import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../platform/ffmpeg_runner.dart' show CancelHandle, CancelledException;
import 'stream_fetch.dart';

class VideoMeta {
  const VideoMeta({required this.id, required this.title, required this.author, this.duration});
  final String id;
  final String title;
  final String author;
  final Duration? duration;
}

/// Said when YouTube has temporarily blocked this connection.
const rateLimitedMessage = 'YouTube is limiting requests from this connection for now, usually after a lot of '
    'tries in a short time. Wait a while (often under an hour), or switch between Wi-Fi and mobile data, '
    'then try again.';

/// Said when YouTube lets the app list a video but refuses to send it.
const refusedMessage = "YouTube is refusing to let this app download videos at the moment. It only sends "
    'the first few seconds unless an app passes its anti-bot checks. Save the video another way, then '
    'open the file here (or share it to Quran Clipper).';

/// Said when YouTube won't play this video at all.
const unplayableMessage = "This video can't be downloaded. It may be private, age-restricted, "
    'members-only or not available in your country.';

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

  /// Ways of asking YouTube for the streams, tried in turn. In November 2026
  /// YouTube said "sign in to confirm you're not a bot" to the others, and
  /// sends only the first megabyte to this one: anything past that is a 403.
  static final clients = [YoutubeApiClient.androidSdkless];

  /// What each way of asking ran into on the last download, for diagnosing.
  final attempts = <String>[];

  static String _clientName(YoutubeApiClient c) =>
      (((c.payload['context'] as Map?)?['client'] as Map?)?['clientName'] ?? '?').toString();

  /// Headers for downloading a stream that [client] listed: the library's own,
  /// with the client's user agent when it has one, as its app would send.
  static Map<String, String> streamHeaders(YoutubeApiClient client) {
    final ua = ((client.payload['context'] as Map?)?['client'] as Map?)?['userAgent'] as String?;
    return {...YoutubeHttpClient.defaultHeaders, 'user-agent': ?ua};
  }

  Future<VideoMeta> fetchMeta(String id) async {
    final yt = YoutubeExplode();
    try {
      final v = await yt.videos.get(id);
      return VideoMeta(id: id, title: v.title, author: v.author, duration: v.duration);
    } on RequestLimitExceededException {
      throw DownloadException(rateLimitedMessage);
    } on VideoUnplayableException {
      throw DownloadException(unplayableMessage);
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
      if (ytdlp == null) throw e is DownloadException ? e : DownloadException('YouTube download failed: $e');
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
      if (ytdlp == null) throw e is DownloadException ? e : DownloadException('YouTube video download failed: $e');
      return _ytDlp(ytdlp, id, dir, video: true, maxHeight: maxHeight, onProgress: onProgress, cancel: cancel);
    }
  }

  Future<String> _explode(String id, Directory dir,
      {required bool video, int maxHeight = 1080, void Function(double)? onProgress, CancelHandle? cancel}) async {
    Object? lastProblem;
    var limited = false;
    var unplayable = 0;
    attempts.clear();
    for (final client in clients) {
      void note(Object what) => attempts.add('${_clientName(client)}: ${what.toString().split('\n').first}');
      if (cancel?.cancelled ?? false) throw CancelledException();
      final yt = YoutubeExplode();
      File? part;
      try {
        final StreamManifest manifest;
        try {
          // The watch page was already loaded for the title; asking for it
          // again only adds to what YouTube counts towards its limit.
          manifest = await yt.videos.streamsClient
              .getManifest(id, ytClients: [client], requireWatchPage: false)
              .timeout(const Duration(seconds: 30));
        } on RequestLimitExceededException catch (e) {
          note(e);
          limited = true;
          break;
        } on VideoUnplayableException catch (e) {
          // One way of asking can be told "unplayable" while another works.
          note(e);
          unplayable++;
          lastProblem = e;
          continue;
        } catch (e) {
          note(e);
          lastProblem = e;
          continue;
        }
        final info = video ? _pickVideo(manifest, maxHeight) : _pickAudio(manifest);
        if (info == null) {
          note('no suitable stream');
          continue;
        }

        final ext = info.container.name;
        final file = File(p.join(dir.path, video ? 'video.$ext' : 'audio.$ext'));
        part = File('${file.path}.part');
        final total = info.size.totalBytes;
        await fetchInChunks(
          url: info.url,
          total: total,
          into: part,
          headers: streamHeaders(client),
          cancel: cancel,
          onBytes: (got) => total > 0 ? onProgress?.call(got / total) : null,
        );
        if (await file.exists()) await file.delete();
        await part.rename(file.path);
        note('ok');
        return file.path;
      } on CancelledException {
        rethrow;
      } on StreamRateLimited catch (e) {
        note(e);
        limited = true;
        break;
      } catch (e) {
        note(e);
        lastProblem = e;
      } finally {
        yt.close();
        if (part != null && await part.exists()) {
          try {
            await part.delete();
          } catch (_) {}
        }
      }
    }
    if (cancel?.cancelled ?? false) throw CancelledException();
    if (limited) throw DownloadException(rateLimitedMessage);
    if (unplayable == clients.length) throw DownloadException(unplayableMessage);
    if (lastProblem is StreamRefused) throw DownloadException(refusedMessage);
    throw DownloadException("YouTube wouldn't let the app download this ${video ? 'video' : 'audio'}"
        "${lastProblem == null ? '' : ' ($lastProblem)'}. Try again later, or save it another way and open the file.");
  }

  static StreamInfo? _pickAudio(StreamManifest manifest) {
    final audio = manifest.audioOnly.toList();
    if (audio.isEmpty) return null;
    final mp4 = audio.where((s) => s.container == StreamContainer.mp4).toList();
    return (mp4.isNotEmpty ? mp4 : audio).withHighestBitrate();
  }

  static StreamInfo? _pickVideo(StreamManifest manifest, int maxHeight) {
    final candidates = manifest.videoOnly.where((s) => s.videoResolution.height <= maxHeight).toList();
    if (candidates.isEmpty) return null;
    // Prefer H.264 (every device decodes it), then VP9, then AV1; tallest first.
    int codecRank(VideoOnlyStreamInfo s) {
      final c = s.videoCodec.toLowerCase();
      if (c.startsWith('avc1')) return 3;
      if (c.startsWith('vp9') || c.startsWith('vp09')) return 2;
      return 1;
    }

    candidates.sort((a, b) {
      final byCodec = codecRank(b) - codecRank(a);
      if (byCodec != 0) return byCodec;
      return b.videoResolution.height.compareTo(a.videoResolution.height);
    });
    return candidates.first;
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
