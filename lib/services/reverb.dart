import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';
import '../core/render.dart';
import '../platform/ffmpeg_runner.dart';

const _mainAsset = 'assets/reverb/masjid_ir_main.flac';
const _shimmerAsset = 'assets/reverb/masjid_ir_shimmer.flac';

/// How far the measured wet level may be from [reverbWetTargetDb].
const reverbLevelToleranceDb = 0.75;

/// afir's "no auto gain" option changed between ffmpeg versions, and the wrong
/// one can run without any error and make the reverb inaudible. So each is
/// measured until one gives the right level.
const noAutoGainCandidates = ['irnorm=-1', 'gtype=none', 'irnorm=-1:gtype=none'];

/// Copies the impulse responses out of the app, since ffmpeg can't read Flutter
/// assets. Writes only when missing or different, and atomically, so an
/// interrupted copy can't leave a broken file behind.
Future<(String main, String shimmer)> extractReverbAssets(Directory dir) async {
  await dir.create(recursive: true);
  Future<String> extract(String asset) async {
    final bytes = (await rootBundle.load(asset)).buffer.asUint8List();
    final file = File(p.join(dir.path, p.basename(asset)));
    if (await file.exists() && listEquals(await file.readAsBytes(), bytes)) return file.path;
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
    return file.path;
  }

  return (await extract(_mainAsset), await extract(_shimmerAsset));
}

/// A tenth of a second of 48 kHz stereo silence with one sample at 0.5.
Uint8List clickWav() {
  const frames = 4800, clickAt = 100;
  final data = ByteData(44 + frames * 4);
  void tag(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  data.setUint32(4, 36 + frames * 4, Endian.little);
  tag(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 2, Endian.little);
  data.setUint32(24, 48000, Endian.little);
  data.setUint32(28, 48000 * 4, Endian.little);
  data.setUint16(32, 4, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, frames * 4, Endian.little);
  data.setInt16(44 + clickAt * 4, 16384, Endian.little);
  data.setInt16(46 + clickAt * 4, 16384, Endian.little);
  return data.buffer.asUint8List();
}

/// Energy per channel of raw stereo 32-bit floats, in dB relative to [clickWav].
List<double> clickRelativeDb(Uint8List raw) {
  final v = raw.buffer.asByteData(raw.offsetInBytes, raw.lengthInBytes);
  final energy = [0.0, 0.0];
  for (var i = 0; i + 4 <= raw.lengthInBytes; i += 4) {
    final x = v.getFloat32(i, Endian.little);
    energy[(i ~/ 4) % 2] += x * x;
  }
  return [for (final e in energy) e <= 0 ? -200.0 : 10 * log(e / 0.25) / ln10];
}

/// Finds what this ffmpeg needs by testing it. Throws, rather than export the
/// wrong sound, if no option gives the right reverb level.
Future<ReverbEngine> detectReverbEngine(FfmpegRunner ffmpeg, {required String mainIr, required Directory workDir}) async {
  await workDir.create(recursive: true);
  final click = File(p.join(workDir.path, 'reverb_click.wav'));
  final out = File(p.join(workDir.path, 'reverb_check.raw'));
  await click.writeAsBytes(clickWav());
  try {
    String pitchUp;
    try {
      await ffmpeg.run(buildFilterCheckArgs(input: click.path, filter: ReverbEngine.pitchRubberband));
      pitchUp = ReverbEngine.pitchRubberband;
    } on FfmpegException {
      pitchUp = ReverbEngine.pitchResample;
    }

    final tried = <String>[];
    for (final option in noAutoGainCandidates) {
      final engine = ReverbEngine(noAutoGain: option, pitchUp: pitchUp);
      try {
        await ffmpeg.run(buildWetCheckArgs(click: click.path, mainIr: mainIr, engine: engine, output: out.path));
      } on FfmpegException catch (e) {
        tried.add('$option: failed (${e.tail.split('\n').last})');
        continue;
      }
      final levels = clickRelativeDb(await out.readAsBytes());
      if (levels.every((db) => (db - reverbWetTargetDb).abs() <= reverbLevelToleranceDb)) return engine;
      tried.add('$option: ${levels.map((d) => d.toStringAsFixed(1)).join(' / ')} dB');
    }
    throw FfmpegException(
      "Masjid reverb can't run correctly on this device, so nothing was exported.",
      'Expected $reverbWetTargetDb dB.\n${tried.join('\n')}',
    );
  } finally {
    for (final f in [click, out]) {
      if (await f.exists()) await f.delete();
    }
  }
}

/// Sets the reverb up once per app run.
class MasjidReverb {
  MasjidReverb._();
  static final instance = MasjidReverb._();

  Future<ReverbRig>? _rig;

  Future<ReverbRig> rig() {
    return _rig ??= _prepare().catchError((Object e) {
      _rig = null; // Try again next time.
      throw e;
    });
  }

  Future<ReverbRig> _prepare() async {
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'reverb'));
    final (main, shimmer) = await extractReverbAssets(dir);
    final engine = await detectReverbEngine(FfmpegRunner.instance, mainIr: main, workDir: dir);
    return ReverbRig(mainIr: main, shimmerIr: shimmer, engine: engine);
  }
}

/// Renders a short stretch of [project] to a WAV in [dir] for listening.
Future<String> renderPreview({
  required Project project,
  required ExportSettings settings,
  required bool withReverb,
  required Directory dir,
  double seconds = 20,
  CancelHandle? cancel,
}) async {
  await dir.create(recursive: true);
  // Edge fades belong to the whole result, not to this stretch of it.
  final s = settings.copy()
    ..format = AudioFormat.wav
    ..video = VideoMode.none
    ..fadeEdges = false
    ..masjidReverb = withReverb;
  final file = File(p.join(dir.path, 'preview_${DateTime.now().microsecondsSinceEpoch}.wav'));
  await FfmpegRunner.instance.run(
    buildAudioArgs(
      input: project.audioPath,
      segments: previewSegments(project.segments, seconds),
      settings: s,
      output: file.path,
      reverb: withReverb ? await MasjidReverb.instance.rig() : null,
    ),
    cancel: cancel,
  );
  return file.path;
}
