import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:quran_clipper/core/models.dart';
import 'package:quran_clipper/core/render.dart';
import 'package:quran_clipper/platform/ffmpeg_runner.dart';
import 'package:quran_clipper/services/exporter.dart';
import 'package:quran_clipper/services/reverb.dart';
import 'package:quran_clipper/services/storage.dart';

/// Runs the export code through the FFmpeg bundled with the app, on the
/// platform it's running on. The unit tests use a system ffmpeg, which is a
/// different version and build.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late String audio;
  late String video;
  final ffmpeg = FfmpegRunner.instance;

  Project project(String title, {String? videoPath, required List<Segment> parts}) => Project(
        id: newId(),
        title: title,
        audioPath: audio,
        videoPath: videoPath,
        duration: 600,
        segments: parts,
      );

  List<Segment> parts() => [
        Segment(id: 'a', start: 1, end: 4),
        Segment(id: 'b', start: 6, end: 8),
        Segment(id: 'c', start: 10, end: 15),
      ];

  Future<ExportResult> export(Project p, ExportSettings s, {CancelHandle? cancel, void Function(double)? onProgress}) =>
      Exporter(onStatus: (_) {}, onProgress: onProgress ?? (_) {}, cancel: cancel).run(p, s);

  Future<List<String>> desktopOrProjectExports(Project pr) async {
    final folder = isDesktop ? await desktopExportDir() : Directory(p.join(ProjectStore.instance.dirFor(pr.id).path, 'exports'));
    if (!folder.existsSync()) return [];
    return folder.listSync().map((e) => e.path).toList();
  }

  setUpAll(() async {
    await SettingsStore.init();
    await ProjectStore.init();
    // On macOS the temporary folder may not exist yet.
    dir = await (await (await getTemporaryDirectory()).create(recursive: true)).createTemp('qc_integration');
    audio = p.join(dir.path, 'voice like.wav');
    video = p.join(dir.path, 'source.mp4');
    // Ten minutes, with pauses and changing pitch, so it costs what speech costs.
    const voice = '0.4*gt(sin(2*PI*0.3*t)\\,-0.5)*sin(2*PI*(180+60*sin(2*PI*1.7*t))*t)';
    await ffmpeg.run(['-y', '-f', 'lavfi', '-i', 'aevalsrc=$voice|$voice:s=48000:d=600', audio]);
    await ffmpeg.run([
      '-y', '-f', 'lavfi', '-i', 'testsrc=size=320x180:rate=10:duration=20',
      '-f', 'lavfi', '-i', 'sine=frequency=300:duration=20',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'aac', '-shortest', video,
    ]);
  });

  tearDownAll(() => dir.delete(recursive: true));

  testWidgets('finds a working setup for this FFmpeg', (t) async {
    final rig = await MasjidReverb.instance.rig();
    debugPrint('REVERB ENGINE ${Platform.operatingSystem}: ${rig.engine.noAutoGain} | ${rig.engine.pitchUp}');
    expect(File(rig.mainIr).lengthSync(), greaterThan(100000));
    expect(File(rig.shimmerIr).lengthSync(), greaterThan(100000));
    // Asked again, it's the same work, not a new check.
    expect(identical(await MasjidReverb.instance.rig(), rig), isTrue);
  });

  testWidgets('every audio format, with and without sparkle', (t) async {
    for (final format in AudioFormat.values) {
      for (final sparkle in [true, false]) {
        final s = ExportSettings(format: format, masjidReverb: true, reverbSparkle: sparkle, normalize: format == AudioFormat.mp3);
        final r = await export(project('format test', parts: parts()), s);
        final info = await ffmpeg.probe(r.audioPath);
        expect(info.duration, closeTo(stitchedDuration(parts(), s), 0.2), reason: '$format sparkle $sparkle');
        expect(r.audioPath, contains('(masjid reverb)'));
        File(r.audioPath).deleteSync();
      }
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('every join, with a title card video', (t) async {
    for (final join in JoinMode.values) {
      final s = ExportSettings(join: join, joinSeconds: 0.5, masjidReverb: true, fadeEdges: true, video: VideoMode.stillImage, videoHeight: 360);
      final r = await export(project('join test', parts: parts()), s);
      final info = await ffmpeg.probe(r.videoPath!);
      expect(info.hasVideo, isTrue);
      expect(info.duration, closeTo(stitchedDuration(parts(), s), 0.7), reason: '$join');
      File(r.audioPath).deleteSync();
      File(r.videoPath!).deleteSync();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('original footage holds the last frame for the tail', (t) async {
    final s = ExportSettings(masjidReverb: true, video: VideoMode.original, videoHeight: 180);
    final r = await export(project('footage test', videoPath: video, parts: parts()), s);
    final info = await ffmpeg.probe(r.videoPath!);
    expect(info.hasVideo, isTrue);
    expect(info.hasAudio, isTrue);
    expect(info.duration, closeTo(stitchedDuration(parts(), s), 0.3));
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('a whole file goes straight through, as audio and as video', (t) async {
    final length = (await ffmpeg.probe(video)).duration;
    final pr = Project(id: newId(), title: 'whole file test', audioPath: video, videoPath: video, duration: length)..useWholeFile();
    final audioOnly = ExportSettings().forWholeFile();
    final sound = await export(pr, audioOnly);
    expect((await ffmpeg.probe(sound.audioPath)).duration, closeTo(length + reverbTailSeconds, 0.2));
    expect(sound.audioPath, contains('(masjid reverb)'));

    final footage = await export(pr, audioOnly.copy()
      ..video = VideoMode.original
      ..videoHeight = 180);
    final info = await ffmpeg.probe(footage.videoPath!);
    expect(info.hasVideo, isTrue);
    expect(info.duration, closeTo(length + reverbTailSeconds, 0.3));
    await ProjectStore.instance.delete(pr);
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('cancel works while the system is holding a file up', (t) async {
    // Opening a pipe nobody is writing to blocks, like a file behind a macOS
    // privacy prompt does.
    final pipe = p.join(dir.path, 'held.wav');
    expect((await Process.run('mkfifo', [pipe])).exitCode, 0);
    final pr = Project(id: newId(), title: 'held test', audioPath: pipe, duration: 20, segments: parts());
    final cancel = CancelHandle();
    final clock = Stopwatch()..start();
    Future<void>.delayed(const Duration(seconds: 2), cancel.cancel);
    await expectLater(export(pr, ExportSettings(), cancel: cancel), throwsA(isA<CancelledException>()));
    expect(clock.elapsed, lessThan(const Duration(seconds: 15)));
    final out = await desktopOrProjectExports(pr);
    expect(out.where((f) => p.basename(f).startsWith('held test')), isEmpty);

    // Let the stuck job go, then check it doesn't leave anything behind.
    final sink = File(pipe).openWrite();
    await sink.close();
    await Future<void>.delayed(const Duration(seconds: 2));
    expect((await desktopOrProjectExports(pr)).where((f) => p.basename(f).startsWith('held test')), isEmpty);
    await ProjectStore.instance.delete(pr);
  }, skip: Platform.isWindows, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('preview renders with reverb and without', (t) async {
    final pr = project('preview test', parts: [Segment(id: 'a', start: 10, end: 100)]);
    final wet = await renderPreview(project: pr, settings: ExportSettings(masjidReverb: true), withReverb: true, dir: dir);
    final dry = await renderPreview(project: pr, settings: ExportSettings(masjidReverb: true), withReverb: false, dir: dir);
    expect((await ffmpeg.probe(wet)).duration, closeTo(29, 0.2));
    expect((await ffmpeg.probe(dry)).duration, closeTo(20, 0.2));
  });

  testWidgets('cancelling removes the unfinished file', (t) async {
    final cancel = CancelHandle();
    final outDir = isDesktop ? await desktopExportDir() : null;
    final pr = project('cancel test ${newId()}', parts: [Segment(id: 'a', start: 0, end: 600)]);
    final seen = Directory(outDir?.path ?? p.join(ProjectStore.instance.dirFor(pr.id).path, 'exports'));
    var cancelled = false;
    await expectLater(
      export(pr, ExportSettings(masjidReverb: true, format: AudioFormat.wav), cancel: cancel, onProgress: (f) {
        if (f > 0.02 && !cancelled) {
          cancelled = true;
          cancel.cancel();
        }
      }),
      throwsA(isA<CancelledException>()),
    );
    expect(cancelled, isTrue);
    final left = seen.existsSync() ? seen.listSync().where((e) => p.basename(e.path).startsWith(pr.title)) : const [];
    expect(left, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('how long ten minutes takes', (t) async {
    final clip = [Segment(id: 'a', start: 0, end: 600)];
    Future<int> time(ExportSettings s) async {
      final r = await export(project('timing', parts: clip), s);
      File(r.audioPath).deleteSync();
      return r.took.inMilliseconds;
    }

    final off = await time(ExportSettings());
    final on = await time(ExportSettings(masjidReverb: true));
    final dry = await time(ExportSettings(masjidReverb: true, reverbSparkle: false));
    debugPrint('REVERB TIMING ${Platform.operatingSystem}: 10 min MP3 off ${off}ms, on ${on}ms, sparkle off ${dry}ms');
  }, timeout: const Timeout(Duration(minutes: 60)));
}
