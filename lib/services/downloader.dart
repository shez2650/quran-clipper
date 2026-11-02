import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../platform/ffmpeg_runner.dart' show CancelHandle, CancelledException;

class VideoMeta {
  const VideoMeta({required this.id, required this.title, required this.author, this.duration});
  final String id;
  final String title;
  final String author;
  final Duration? duration;
}

class DownloadException implements Exception {
  DownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Downloads YouTube audio/video with youtube_explode (pure Dart, all
/// platforms). On desktop, falls back to a yt-dlp found on the system.
class YouTubeDownloader {
  static String? parseId(String text) {
    final match = RegExp(r'https?://\S+').firstMatch(text);
    return VideoId.parseVideoId(match?.group(0) ?? text.trim());
  }

  Future<VideoMeta> fetchMeta(String id) async {
    final yt = YoutubeExplode();
    try {
      final v = await yt.videos.get(id);
      return VideoMeta(id: id, title: v.title, author: v.author, duration: v.duration);
    } finally {
      yt.close();
    }
  }

  /// Saves the best audio-only stream into [dir] and returns the path.
  Future<String> downloadAudio(String id, Directory dir,
      {void Function(double fraction)? onProgress, CancelHandle? cancel}) async {
    try {
      return await _explode(id, dir, video: false, onProgress: onProgress, cancel: cancel);
    } on CancelledException {
      rethrow;
    } catch (e) {
      final ytdlp = await _findYtDlp();
      if (ytdlp == null) throw DownloadException('YouTube download failed: $e');
      return _ytDlp(ytdlp, id, dir, video: false, onProgress: onProgress, cancel: cancel);
    }
  }

  /// Saves a video-only stream (no sound) up to [maxHeight] into [dir].
  Future<String> downloadVideo(String id, Directory dir,
      {int maxHeight = 1080, void Function(double fraction)? onProgress, CancelHandle? cancel}) async {
    try {
      return await _explode(id, dir, video: true, maxHeight: maxHeight, onProgress: onProgress, cancel: cancel);
    } on CancelledException {
      rethrow;
    } catch (e) {
      final ytdlp = await _findYtDlp();
      if (ytdlp == null) throw DownloadException('YouTube video download failed: $e');
      return _ytDlp(ytdlp, id, dir, video: true, maxHeight: maxHeight, onProgress: onProgress, cancel: cancel);
    }
  }

  Future<String> _explode(String id, Directory dir,
      {required bool video, int maxHeight = 1080, void Function(double)? onProgress, CancelHandle? cancel}) async {
    final yt = YoutubeExplode();
    try {
      final manifest = await yt.videos.streamsClient.getManifest(id);
      StreamInfo info;
      if (video) {
        final candidates = manifest.videoOnly.where((s) => s.videoResolution.height <= maxHeight).toList();
        if (candidates.isEmpty) throw DownloadException('No video stream found.');
        // Prefer MP4/H.264 for the widest decoder support, then the tallest.
        candidates.sort((a, b) {
          final mp4 = (b.container == StreamContainer.mp4 ? 1 : 0) - (a.container == StreamContainer.mp4 ? 1 : 0);
          if (mp4 != 0) return mp4;
          return b.videoResolution.height.compareTo(a.videoResolution.height);
        });
        info = candidates.first;
      } else {
        final audio = manifest.audioOnly.toList();
        if (audio.isEmpty) throw DownloadException('No audio stream found.');
        final mp4 = audio.where((s) => s.container == StreamContainer.mp4).toList();
        info = (mp4.isNotEmpty ? mp4 : audio).withHighestBitrate();
      }
      final ext = info.container.name;
      final file = File(p.join(dir.path, video ? 'video.$ext' : 'audio.$ext'));
      final part = File('${file.path}.part');
      final total = info.size.totalBytes;
      final sink = part.openWrite();
      var got = 0;
      final done = Completer<void>();
      late StreamSubscription<List<int>> sub;
      sub = yt.videos.streamsClient.get(info).listen(
        (chunk) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) onProgress?.call(got / total);
        },
        onError: (Object e) => done.isCompleted ? null : done.completeError(e),
        onDone: () => done.isCompleted ? null : done.complete(),
        cancelOnError: true,
      );
      if (cancel != null) {
        unawaited(Future.doWhile(() async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          if (done.isCompleted) return false;
          if (cancel.cancelled) {
            await sub.cancel();
            done.completeError(CancelledException());
            return false;
          }
          return true;
        }));
      }
      try {
        await done.future;
      } finally {
        await sink.close();
      }
      if (total > 0 && got < total * 0.98) throw DownloadException('Download stopped early ($got of $total bytes).');
      if (await file.exists()) await file.delete();
      await part.rename(file.path);
      return file.path;
    } finally {
      yt.close();
    }
  }

  static Future<String?> _findYtDlp() async {
    if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) return null;
    final candidates = [
      '/opt/homebrew/bin/yt-dlp',
      '/usr/local/bin/yt-dlp',
      if (Platform.isWindows) p.join(Platform.environment['LOCALAPPDATA'] ?? '', 'Microsoft', 'WinGet', 'Links', 'yt-dlp.exe'),
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    try {
      final r = await Process.run(Platform.isWindows ? 'where' : 'which', ['yt-dlp']);
      final out = (r.stdout as String).trim().split('\n').first.trim();
      if (r.exitCode == 0 && out.isNotEmpty) return out;
    } catch (_) {}
    return null;
  }

  Future<String> _ytDlp(String exe, String id, Directory dir,
      {required bool video, int maxHeight = 1080, void Function(double)? onProgress, CancelHandle? cancel}) async {
    final base = video ? 'video' : 'audio';
    final format = video ? 'bv*[height<=$maxHeight][ext=mp4]/bv*[height<=$maxHeight]' : 'ba[ext=m4a]/ba';
    final proc = await Process.start(exe, [
      '-f', format, '--no-playlist', '--newline', '--no-part',
      '-o', p.join(dir.path, '$base.%(ext)s'),
      '--print', 'after_move:filepath',
      'https://www.youtube.com/watch?v=$id',
    ]);
    if (cancel != null) {
      unawaited(Future.doWhile(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        if (cancel.cancelled) proc.kill();
        return !cancel.cancelled;
      }));
    }
    String? path;
    final err = StringBuffer();
    proc.stderr.transform(utf8.decoder).listen(err.write);
    await proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).forEach((line) {
      final m = RegExp(r'\[download\]\s+([\d.]+)%').firstMatch(line);
      if (m != null) {
        onProgress?.call(double.parse(m.group(1)!) / 100);
      } else if (line.trim().isNotEmpty && File(line.trim()).existsSync()) {
        path = line.trim();
      }
    });
    final code = await proc.exitCode;
    if (cancel?.cancelled ?? false) throw CancelledException();
    if (code != 0 || path == null) throw DownloadException('yt-dlp failed: ${err.toString().trim()}');
    return path!;
  }
}
