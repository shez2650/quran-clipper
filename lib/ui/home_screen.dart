import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../core/models.dart';
import '../core/time_format.dart';
import '../services/downloader.dart';
import '../services/storage.dart';
import 'import_screen.dart';
import 'mark_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  StreamSubscription<List<SharedMediaFile>>? _shareSub;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      _shareSub = ReceiveSharingIntent.instance.getMediaStream().listen(_onShared, onError: (_) {});
      ReceiveSharingIntent.instance.getInitialMedia().then((files) {
        _onShared(files);
        ReceiveSharingIntent.instance.reset();
      });
    }
  }

  @override
  void dispose() {
    _shareSub?.cancel();
    super.dispose();
  }

  /// Something was shared to the app from another Android app.
  void _onShared(List<SharedMediaFile> files) {
    if (files.isEmpty || !mounted) return;
    final f = files.first;
    if (f.type == SharedMediaType.text || f.type == SharedMediaType.url) {
      final text = '${f.path} ${f.message ?? ''}';
      if (YouTubeDownloader.parseId(text) != null) _open(ImportScreen(link: text));
    } else if (File(f.path).existsSync()) {
      _open(ImportScreen(filePath: f.path));
    }
  }

  Future<void> _open(Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  Future<void> _newFromLink() async {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clip?.text ?? '';
    if (!mounted) return;
    await _open(ImportScreen(link: YouTubeDownloader.parseId(text) != null ? text.trim() : null, editLink: true));
  }

  Future<void> _delete(Project p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete project?'),
        content: Text('"${p.title}" and its downloaded files will be removed. Files you exported are kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) await ProjectStore.instance.delete(p);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Quran Clipper'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => _open(const SettingsScreen()),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: ProjectStore.instance,
        builder: (context, _) {
          final projects = ProjectStore.instance.projects;
          if (projects.isEmpty) return _Empty(onLink: _newFromLink, onFile: () => _open(const ImportScreen(pickFile: true)));
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
            itemCount: projects.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              final p = projects[i];
              return Card(
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  contentPadding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  leading: CircleAvatar(
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Icon(
                      p.sourceUrl != null ? Icons.smart_display_outlined : (p.videoPath != null ? Icons.movie_outlined : Icons.graphic_eq),
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  title: Text(p.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${p.segments.length} part${p.segments.length == 1 ? '' : 's'}'
                    ' · ${formatLength(p.stitchedLength)} of ${formatLength(p.duration)}'
                    ' · ${_ago(p.updated)}',
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) => v == 'delete' ? _delete(p) : null,
                    itemBuilder: (_) => const [PopupMenuItem(value: 'delete', child: Text('Delete'))],
                  ),
                  onTap: () => _open(MarkScreen(project: p)),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: ListenableBuilder(
        listenable: ProjectStore.instance,
        builder: (context, _) => ProjectStore.instance.projects.isEmpty
            ? const SizedBox.shrink()
            : _NewButtons(onLink: _newFromLink, onFile: () => _open(const ImportScreen(pickFile: true))),
      ),
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    if (d.inDays < 30) return '${d.inDays}d ago';
    return '${t.day}/${t.month}/${t.year}';
  }
}

class _NewButtons extends StatelessWidget {
  const _NewButtons({required this.onLink, required this.onFile});
  final VoidCallback onLink;
  final VoidCallback onFile;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.extended(
            heroTag: 'file',
            onPressed: onFile,
            icon: const Icon(Icons.folder_open),
            label: const Text('File'),
            backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
          ),
          const SizedBox(width: 12),
          FloatingActionButton.extended(
            heroTag: 'link',
            onPressed: onLink,
            icon: const Icon(Icons.link),
            label: const Text('YouTube link'),
          ),
        ],
      );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onLink, required this.onFile});
  final VoidCallback onLink;
  final VoidCallback onFile;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.auto_awesome_motion_outlined, size: 72, color: t.colorScheme.primary),
              const SizedBox(height: 20),
              Text('Stitch recitations together', style: t.textTheme.headlineSmall, textAlign: TextAlign.center),
              const SizedBox(height: 10),
              Text(
                'Open a video or recording, mark where each recitation starts and ends, '
                'and get one continuous recitation without the talking in between.',
                style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: onLink,
                  icon: const Icon(Icons.link),
                  label: const Text('Paste a YouTube link'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: onFile,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Open a video or audio file'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
