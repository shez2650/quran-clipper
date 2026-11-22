import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import '../lib/services/yt_dlp.dart';

Future<void> main(List<String> args) async {
  final exe = await findYtDlp();
  final expected = bundledYtDlpPath(Platform.resolvedExecutable);
  if (exe == null || !p.equals(exe, expected)) {
    throw StateError('Did not resolve the packaged executable: $exe (expected $expected)');
  }
  final dl = YtDlp(exe);
  final version = await dl.version();
  if (version != '2026.10.26') throw StateError('Unexpected version: $version');
  final deno = await Process.run(p.join(p.dirname(exe), 'deno.exe'), ['--version']);
  if (deno.exitCode != 0 || !(deno.stdout as String).startsWith('deno 2.9.8')) {
    throw StateError('Bundled JavaScript runtime failed: ${deno.stderr}');
  }
  final report = <String, Object?>{
    'packagedDownloader': exe, 'version': version, 'systemPath': Platform.environment['PATH'],
    'bundledRuntime': true, 'liveDownload': 'not requested',
  };
  if (args.contains('--live')) {
    final dir = await Directory.systemTemp.createTemp('Quran Clipper live smoke ');
    try {
      final id = Platform.environment['LIVE_YOUTUBE_ID'] ?? 'dzLTlrwvuKs'; // Existing repository live-test video.
      report['title'] = (await dl.metadata(id))['title'];
      final audio = await dl.download(id, dir, video: false);
      final video = await dl.download(id, dir, video: true, maxHeight: 360);
      report['audioBytes'] = await File(audio).length();
      report['videoBytes'] = await File(video).length();
      report['liveDownload'] = 'passed';
    } catch (e) {
      // Hosted runners can be blocked by YouTube. Preserve the real outcome.
      report['liveDownload'] = 'failed';
      report['liveError'] = e.toString();
    } finally {
      await dir.delete(recursive: true);
    }
  }
  await File('windows-downloader-smoke.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(report));
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
}
