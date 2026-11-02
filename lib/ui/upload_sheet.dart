import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/storage.dart';
import '../services/youtube_service.dart';
import 'settings_screen.dart';

/// Sign in, choose title / playlist, and upload one video.
class UploadSheet extends StatefulWidget {
  const UploadSheet({super.key, required this.videoPath, required this.title, required this.description});
  final String videoPath;
  final String title;
  final String description;

  @override
  State<UploadSheet> createState() => _UploadSheetState();
}

class _UploadSheetState extends State<UploadSheet> {
  final yt = YouTubeService.instance;
  late final _title = TextEditingController(text: widget.title);
  late final _desc = TextEditingController(text: widget.description);
  String _privacy = SettingsStore.instance.youtubePrivacy;
  List<PlaylistRef>? _playlists;
  String? _playlistId = SettingsStore.instance.lastPlaylistId;
  bool _busy = false;
  double? _progress;
  String? _error;
  String? _uploadedId;

  @override
  void initState() {
    super.initState();
    if (yt.isSignedIn) _loadAccount();
  }

  Future<void> _guard(Future<void> Function() fn) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await fn();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadAccount() => _guard(() async {
        if (yt.channelTitle == null) await yt.loadChannel();
        final lists = await yt.playlists();
        if (!mounted) return;
        setState(() {
          _playlists = lists;
          if (_playlistId != null && !lists.any((l) => l.id == _playlistId)) _playlistId = null;
        });
      });

  Future<void> _signIn() => _guard(() async {
        await yt.signIn();
        await _loadAccount();
      });

  Future<void> _newPlaylist() async {
    final ctrl = TextEditingController(text: 'Quran recitations');
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('New private playlist'),
        content: TextField(controller: ctrl, autofocus: true, onSubmitted: (v) => Navigator.pop(c, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctrl.text), child: const Text('Create')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await _guard(() async {
      final p = await yt.createPlaylist(name.trim());
      setState(() {
        _playlists = [...?_playlists, p];
        _playlistId = p.id;
      });
    });
  }

  Future<void> _upload() => _guard(() async {
        SettingsStore.instance.youtubePrivacy = _privacy;
        SettingsStore.instance.lastPlaylistId = _playlistId;
        setState(() => _progress = 0);
        final id = await yt.upload(
          file: File(widget.videoPath),
          title: _title.text.trim().isEmpty ? widget.title : _title.text.trim(),
          description: _desc.text,
          privacy: _privacy,
          playlistId: _playlistId,
          onProgress: (f) => mounted ? setState(() => _progress = f) : null,
        );
        if (mounted) setState(() => _uploadedId = id);
      });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Upload to YouTube', style: t.textTheme.titleLarge),
              const SizedBox(height: 12),
              ..._body(t),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: t.colorScheme.errorContainer, borderRadius: BorderRadius.circular(12)),
                  child: SelectableText(_error!, style: TextStyle(color: t.colorScheme.onErrorContainer)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _body(ThemeData t) {
    if (!yt.isConfigured) {
      return [
        const Text('To upload, the app needs your own Google API client (free, about 5 minutes to set up). '
            'Settings has step-by-step instructions.'),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () async {
            await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
            if (mounted) setState(() {});
          },
          child: const Text('Open Settings'),
        ),
      ];
    }
    if (!yt.isSignedIn) {
      return [
        const Text('Sign in with the Google account that owns your YouTube channel. '
            'Your browser will open. Come back here when it says "Signed in".'),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _busy ? null : _signIn,
          icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.login),
          label: const Text('Sign in with Google'),
        ),
      ];
    }
    if (_uploadedId != null) {
      return [
        Row(children: [
          Icon(Icons.check_circle, color: t.colorScheme.primary),
          const SizedBox(width: 8),
          const Expanded(child: Text('Uploaded. YouTube may take a few minutes to process it.')),
        ]),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () => launchUrl(Uri.parse('https://youtu.be/$_uploadedId'), mode: LaunchMode.externalApplication),
          icon: const Icon(Icons.open_in_new),
          label: const Text('Open on YouTube'),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ];
    }
    final uploading = _busy && _progress != null;
    return [
      if (yt.channelTitle != null)
        Row(children: [
          const Icon(Icons.account_circle_outlined, size: 20),
          const SizedBox(width: 6),
          Expanded(child: Text(yt.channelTitle!, style: t.textTheme.bodyMedium)),
          TextButton(
            onPressed: _busy
                ? null
                : () async {
                    await yt.signOut();
                    setState(() {});
                  },
            child: const Text('Sign out'),
          ),
        ]),
      const SizedBox(height: 8),
      TextField(controller: _title, enabled: !uploading, decoration: const InputDecoration(labelText: 'Title'), maxLength: 100),
      const SizedBox(height: 4),
      TextField(
        controller: _desc,
        enabled: !uploading,
        decoration: const InputDecoration(labelText: 'Description'),
        minLines: 2,
        maxLines: 5,
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        initialValue: _privacy,
        decoration: const InputDecoration(labelText: 'Visibility'),
        items: const [
          DropdownMenuItem(value: 'private', child: Text('Private')),
          DropdownMenuItem(value: 'unlisted', child: Text('Unlisted')),
          DropdownMenuItem(value: 'public', child: Text('Public')),
        ],
        onChanged: uploading ? null : (v) => setState(() => _privacy = v!),
      ),
      if (_privacy != 'private')
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Uploads from personal API projects that Google has not reviewed are locked to Private by YouTube.',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: _playlists == null
                ? const LinearProgressIndicator()
                : DropdownButtonFormField<String?>(
                    initialValue: _playlistId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Add to playlist'),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('None')),
                      for (final p in _playlists!)
                        DropdownMenuItem<String?>(value: p.id, child: Text(p.title, overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: uploading ? null : (v) => setState(() => _playlistId = v),
                  ),
          ),
          IconButton(tooltip: 'New playlist', onPressed: _busy ? null : _newPlaylist, icon: const Icon(Icons.playlist_add)),
        ],
      ),
      const SizedBox(height: 20),
      if (uploading) ...[
        Text('Uploading… ${((_progress ?? 0) * 100).toStringAsFixed(0)}%'),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: _progress, minHeight: 6, borderRadius: BorderRadius.circular(3)),
      ] else
        FilledButton.icon(
          onPressed: _busy ? null : _upload,
          icon: const Icon(Icons.cloud_upload_outlined),
          label: const Text('Upload'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
        ),
    ];
  }
}
