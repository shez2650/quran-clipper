import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/render.dart';
import '../platform/ffmpeg_runner.dart';

/// Peak levels (0..1) at [peaksPerSecond] across the whole source.
class Waveform {
  const Waveform(this.peaks, this.peaksPerSecond);
  final Float32List peaks;
  final int peaksPerSecond;

  double get duration => peaks.length / peaksPerSecond;
}

const _sampleRate = 4000;
const _peaksPerSecond = 50;

/// Loads the cached waveform for [source] or builds it with ffmpeg.
Future<Waveform> loadWaveform(String source, Directory cacheDir) async {
  final cache = File(p.join(cacheDir.path, 'waveform_${source.hashCode.toUnsigned(32)}.peaks'));
  if (await cache.exists()) {
    final bytes = await cache.readAsBytes();
    return Waveform(bytes.buffer.asFloat32List(bytes.offsetInBytes, bytes.lengthInBytes ~/ 4), _peaksPerSecond);
  }
  final raw = File(p.join(cacheDir.path, 'waveform.raw'));
  await FfmpegRunner.instance.run(buildWaveformArgs(input: source, output: raw.path, sampleRate: _sampleRate));
  final pcm = await raw.readAsBytes();
  final peaks = await compute(_peaksFromPcm, pcm);
  await raw.delete();
  await cache.writeAsBytes(peaks.buffer.asUint8List(peaks.offsetInBytes, peaks.lengthInBytes));
  return Waveform(peaks, _peaksPerSecond);
}

Float32List _peaksFromPcm(Uint8List pcm) {
  final samples = pcm.buffer.asInt16List(pcm.offsetInBytes, pcm.lengthInBytes ~/ 2);
  const per = _sampleRate ~/ _peaksPerSecond;
  final out = Float32List((samples.length / per).ceil());
  var loudest = 1.0;
  for (var i = 0; i < out.length; i++) {
    var m = 0;
    final end = (i + 1) * per < samples.length ? (i + 1) * per : samples.length;
    for (var j = i * per; j < end; j++) {
      final v = samples[j].abs();
      if (v > m) m = v;
    }
    out[i] = m.toDouble();
    if (m > loudest) loudest = m.toDouble();
  }
  // Normalise so quiet recordings still draw a readable shape.
  for (var i = 0; i < out.length; i++) {
    out[i] = out[i] / loudest;
  }
  return out;
}
