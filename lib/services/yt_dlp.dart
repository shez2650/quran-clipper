import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/cancellation.dart' show CancelHandle, CancelledException;

/// The release ZIP keeps these next to QuranClipper.exe, independent of cwd.
String bundledYtDlpPath(String executable) =>
    p.join(p.dirname(executable), 'tools', 'yt-dlp.exe');

Future<String?> findYtDlp({String? executable, bool? windows,
    Map<String, String>? environment}) async {
  final win = windows ?? Platform.isWindows;
  if (!win && !(Platform.isMacOS || Platform.isLinux)) return null;
  final env = environment ?? Platform.environment;
  final candidates = <String>[
    if (win) bundledYtDlpPath(executable ?? Platform.resolvedExecutable),
    if (win && env['LOCALAPPDATA'] != null)
      p.join(env['LOCALAPPDATA']!, 'Microsoft', 'WinGet', 'Links', 'yt-dlp.exe'),
    if (!win) ...['/opt/homebrew/bin/yt-dlp', '/usr/local/bin/yt-dlp'],
    for (final folder in (env['PATH'] ?? env['Path'] ?? '').split(win ? ';' : ':'))
      if (folder.trim().isNotEmpty)
        p.join(folder.replaceAll('"', ''), win ? 'yt-dlp.exe' : 'yt-dlp'),
  ];
  for (final candidate in candidates) {
    if (await File(candidate).exists()) return p.absolute(candidate);
  }
  return null;
}

class YtDlpException implements Exception {
  YtDlpException(this.message);
  final String message;
  @override
  String toString() => message;
}

typedef StartDownloader = Future<Process> Function(String executable, List<String> arguments);

/// Uses separate arguments throughout; never invokes a shell.
class YtDlp {
  YtDlp(this.executable, {StartDownloader? start})
      : _start = start ?? ((exe, args) => Process.start(exe, args));
  final String executable;
  final StartDownloader _start;

  List<String> get _common {
    final deno = p.join(p.dirname(executable), 'deno.exe');
    return [
      '--ignore-config', '--no-playlist', '--no-plugin-dirs',
      '--no-remote-components', '--no-cache-dir', '--encoding', 'utf-8',
      '--socket-timeout', '20', '--retries', '2', '--fragment-retries', '2',
      if (Platform.isWindows && File(deno).existsSync())
        ...['--no-js-runtimes', '--js-runtimes', 'deno:$deno'],
    ];
  }

  Future<String> version() async {
    final lines = <String>[];
    await _run(['--ignore-config', '--version'], onLine: lines.add, timeout: const Duration(seconds: 30));
    return lines.join('\n').trim();
  }

  Future<Map<String, dynamic>> metadata(String id, {CancelHandle? cancel}) async {
    final lines = <String>[];
    await _run([..._common, '--skip-download', '--dump-single-json',
      '--', 'https://www.youtube.com/watch?v=$id'],
      cancel: cancel, onLine: lines.add, timeout: const Duration(seconds: 90));
    return jsonDecode(lines.join('\n')) as Map<String, dynamic>;
  }

  Future<String> download(String id, Directory directory, {required bool video,
      int maxHeight = 1080, CancelHandle? cancel, void Function(double)? onProgress}) async {
    if (cancel?.cancelled ?? false) throw CancelledException();
    await directory.create(recursive: true);
    // A failed/cancelled late footage download must never delete saved audio.
    final temp = await directory.createTemp('.youtube-');
    try {
      final base = video ? 'video' : 'audio';
      String? downloaded;
      await _run([
        ..._common, '--newline', '--no-simulate',
        '-f', video
            ? 'bv[height<=$maxHeight][ext=mp4][vcodec^=avc1]/bv[height<=$maxHeight][ext=mp4]/bv[height<=$maxHeight]'
            : 'ba[ext=m4a]/ba',
        '-o', p.join(temp.path, '$base.%(ext)s'),
        '--progress-template', 'download:progress:%(progress._percent_str)s',
        '--print', 'after_move:filepath',
        '--', 'https://www.youtube.com/watch?v=$id',
      ], cancel: cancel, onLine: (line) {
        final match = RegExp(r'^progress:\s*([\d.]+)%').firstMatch(line);
        if (match != null) {
          onProgress?.call((double.parse(match.group(1)!) / 100).clamp(0, 1));
        } else if (line.trim().isNotEmpty) {
          final candidate = p.normalize(p.absolute(line.trim()));
          if (p.isWithin(p.absolute(temp.path), candidate) && File(candidate).existsSync()) {
            downloaded = candidate;
          }
        }
      });
      if (cancel?.cancelled ?? false) throw CancelledException();
      if (downloaded == null || await File(downloaded!).length() == 0) {
        throw YtDlpException('YouTube returned no usable media. Try another video or open a local file.');
      }
      final target = p.join(directory.path, '$base${p.extension(downloaded!)}');
      await File(downloaded!).rename(target);
      onProgress?.call(1);
      return target;
    } finally {
      if (await temp.exists()) await temp.delete(recursive: true);
    }
  }

  Future<void> _run(List<String> arguments, {CancelHandle? cancel,
      required void Function(String) onLine, Duration? timeout}) async {
    if (cancel?.cancelled ?? false) throw CancelledException();
    final Process process;
    try {
      process = await _start(executable, arguments);
    } on ProcessException catch (e) {
      throw YtDlpException('Could not start the YouTube downloader. Extract the complete Windows ZIP again. ${e.message}');
    }
    var stopping = false;
    var timedOut = false;
    Future<void> stop() async {
      if (stopping) return;
      stopping = true;
      if (Platform.isWindows) {
        // yt-dlp's one-file launcher and JavaScript runtime are child processes.
        try {
          final result = await Process.run(p.join(Platform.environment['SystemRoot'] ?? r'C:\Windows',
              'System32', 'taskkill.exe'), ['/PID', '${process.pid}', '/T', '/F']);
          if (result.exitCode != 0) process.kill();
        } catch (_) {
          process.kill();
        }
      } else {
        process.kill(ProcessSignal.sigkill);
      }
    }

    final timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (cancel?.cancelled ?? false) unawaited(stop());
    });
    final deadline = timeout == null ? null : Timer(timeout, () {
      timedOut = true;
      unawaited(stop());
    });
    final errors = <String>[];
    try {
      await Future.wait([
        process.stdout.transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter()).forEach(onLine),
        process.stderr.transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter()).forEach((line) {
          errors.add(line);
          if (errors.length > 8) errors.removeAt(0);
        }),
      ]);
      final code = await process.exitCode;
      if (cancel?.cancelled ?? false) throw CancelledException();
      if (timedOut) throw YtDlpException('YouTube did not respond in time. Try again later.');
      if (code != 0) {
        throw YtDlpException("YouTube could not download this video. It may be unavailable, private, "
            "restricted, or blocked by YouTube. Try again later or open a local file.\n${errors.join('\n')}");
      }
    } finally {
      timer.cancel();
      deadline?.cancel();
      if (!stopping) {
        process.kill();
      }
    }
  }
}
