import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_clipper/core/models.dart';
import 'package:quran_clipper/core/render.dart';
import 'package:quran_clipper/core/time_format.dart';
import 'package:quran_clipper/platform/ffmpeg_runner.dart';
import 'package:quran_clipper/services/reverb.dart';

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

const mainIr = 'assets/reverb/masjid_ir_main.flac';
const shimmerIr = 'assets/reverb/masjid_ir_shimmer.flac';
const engine = ReverbEngine(noAutoGain: 'irnorm=-1', pitchUp: ReverbEngine.pitchResample);
const rig = ReverbRig(mainIr: mainIr, shimmerIr: shimmerIr, engine: engine);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  group('reverb off', () {
    // Recorded from the code as it was before the reverb existed. Any change
    // here means ordinary exports changed.
    final golden = jsonDecode(File('test/goldens/graphs_reverb_off.json').readAsStringSync()) as Map<String, dynamic>;
    final parts = [
      Segment(id: 'a', start: 1, end: 4),
      Segment(id: 'b', start: 10, end: 12),
      Segment(id: 'c', start: 20, end: 25),
    ];
    final one = [Segment(id: 'a', start: 1.5, end: 9.25)];

    for (final join in JoinMode.values) {
      for (final extras in [false, true]) {
        for (final p in [parts, one]) {
          final k = '${join.name}_${extras ? 'extras' : 'plain'}_${p.length}';
          test('$k is unchanged', () {
            final s = ExportSettings(
              join: join,
              joinSeconds: 0.5,
              normalize: extras,
              fadeEdges: extras,
              video: VideoMode.original,
            );
            expect(buildAudioArgs(input: 'in.m4a', segments: p, settings: s, output: 'out.mp3'), golden['audio_$k']);
            expect(
              buildOriginalVideoArgs(audioInput: 'in.mp4', videoInput: 'in.mp4', segments: p, settings: s, output: 'out.mp4'),
              golden['video_same_$k'],
            );
            expect(
              buildOriginalVideoArgs(audioInput: 'in.m4a', videoInput: 'in.mp4', segments: p, settings: s, output: 'out.mp4'),
              golden['video_two_$k'],
            );
          });
        }
      }
    }

    test('still image is unchanged', () {
      expect(
        buildStillImageArgs(
          image: 'i.png',
          audio: 'a.mp3',
          durationSeconds: 10,
          settings: ExportSettings(video: VideoMode.stillImage),
          output: 'o.mp4',
        ),
        golden['still'],
      );
    });

    test('no reverb filters appear', () {
      final g = audioGraph(parts, ExportSettings());
      for (final f in ['afir', 'amix', 'alimiter', 'extrastereo', 'highpass', 'acompressor', 'reverbed']) {
        expect(g, isNot(contains(f)));
      }
      expect(videoGraph(parts, ExportSettings()), isNot(contains('tpad')));
    });
  });

  group('reverb settings', () {
    test('old saved settings still load, with the reverb off', () {
      final s = ExportSettings.fromJson({'format': 'wav', 'bitrateKbps': 128});
      expect(s.masjidReverb, isFalse);
      expect(s.reverbAmount, ReverbAmount.normal);
      expect(s.reverbSparkle, isTrue);
      expect(s.format, AudioFormat.wav);
    });
    test('survive saving and loading', () {
      final s = ExportSettings(masjidReverb: true, reverbAmount: ReverbAmount.strong, reverbSparkle: false).copy();
      expect(s.masjidReverb, isTrue);
      expect(s.reverbAmount, ReverbAmount.strong);
      expect(s.reverbSparkle, isFalse);
    });
    test('an unknown amount falls back to normal', () {
      expect(ExportSettings.fromJson({'reverbAmount': 'huge'}).reverbAmount, ReverbAmount.normal);
    });
  });

  group('reverb graph', () {
    final parts = segs([[1, 4], [10, 12]]);
    ExportSettings on({ReverbAmount amount = ReverbAmount.normal, bool sparkle = true, bool extras = false}) =>
        ExportSettings(masjidReverb: true, reverbAmount: amount, reverbSparkle: sparkle, normalize: extras, fadeEdges: extras);

    test('is exactly the tuned chain, in order', () {
      expect(
        reverbGraph('acat', on(), engine, ir: 1),
        '[acat]highpass=f=100,equalizer=f=850:t=o:w=1.2:g=3.5,equalizer=f=3500:t=o:w=1.5:g=-2,'
        'acompressor=threshold=0.063:ratio=3:attack=15:release=180,extrastereo=m=0.7,apad=pad_dur=9,'
        'asplit=3[rdry][rv][rsh];'
        '[1:a]aformat=sample_fmts=fltp:channel_layouts=stereo[ir1];'
        '[2:a]aformat=sample_fmts=fltp:channel_layouts=stereo[ir2];'
        '[rv][ir1]afir=irnorm=-1:irfmt=input,volume=-49.39dB[rwet];'
        '[rsh]asetrate=96000,aresample=48000,atempo=0.5,highpass=f=900[rshp];'
        '[rshp][ir2]afir=irnorm=-1:irfmt=input,highpass=f=1500,lowpass=f=6000,volume=-57.42dB[rshw];'
        '[rdry][rwet][rshw]amix=inputs=3:normalize=0,alimiter=limit=0.84:level=0[reverbed]',
      );
    });

    test('runs after the join and before loudnorm and edge fades', () {
      final g = audioGraph(parts, on(extras: true), engine: engine);
      final order = ['concat=', 'highpass=f=100', 'alimiter', '[reverbed]loudnorm', 'afade=t=in:d=1.500'];
      final at = order.map(g.indexOf).toList();
      expect(at, isNot(contains(-1)));
      expect(at, orderedEquals([...at]..sort()));
      expect(g, endsWith('[aout]'));
    });

    test('amount moves wet and shimmer together', () {
      final light = reverbGraph('a', on(amount: ReverbAmount.light), engine, ir: 1);
      expect(light, allOf(contains('volume=-53.39dB'), contains('volume=-61.42dB')));
      final strong = reverbGraph('a', on(amount: ReverbAmount.strong), engine, ir: 1);
      expect(strong, allOf(contains('volume=-45.39dB'), contains('volume=-53.42dB')));
    });

    test('sparkle off drops the whole shimmer branch', () {
      final g = reverbGraph('a', on(sparkle: false), engine, ir: 1);
      expect(g, allOf(contains('asplit=2[rdry][rv];'), contains('[rdry][rwet]amix=inputs=2:normalize=0')));
      for (final f in ['rsh', 'ir2', 'atempo', 'f=1500', '2:a']) {
        expect(g, isNot(contains(f)));
      }
    });

    test('uses the options found for this ffmpeg', () {
      const old = ReverbEngine(noAutoGain: 'gtype=none', pitchUp: ReverbEngine.pitchRubberband);
      final g = reverbGraph('a', on(), old, ir: 1);
      expect(g, allOf(contains('afir=gtype=none:irfmt=input'), contains('[rsh]rubberband=pitch=2,highpass')));
      expect(g, isNot(contains('irnorm')));
    });

    test('impulse responses are numbered after the other inputs', () {
      final s = on()..video = VideoMode.original;
      final audio = buildAudioArgs(input: 'a.m4a', segments: parts, settings: s, output: 'o.mp3', reverb: rig);
      expect(audio.where((e) => e == '-i').length, 3);
      expect(audio.join(' '), allOf(contains('[1:a]aformat'), contains('[2:a]aformat')));

      final same = buildOriginalVideoArgs(audioInput: 'v.mp4', videoInput: 'v.mp4', segments: parts, settings: s, output: 'o.mp4', reverb: rig);
      expect(same.join(' '), allOf(contains('[0:v]trim'), contains('[1:a]aformat'), contains('[2:a]aformat')));

      final two = buildOriginalVideoArgs(audioInput: 'a.m4a', videoInput: 'v.mp4', segments: parts, settings: s, output: 'o.mp4', reverb: rig);
      expect(two.join(' '), allOf(contains('[1:v]trim'), contains('[2:a]aformat'), contains('[3:a]aformat')));

      final dry = buildAudioArgs(input: 'a.m4a', segments: parts, settings: on(sparkle: false), output: 'o.mp3', reverb: rig);
      expect(dry, isNot(contains(shimmerIr)));
    });

    test('adds the tail to the length, for every join', () {
      for (final join in JoinMode.values) {
        final off = ExportSettings(join: join, joinSeconds: 0.5);
        final with9 = off.copy()..masjidReverb = true;
        expect(stitchedDuration(parts, with9), closeTo(stitchedDuration(parts, off) + 9, 1e-9));
      }
      expect(stitchedDuration([], ExportSettings(masjidReverb: true)), 0);
    });

    test('edge fades end at the end of the tail', () {
      final s = on(extras: true); // 3 + 2 + 9 = 14, so the fade starts at 12.5.
      expect(audioGraph(parts, s, engine: engine), contains('afade=t=out:st=12.500:d=1.500'));
      expect(videoGraph(parts, s), contains('fade=t=out:st=12.500:d=1.500'));
    });

    test('video holds its last frame for the tail, before any fade', () {
      expect(videoGraph(parts, on()), contains('tpad=stop_mode=clone:stop_duration=9[vout]'));
      final faded = videoGraph(parts, on(extras: true));
      expect(faded.indexOf('tpad=stop_mode=clone'), lessThan(faded.indexOf('fade=t=in')));
    });
  });

  group('preview stretch', () {
    double len(List<Segment> s) => s.fold(0.0, (a, e) => a + e.length);

    test('a long first part gives its ending', () {
      final p = previewSegments(segs([[10, 100], [200, 300]]), 20);
      expect(p.length, 1);
      expect([p[0].start, p[0].end], [80, 100]);
    });
    test('short parts stay whole, then the ending of the next', () {
      final p = previewSegments(segs([[0, 5], [10, 100]]), 20);
      expect(p.length, 2);
      expect([p[1].start, p[1].end], [85, 100]);
      expect(len(p), 20);
    });
    test('never longer than the parts, and leaves them untouched', () {
      final original = segs([[0, 5]]);
      final p = previewSegments(original, 20);
      expect(len(p), 5);
      p[0].start = 3;
      expect(original[0].start, 0);
    });
    test('skips a sliver too short to matter', () {
      expect(previewSegments(segs([[0, 19.5], [30, 90]]), 20).length, 1);
    });
  });

  group('reverb assets', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('qc_assets'));
    tearDown(() => dir.delete(recursive: true));

    test('copies out, and repairs a damaged file', () async {
      final (main, shimmer) = await extractReverbAssets(dir);
      final good = File(mainIr).readAsBytesSync();
      expect(File(main).readAsBytesSync(), good);
      expect(File(shimmer).readAsBytesSync(), File(shimmerIr).readAsBytesSync());

      File(main).writeAsBytesSync(good.sublist(0, 100));
      await extractReverbAssets(dir);
      expect(File(main).readAsBytesSync(), good);
      expect(dir.listSync().map((e) => e.path).where((e) => e.endsWith('.tmp')), isEmpty);
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

    test('a whole file keeps all of its sound and gains the tail', () async {
      final p = Project(id: 'whole', title: 'Whole', audioPath: src, duration: durationOf(await probe(src)))..useWholeFile();
      final s = ExportSettings(join: JoinMode.crossfade).forWholeFile();
      final out = '${dir.path}/whole.mp3';
      await run(buildAudioArgs(input: src, segments: p.segments, settings: s, output: out, reverb: rig));
      expect(durationOf(await probe(out)), closeTo(p.duration + reverbTailSeconds, 0.15));

      // The last second of the file is still there, at full level.
      final r = await Process.run(ffmpeg, ['-hide_banner', '-ss', '${p.duration - 1}', '-t', '0.9', '-i', out, '-af', 'volumedetect', '-f', 'null', '-']);
      final peak = double.parse(RegExp(r'max_volume: (-?[\d.]+) dB').firstMatch(r.stderr as String)!.group(1)!);
      expect(peak, greaterThan(-30));
    });

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

    group('reverb', () {
      late ReverbEngine found;
      late ReverbRig realRig;
      setUpAll(() async {
        found = await detectReverbEngine(
          ProcessFfmpegRunner(ffmpeg: ffmpeg, ffprobe: ffprobe),
          mainIr: mainIr,
          workDir: dir,
        );
        realRig = ReverbRig(mainIr: mainIr, shimmerIr: shimmerIr, engine: found);
        // ignore: avoid_print
        print('This ffmpeg uses: ${found.noAutoGain} and ${found.pitchUp}');
      });

      test('a click through the wet branch comes out at -19 dB', () async {
        final click = '${dir.path}/click.wav';
        final out = '${dir.path}/click_out.raw';
        File(click).writeAsBytesSync(clickWav());
        await run(buildWetCheckArgs(click: click, mainIr: mainIr, engine: found, output: out));
        final levels = clickRelativeDb(File(out).readAsBytesSync());
        expect(levels.length, 2);
        for (final db in levels) {
          expect(db, closeTo(-19, 0.75));
        }
      });

      test('click energy is measured correctly', () {
        final raw = Float32List.fromList([0.5, 0.25, 0, 0]);
        final db = clickRelativeDb(raw.buffer.asUint8List());
        expect(db[0], closeTo(0, 1e-6));
        expect(db[1], closeTo(-6.02, 0.01));
      });

      test('auto gain really is the thing being checked', () async {
        // Without the option the level is far off, so the check above can fail.
        const auto = ReverbEngine(noAutoGain: 'irlink=1', pitchUp: ReverbEngine.pitchResample);
        final click = '${dir.path}/click2.wav';
        final out = '${dir.path}/click2_out.raw';
        File(click).writeAsBytesSync(clickWav());
        await run(buildWetCheckArgs(click: click, mainIr: mainIr, engine: auto, output: out));
        expect((clickRelativeDb(File(out).readAsBytesSync())[0] + 19).abs(), greaterThan(5));
      });

      test('a loud tone gets the 9s tail and stays under the limiter', () async {
        final tone = '${dir.path}/tone.wav';
        // The compressor tames anything at full scale, so to really push the
        // limiter this uses sudden bursts well above it, in a float WAV.
        const burst = 'gt(mod(t\\,0.5)\\,0.4)*3*sin(2*PI*850*t)';
        await run(['-y', '-f', 'lavfi', '-i', 'aevalsrc=$burst|$burst:s=48000:d=4', '-c:a', 'pcm_f32le', tone]);
        final s = ExportSettings(masjidReverb: true, format: AudioFormat.wav);
        final parts2 = segs([[0, 4]]);
        final out = '${dir.path}/tone_out.wav';
        await run(buildAudioArgs(input: tone, segments: parts2, settings: s, output: out, reverb: realRig));
        expect(durationOf(await probe(out)), closeTo(4 + 9, 0.1));

        final raw = '${dir.path}/tone_out.raw';
        await run(['-y', '-i', out, '-c:a', 'pcm_f32le', '-f', 'f32le', raw]);
        final bytes = File(raw).readAsBytesSync();
        final samples = bytes.buffer.asFloat32List(0, bytes.length ~/ 4);
        final peak = samples.map((e) => e.abs()).reduce(max);
        expect(peak, lessThanOrEqualTo(reverbLimit + 0.001));
        expect(peak, greaterThan(0.8)); // It really reached the limiter.
        // The tail isn't silence.
        final last = samples.sublist(samples.length - 48000 * 2 * 2);
        expect(last.map((e) => e.abs()).reduce(max), greaterThan(0));
      });

      for (final pitch in [ReverbEngine.pitchResample, ReverbEngine.pitchRubberband]) {
        test('sparkle works with $pitch', () async {
          final check = await Process.run(ffmpeg, ['-hide_banner', '-filters']);
          if (pitch == ReverbEngine.pitchRubberband && !(check.stdout as String).contains('rubberband')) {
            markTestSkipped('this ffmpeg has no rubberband');
            return;
          }
          final tryRig = ReverbRig(
            mainIr: mainIr,
            shimmerIr: shimmerIr,
            engine: ReverbEngine(noAutoGain: found.noAutoGain, pitchUp: pitch),
          );
          final s = ExportSettings(masjidReverb: true, format: AudioFormat.flac);
          final out = '${dir.path}/pitch_${pitch.length}.flac';
          await run(buildAudioArgs(input: src, segments: parts, settings: s, output: out, reverb: tryRig));
          expect(durationOf(await probe(out)), closeTo(stitchedDuration(parts, s), 0.15));
        });
      }

      for (final join in JoinMode.values) {
        for (final format in AudioFormat.values) {
          test('audio ${join.name} ${format.name}', () async {
            final s = ExportSettings(
              join: join,
              format: format,
              joinSeconds: 0.5,
              masjidReverb: true,
              reverbSparkle: format != AudioFormat.opus,
              reverbAmount: ReverbAmount.values[format.index % 3],
              normalize: format == AudioFormat.mp3,
              fadeEdges: format == AudioFormat.m4a,
            );
            final out = '${dir.path}/rev_${join.name}.${format.extension}';
            await run(buildAudioArgs(input: src, segments: parts, settings: s, output: out, reverb: realRig));
            expect(durationOf(await probe(out)), closeTo(stitchedDuration(parts, s), 0.15));
          });
        }

        test('original video ${join.name}', () async {
          final s = ExportSettings(
            join: join,
            joinSeconds: 0.5,
            masjidReverb: true,
            video: VideoMode.original,
            videoHeight: 240,
            fadeEdges: join == JoinMode.fade,
          );
          final out = '${dir.path}/rev_vid_${join.name}.mp4';
          await run(buildOriginalVideoArgs(audioInput: src, videoInput: src, segments: parts, settings: s, output: out, reverb: realRig));
          final p = await probe(out);
          expect(durationOf(p), closeTo(stitchedDuration(parts, s), 0.2));
          final streams = (p['streams'] as List).cast<Map>();
          expect(streams.any((e) => e['codec_type'] == 'video'), isTrue);
        });
      }

      test('original video from a separate audio file', () async {
        final s = ExportSettings(masjidReverb: true, video: VideoMode.original, videoHeight: 240);
        final audio = '${dir.path}/sep.m4a';
        await run(['-y', '-i', src, '-vn', '-c:a', 'copy', audio]);
        final out = '${dir.path}/sep.mp4';
        await run(buildOriginalVideoArgs(audioInput: audio, videoInput: src, segments: parts, settings: s, output: out, reverb: realRig));
        expect(durationOf(await probe(out)), closeTo(stitchedDuration(parts, s), 0.2));
      });

      test('still image video runs for the tail too', () async {
        final s = ExportSettings(masjidReverb: true, video: VideoMode.stillImage, videoHeight: 360);
        final total = stitchedDuration(parts, s);
        final audio = '${dir.path}/rev_still.mp3';
        final image = '${dir.path}/rev_img.png';
        await run(['-y', '-f', 'lavfi', '-i', 'color=c=green:s=800x600', '-frames:v', '1', image]);
        await run(buildAudioArgs(input: src, segments: parts, settings: s, output: audio, reverb: realRig));
        final out = '${dir.path}/rev_still.mp4';
        await run(buildStillImageArgs(image: image, audio: audio, durationSeconds: total, settings: s, output: out));
        expect(total, 19);
        expect(durationOf(await probe(out)), closeTo(total, 0.6));
      });
    });

    test('waveform pcm', () async {
      final out = '${dir.path}/wave.raw';
      await run(buildWaveformArgs(input: src, output: out));
      expect(File(out).lengthSync(), closeTo(30 * 4000 * 2, 4000));
    });
  });
}
