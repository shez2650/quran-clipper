import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:googleapis/youtube/v3.dart' as yt;
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../platform/stay_awake.dart';
import 'storage.dart';

class PlaylistRef {
  const PlaylistRef(this.id, this.title, this.privacy);
  final String id;
  final String title;
  final String privacy;
}

class YouTubeAuthException implements Exception {
  YouTubeAuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

// On Android a link can switch straight back to the app.
final _backToApp = Platform.isAndroid
    ? '<p><a class="btn" href="intent:#Intent;action=android.intent.action.MAIN;'
        'category=android.intent.category.LAUNCHER;package=app.quranclipper.quran_clipper;end">'
        'Back to Quran Clipper</a></p>'
    : '';

final _postAuthPage = '''<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Quran Clipper</title>
<style>body{font-family:system-ui,sans-serif;background:#0b2a24;color:#f4efe2;display:grid;place-items:center;height:100vh;margin:0;text-align:center}
h1{font-weight:600}p{color:#bfd3cc}
.btn{display:inline-block;margin-top:12px;padding:14px 28px;border-radius:999px;background:#c9a75a;color:#0b2a24;font-weight:600;text-decoration:none}</style></head>
<body><div><h1>Signed in ✓</h1><p>You can close this tab and go back to Quran Clipper.</p>$_backToApp</div></body></html>''';

/// Google sign-in (loopback OAuth, same flow on every platform) and YouTube
/// Data API calls.
class YouTubeService {
  YouTubeService._();
  static final instance = YouTubeService._();

  AutoRefreshingAuthClient? _client;
  StreamSubscription<AccessCredentials>? _updates;
  String? channelTitle;

  SettingsStore get _settings => SettingsStore.instance;

  bool get isConfigured => _settings.googleClientId.isNotEmpty;
  bool get isSignedIn => _settings.googleCredentials != null;

  ClientId get _clientId =>
      ClientId(_settings.googleClientId, _settings.googleClientSecret.isEmpty ? null : _settings.googleClientSecret);

  static const _scopes = [yt.YouTubeApi.youtubeScope];

  /// Reads a client_secret_*.json downloaded from Google Cloud.
  static (String id, String secret) parseClientSecretJson(String text) {
    final j = jsonDecode(text) as Map<String, dynamic>;
    final inner = (j['installed'] ?? j['web'] ?? j) as Map<String, dynamic>;
    final id = inner['client_id'] as String?;
    if (id == null) throw const FormatException('No client_id in that file.');
    return (id, (inner['client_secret'] as String?) ?? '');
  }

  /// Opens Google's sign-in page in the browser. Google then redirects to a
  /// small web server this app runs on localhost, so the app must stay awake
  /// while the browser is in front.
  Future<void> signIn() async {
    if (!isConfigured) throw YouTubeAuthException('Add your Google OAuth client in Settings first.');
    final base = http.Client();
    try {
      final creds = await StayAwake.during(
        'Waiting for Google sign-in…',
        () => obtainAccessCredentialsViaUserConsent(
          _clientId,
          _scopes,
          base,
          (url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
          customPostAuthPage: _postAuthPage,
        ).timeout(const Duration(minutes: 5), onTimeout: () => throw YouTubeAuthException('Sign-in timed out.')),
      );
      _settings.googleCredentials = jsonEncode(creds.toJson());
      _attach(creds);
      await loadChannel();
    } finally {
      base.close();
    }
  }

  Future<void> signOut() async {
    await _updates?.cancel();
    _client?.close();
    _client = null;
    channelTitle = null;
    _settings.googleCredentials = null;
  }

  void _attach(AccessCredentials creds) {
    _updates?.cancel();
    _client?.close();
    _client = autoRefreshingClient(_clientId, creds, http.Client());
    _updates = _client!.credentialUpdates.listen((c) => _settings.googleCredentials = jsonEncode(c.toJson()));
  }

  Future<yt.YouTubeApi> _api() async {
    if (_client == null) {
      final saved = _settings.googleCredentials;
      if (saved == null) throw YouTubeAuthException('Sign in to YouTube first.');
      _attach(AccessCredentials.fromJson(jsonDecode(saved) as Map<String, dynamic>));
    }
    return yt.YouTubeApi(_client!);
  }

  /// Runs [fn]; if Google rejected the saved login (expired after 7 days in
  /// Testing mode, or revoked), forgets it so the user is asked to sign in.
  Future<T> _guard<T>(Future<T> Function(yt.YouTubeApi api) fn) async {
    try {
      return await fn(await _api());
    } on AccessDeniedException {
      await signOut();
      throw YouTubeAuthException('Your Google sign-in expired. Please sign in again.');
    } on ServerRequestFailedException {
      await signOut();
      throw YouTubeAuthException('Your Google sign-in expired. Please sign in again.');
    } on yt.DetailedApiRequestError catch (e) {
      if (e.status == 401) {
        await signOut();
        throw YouTubeAuthException('Your Google sign-in expired. Please sign in again.');
      }
      rethrow;
    }
  }

  Future<String?> loadChannel() => _guard((api) async {
        final r = await api.channels.list(['snippet'], mine: true);
        channelTitle = r.items?.firstOrNull?.snippet?.title;
        return channelTitle;
      });

  Future<List<PlaylistRef>> playlists() => _guard((api) async {
        final out = <PlaylistRef>[];
        String? page;
        do {
          final r = await api.playlists.list(['snippet', 'status'], mine: true, maxResults: 50, pageToken: page);
          for (final p in r.items ?? <yt.Playlist>[]) {
            out.add(PlaylistRef(p.id!, p.snippet?.title ?? '(untitled)', p.status?.privacyStatus ?? ''));
          }
          page = r.nextPageToken;
        } while (page != null);
        out.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
        return out;
      });

  Future<PlaylistRef> createPlaylist(String title, {String privacy = 'private'}) => _guard((api) async {
        final p = await api.playlists.insert(
          yt.Playlist(
            snippet: yt.PlaylistSnippet(title: title),
            status: yt.PlaylistStatus(privacyStatus: privacy),
          ),
          ['snippet', 'status'],
        );
        return PlaylistRef(p.id!, title, privacy);
      });

  /// Uploads [file] and returns the new video's id.
  Future<String> upload({
    required File file,
    required String title,
    String description = '',
    String privacy = 'private',
    String? playlistId,
    void Function(double fraction)? onProgress,
  }) =>
      StayAwake.during('Uploading to YouTube…', () => _upload(file, title, description, privacy, playlistId, onProgress));

  Future<String> _upload(File file, String title, String description, String privacy, String? playlistId,
          void Function(double fraction)? onProgress) =>
      _guard((api) async {
        final length = await file.length();
        var sent = 0;
        final stream = file.openRead().map((chunk) {
          sent += chunk.length;
          onProgress?.call(sent / length);
          return chunk;
        });
        final video = await api.videos.insert(
          yt.Video(
            snippet: yt.VideoSnippet(
              title: title.length > 100 ? title.substring(0, 100) : title,
              description: description,
              categoryId: '10', // Music
            ),
            status: yt.VideoStatus(privacyStatus: privacy, selfDeclaredMadeForKids: false),
          ),
          ['snippet', 'status'],
          uploadMedia: yt.Media(stream, length, contentType: 'video/mp4'),
          uploadOptions: yt.ResumableUploadOptions(chunkSize: 8 * 1024 * 1024),
          notifySubscribers: false,
        );
        if (playlistId != null) {
          await api.playlistItems.insert(
            yt.PlaylistItem(
              snippet: yt.PlaylistItemSnippet(
                playlistId: playlistId,
                resourceId: yt.ResourceId(kind: 'youtube#video', videoId: video.id),
              ),
            ),
            ['snippet'],
          );
        }
        return video.id!;
      });
}
