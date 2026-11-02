import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_clipper/core/models.dart';
import 'package:quran_clipper/core/render.dart';
import 'package:quran_clipper/core/time_format.dart';

List<Segment> segs(List<List<double>> r) =>
    [for (var i = 0; i < r.length; i++) Segment(id: '$i', start: r[i][0], end: r[i][1])];

/// Runs system ffmpeg, when installed, so the generated graphs are proven to
/// work and not just to look right.
final ffmpeg = ['/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg', '/usr/bin/ffmpeg']
    .firstWhere((p) => File(p).existsSync(), orElse: () => '');
final ffprobe = ffmpeg.replaceAll('ffmpeg', 'ffprobe');

Future<void> run(List<String> args) async {
  final r = await Process.run(ffmpeg, args);
  if (r.exitCode != 0) fail('ffmpeg failed: ${r.stderr}');
}

Future<Map<String, dynamic>> probe(String path) async {
  final r = await Process.run(ffprobe, [
    '-v', 'error', '-show_entries', 'format=duration:stream=codec_type,codec_name,height', '-of', 'json', path,
  ]);
  return jsonDecode(r.stdout as String) as Map<String, dynamic>;
}

double durationOf(Map<String, dynamic> p) => double.parse((p['format'] as Map)['duration'] as String);

void main() {
  group('durations', () {
    final s3 = segs([[1, 4], [10, 12], [20, 25]]); // 3 + 2 + 5 = 10
    test('hard cut and fade keep the sum', () {
      expect(stitchedDuration(s3, ExportSettings()), 10);
      expect(stitchedDuration(s3, ExportSettings(join: JoinMode.fade)), 10);
    });
    test('gap adds a pause per join', () {
      expect(stitchedDuration(s3, ExportSettings(join: JoinMode.gap, joinSeconds: 1)), 12);
    });
    test('crossfade overlaps and is clamped to half the shortest part', () {
      expect(stitchedDuration(s3, ExportSettings(join: JoinMode.crossfade, joinSeconds: 0.5)), 9);
      expect(crossfadeSeconds(s3, ExportSettings(join: JoinMode.crossfade, joinSeconds: 5)), closeTo(0.99, 1e-9));
    });
    test('single part has no joins', () {
      expect(stitchedDuration(segs([[0, 5]]), ExportSettings(join: JoinMode.gap, joinSeconds: 2)), 5);
    });
  });

  group('validation', () {
    test('flags bad parts', () {
      expect(validateSegments([], 10), isNotEmpty);
      expect(validateSegments(segs([[5, 4]]), 10).first, contains('ends before'));
      expect(validateSegments(segs([[11, 12]]), 10).first, contains('after the end'));
      expect(validateSegments(segs([[1, 4]]), 10), isEmpty);
    });
  });

  group('time format', () {
    test('format and parse round trip', () {
      expect(formatTime(75.25), '1:15.3');
      expect(formatTime(3725), '1:02:05.0');
      expect(parseTime('1:15.5'), 75.5);
      expect(parseTime('1:02:05'), 3725);
      expect(parseTime('abc'), isNull);
    });
  });

  group('graph', () {
    test('hard cut uses concat with de-click fades', () {
      final g = audioGraph(segs([[1, 4], [10, 12]]), ExportSettings());
      expect(g, contains('concat=n=2:v=0:a=1'));
      expect(g, contains('afade=t=in:d=0.010'));
    });
    test('crossfade chains acrossfade', () {
      final g = audioGraph(segs([[1, 4], [10, 12], [20, 25]]), ExportSettings(join: JoinMode.crossfade));
      expect('acrossfade'.allMatches(g).length, 2);
    });
  });

  group('real ffmpeg', skip: ffmpeg.isEmpty ? 'ffmpeg not installed' : null, () {
    late Directory dir;
    late String src;

    setUpAll(() async {
      dir = await Directory.systemTemp.createTemp('qc_test');
      src = '${dir.path}/src.mp4';
      await run([
        '-y', '-f', 'lavfi', '-i', 'testsrc=size=640x360:rate=25:duration=30',
        '-f', 'lavfi', '-i', 'sine=frequency=440:duration=30',
        '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'aac', '-shortest', src,
      ]);
    });
    tearDownAll(() => dir.delete(recursive: true));

    final parts = segs([[1, 4], [10, 12], [20, 25]]);

    for (final join in JoinMode.values) {
      for (final format in AudioFormat.values) {
        test('audio ${join.name} ${format.name}', () async {
          final s = ExportSettings(join: join, format: format, joinSeconds: 0.5, normalize: format == AudioFormat.mp3);
          final out = '${dir.path}/out_${join.name}.${format.extension}';
          await run(buildAudioArgs(input: src, segments: parts, settings: s, output: out));
          expect(durationOf(await probe(out)), closeTo(stitchedDuration(parts, s), 0.15));
        });
      }

      test('original video ${join.name}', () async {
        final s = ExportSettings(join: join, joinSeconds: 0.5, video: VideoMode.original, videoHeight: 240, fadeEdges: true);
        final out = '${dir.path}/vid_${join.name}.mp4';
        await run(buildOriginalVideoArgs(audioInput: src, videoInput: src, segments: parts, settings: s, output: out));
        final p = await probe(out);
        expect(durationOf(p), closeTo(stitchedDuration(parts, s), 0.2));
        final streams = (p['streams'] as List).cast<Map>();
        expect(streams.any((e) => e['codec_type'] == 'video' && e['height'] == 240), isTrue);
      });

      test('original video ${join.name} does not upscale', () async {
        final s = ExportSettings(join: join, joinSeconds: 0.5, video: VideoMode.original, videoHeight: 1080);
        final out = '${dir.path}/big_${join.name}.mp4';
        await run(buildOriginalVideoArgs(audioInput: src, videoInput: src, segments: parts, settings: s, output: out));
        final streams = ((await probe(out))['streams'] as List).cast<Map>();
        expect(streams.any((e) => e['codec_type'] == 'video' && e['height'] == 360), isTrue);
      });
    }

    test('still image video', () async {
      final s = ExportSettings(video: VideoMode.stillImage, videoHeight: 360);
      final audio = '${dir.path}/still.mp3';
      final image = '${dir.path}/img.png';
      await run(['-y', '-f', 'lavfi', '-i', 'color=c=green:s=800x600', '-frames:v', '1', image]);
      await run(buildAudioArgs(input: src, segments: parts, settings: s, output: audio));
      final out = '${dir.path}/still.mp4';
      await run(buildStillImageArgs(image: image, audio: audio, durationSeconds: 10, settings: s, output: out));
      expect(durationOf(await probe(out)), closeTo(10, 0.6));
    });

    test('waveform pcm', () async {
      final out = '${dir.path}/wave.raw';
      await run(buildWaveformArgs(input: src, output: out));
      expect(File(out).lengthSync(), closeTo(30 * 4000 * 2, 4000));
    });
  });
}
