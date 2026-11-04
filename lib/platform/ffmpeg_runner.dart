import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

class MediaInfo {
  const MediaInfo({required this.duration, required this.hasAudio, required this.hasVideo});
  final double duration;
  final bool hasAudio;
  final bool hasVideo;
}

class FfmpegException implements Exception {
  FfmpegException(this.message, [this.log = '']);
  final String message;
  final String log;

  /// The last few meaningful lines of ffmpeg's output.
  String get tail {
    final lines = log.split('\n').where((l) => l.trim().isNotEmpty).toList();
    return lines.skip(lines.length > 6 ? lines.length - 6 : 0).join('\n');
  }

  @override
  String toString() => '$message\n$tail';
}

class CancelledException implements Exception {
  @override
  String toString() => 'Cancelled';
}

/// Lets a caller stop a running ffmpeg job.
class CancelHandle {
  bool cancelled = false;
  FutureOr<void> Function()? _onCancel;

  Future<void> cancel() async {
    cancelled = true;
    await _onCancel?.call();
  }
}

/// How long a cancelled ffmpeg job gets to stop before it's given up on.
const cancelGiveUpAfter = Duration(seconds: 3);

abstract class FfmpegRunner {
  /// Swapped for [ProcessFfmpegRunner] in tests.
  static FfmpegRunner instance = KitFfmpegRunner();

  /// Runs ffmpeg. [onProgress] gets seconds of output written so far.
  Future<void> run(List<String> args, {void Function(double seconds)? onProgress, CancelHandle? cancel});

  Future<MediaInfo> probe(String path);
}

/// FFmpegKit plugin: the same ffmpeg build on Android, macOS and Windows.
class KitFfmpegRunner extends FfmpegRunner {
  bool _configured = false;

  Future<void> _configure() async {
    if (_configured) return;
    _configured = true;
    try {
      await FFmpegKitConfig.enableLogs();
    } catch (_) {}
  }

  @override
  Future<void> run(List<String> args, {void Function(double seconds)? onProgress, CancelHandle? cancel}) async {
    await _configure();
    if (cancel?.cancelled ?? false) throw CancelledException();
    final done = Completer<void>();
    final session = await FFmpegKit.executeWithArgumentsAsync(
      args,
      (session) async {
        if (done.isCompleted) {
          // It was given up on, and has only now stopped. Don't leave its output.
          try {
            await File(args.last).delete();
          } catch (_) {}
          return;
        }
        final code = await session.getReturnCode();
        if (ReturnCode.isSuccess(code)) {
          done.complete();
        } else if (ReturnCode.isCancel(code) || (cancel?.cancelled ?? false)) {
          done.completeError(CancelledException());
        } else {
          final log = await session.getAllLogsAsString() ?? '';
          done.completeError(FfmpegException('ffmpeg failed (code ${code?.getValue()})', log));
        }
      },
      null,
      onProgress == null ? null : (stats) => onProgress(stats.getTime() / 1000.0),
    );
    if (cancel != null) {
      cancel._onCancel = () {
        FFmpegKit.cancel(session.getSessionId());
        // FFmpeg can't stop while the system is holding up a file it's opening,
        // for instance behind a macOS privacy prompt. Don't make the user wait.
        Timer(cancelGiveUpAfter, () {
          if (!done.isCompleted) done.completeError(CancelledException());
        });
      };
    }
    return done.future;
  }

  @override
  Future<MediaInfo> probe(String path) async {
    await _configure();
    final session = await FFprobeKit.getMediaInformation(path);
    final info = session.getMediaInformation();
    if (info == null) {
      final log = await session.getAllLogsAsString() ?? '';
      throw FfmpegException('Could not read this file. Is it an audio or video file?', log);
    }
    final streams = info.getStreams();
    return MediaInfo(
      duration: double.tryParse(info.getDuration() ?? '') ?? 0,
      hasAudio: streams.any((s) => s.getType() == 'audio'),
      hasVideo: streams.any((s) {
        if (s.getType() != 'video') return false;
        // Cover art in MP3/M4A shows up as a one-frame video stream.
        final disposition = s.getProperty('disposition');
        return !(disposition is Map && disposition['attached_pic'] == 1);
      }),
    );
  }
}

/// Uses ffmpeg/ffprobe executables. Used by tests and as a fallback.
class ProcessFfmpegRunner extends FfmpegRunner {
  ProcessFfmpegRunner({this.ffmpeg = 'ffmpeg', this.ffprobe = 'ffprobe'});
  final String ffmpeg;
  final String ffprobe;

  @override
  Future<void> run(List<String> args, {void Function(double seconds)? onProgress, CancelHandle? cancel}) async {
    final p = await Process.start(ffmpeg, ['-progress', 'pipe:1', '-nostats', ...args]);
    if (cancel != null) cancel._onCancel = () => p.kill();
    final err = StringBuffer();
    p.stderr.transform(utf8.decoder).listen(err.write);
    p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (line.startsWith('out_time_us=') && onProgress != null) {
        final us = int.tryParse(line.substring(12));
        if (us != null) onProgress(us / 1e6);
      }
    });
    final code = await p.exitCode;
    if (cancel?.cancelled ?? false) throw CancelledException();
    if (code != 0) throw FfmpegException('ffmpeg failed (code $code)', err.toString());
  }

  @override
  Future<MediaInfo> probe(String path) async {
    final r = await Process.run(ffprobe, [
      '-v', 'error', '-show_entries', 'format=duration:stream=codec_type:stream_disposition=attached_pic', '-of', 'json', path,
    ]);
    if (r.exitCode != 0) throw FfmpegException('Could not read this file.', r.stderr as String);
    final j = jsonDecode(r.stdout as String) as Map<String, dynamic>;
    final streams = ((j['streams'] as List?) ?? []).cast<Map>();
    return MediaInfo(
      duration: double.tryParse(((j['format'] as Map?)?['duration'] ?? '').toString()) ?? 0,
      hasAudio: streams.any((s) => s['codec_type'] == 'audio'),
      hasVideo: streams.any((s) => s['codec_type'] == 'video' && (s['disposition'] as Map?)?['attached_pic'] != 1),
    );
  }
}
