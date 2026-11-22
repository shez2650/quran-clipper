import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quran_clipper/core/cancellation.dart';
import 'package:quran_clipper/services/downloader.dart';
import 'package:quran_clipper/services/yt_dlp.dart';

class FakeProcess extends Fake implements Process {
  FakeProcess(String output, {String error = '', int code = 0})
      : stdout = Stream.value(utf8.encode(output)),
        stderr = Stream.value(utf8.encode(error)), exitCode = Future.value(code);
  FakeProcess.held()
      : stdout = const Stream.empty(), stderr = const Stream.empty() {
    exitCode = finished.future;
  }
  final finished = Completer<int>();
  bool killed = false;
  @override
  final Stream<List<int>> stdout;
  @override
  final Stream<List<int>> stderr;
  @override
  late final Future<int> exitCode;
  @override
  int get pid => 2147483647;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!finished.isCompleted) finished.complete(1);
    return true;
  }
}

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('qc downloader spaces '));
  tearDown(() async => dir.delete(recursive: true));

  test('bundled executable wins, then WinGet and PATH; cwd is irrelevant', () async {
    final app = p.join(dir.path, 'app', 'QuranClipper.exe');
    final bundled = File(bundledYtDlpPath(app));
    await bundled.parent.create(recursive: true);
    await bundled.writeAsString('');
    final system = File(p.join(dir.path, 'system', 'yt-dlp.exe'));
    await system.parent.create();
    await system.writeAsString('');
    final winget = File(p.join(dir.path, 'local', 'Microsoft', 'WinGet', 'Links', 'yt-dlp.exe'));
    await winget.parent.create(recursive: true);
    await winget.writeAsString('');
    final env = {'PATH': system.parent.path, 'LOCALAPPDATA': p.join(dir.path, 'local')};
    Future<String?> find() => findYtDlp(executable: app, windows: true, environment: env);
    expect(await find(), bundled.path);
    await bundled.delete();
    expect(await find(), winget.path);
    await winget.delete();
    expect(await find(), system.path);
    await system.delete();
    expect(await find(), isNull);
  });

  test('accepts video URLs and shared text, rejects foreign hosts and playlists', () {
    for (final url in [
      'https://www.youtube.com/watch?v=BaW_jenozKc&list=abc',
      'https://youtu.be/BaW_jenozKc?t=4',
      'https://m.youtube.com/shorts/BaW_jenozKc',
      'https://youtube.com/live/BaW_jenozKc',
      'Watch this https://youtu.be/BaW_jenozKc',
      'BaW_jenozKc',
    ]) {
      expect(YouTubeDownloader.parseId(url), 'BaW_jenozKc', reason: url);
    }
    for (final url in [
      '', 'https://evil.test/watch?v=BaW_jenozKc',
      'https://youtube.com.evil.test/watch?v=BaW_jenozKc',
      'https://youtube.com/playlist?list=abc', '--exec whoami',
      'https://youtube.com@evil.test/watch?v=BaW_jenozKc',
    ]) {
      expect(YouTubeDownloader.parseId(url), isNull, reason: url);
    }
  });

  test('Windows metadata failure does not block a viable audio/video download', () async {
    final calls = <List<String>>[];
    final progress = <double>[];
    final native = YtDlp('bundled downloader.exe', start: (exe, args) async {
      calls.add(args);
      if (args.contains('--dump-single-json')) return FakeProcess('', code: 1, error: 'metadata refused');
      final output = args[args.indexOf('-o') + 1].replaceAll('%(ext)s', args.contains('ba[ext=m4a]/ba') ? 'm4a' : 'mp4');
      await File(output).writeAsString('media');
      return FakeProcess('progress: 50.0%\n$output\n');
    });
    final dl = YouTubeDownloader(windows: true, ytDlp: native);
    expect((await dl.fetchMeta('BaW_jenozKc')).title, 'YouTube BaW_jenozKc');
    final audio = await dl.downloadAudio('BaW_jenozKc', dir, onProgress: progress.add);
    final video = await dl.downloadVideo('BaW_jenozKc', dir, maxHeight: 720);
    expect(await File(audio).readAsString(), 'media');
    expect(p.extension(video), '.mp4');
    expect(progress, containsAllInOrder([0.5, 1.0]));
    expect(calls.last[calls.last.indexOf('-f') + 1], contains('height<=720'));
    for (final args in calls) {
      expect(args.last, 'https://www.youtube.com/watch?v=BaW_jenozKc');
      expect(args[args.length - 2], '--');
      expect(args, contains('--ignore-config'));
    }
    expect(await dir.list().where((e) => e is Directory).toList(), isEmpty);
  });

  test('failure cleans only temporary downloads and preserves saved audio', () async {
    final saved = File(p.join(dir.path, 'audio.m4a'));
    await saved.writeAsString('saved');
    final dl = YtDlp('fake', start: (_, args) async {
      await File(args[args.indexOf('-o') + 1].replaceAll('%(ext)s', 'mp4.part')).writeAsString('partial');
      return FakeProcess('', code: 1, error: 'Private video');
    });
    await expectLater(dl.download('BaW_jenozKc', dir, video: true),
        throwsA(isA<YtDlpException>().having((e) => e.message, 'message', contains('Private video'))));
    expect(await saved.readAsString(), 'saved');
    expect((await dir.list().toList()).length, 1);
  });

  test('pre-cancelled download does not start a process or create files', () async {
    final cancel = CancelHandle()..cancel();
    final dl = YtDlp('fake', start: (_, _) => throw StateError('must not start'));
    await expectLater(dl.download('BaW_jenozKc', dir, video: false, cancel: cancel),
        throwsA(isA<CancelledException>()));
    expect(await dir.list().toList(), isEmpty);
  });

  test('in-flight cancellation stops the process and cleans temporary files', () async {
    final cancel = CancelHandle();
    final proc = FakeProcess.held();
    final dl = YtDlp('fake', start: (_, _) async {
      Timer(const Duration(milliseconds: 10), cancel.cancel);
      return proc;
    });
    await expectLater(dl.download('BaW_jenozKc', dir, video: true, cancel: cancel),
        throwsA(isA<CancelledException>()));
    expect(proc.killed, isTrue);
    expect(await dir.list().toList(), isEmpty);
  });

  test('cancelled metadata is not converted into fallback title', () async {
    final dl = YouTubeDownloader(windows: true, ytDlp: YtDlp('fake'));
    await expectLater(dl.fetchMeta('BaW_jenozKc', cancel: CancelHandle()..cancel()),
        throwsA(isA<CancelledException>()));
  });
}
