import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/models.dart';
import '../platform/ffmpeg_runner.dart';
import '../services/downloader.dart';
import '../services/storage.dart';
import 'mark_screen.dart';

const _mediaExtensions = [
  'mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg', 'oga', 'opus', 'amr', 'wma', '3gp',
  'mp4', 'm4v', 'mov', 'mkv', 'webm', 'avi', 'wmv', 'flv', 'ts', 'mts',
];

/// Creates a project from a YouTube link or a local file, then opens it.
class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key, this.link, this.editLink = false, this.filePath, this.pickFile = false});

  final String? link;
  final bool editLink;
  final String? filePath;
  final bool pickFile;

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  late final _link = TextEditingController(text: widget.link ?? '');
  late bool _withVideo = SettingsStore.instance.downloadVideoByDefault;
  bool _busy = false;
  String _status = '';
  double? _progress;
  String? _error;
  CancelHandle? _cancel;
  Directory? _workDir;

  bool get _fileMode => widget.pickFile || widget.filePath != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.filePath != null) {
        _importFile(widget.filePath!, p.basename(widget.filePath!), copy: true);
      } else if (widget.pickFile) {
        _pick();
      } else if (!widget.editLink && widget.link != null) {
        _importLink();
      }
    });
  }

  @override
  void dispose() {
    _cancel?.cancel();
    _link.dispose();
    super.dispose();
  }

  void _set({String? status, double? progress, bool clearProgress = false}) {
    if (!mounted) return;
    setState(() {
      if (status != null) _status = status;
      if (clearProgress) {
        _progress = null;
      } else if (progress != null) {
        _progress = progress;
      }
    });
  }

  Future<void> _fail(Object e) async {
    if (_workDir != null && await _workDir!.exists()) {
      await _workDir!.delete(recursive: true).catchError((_) => _workDir!);
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = e is CancelledException ? null : e.toString();
    });
    if (e is CancelledException && mounted) Navigator.pop(context);
  }

  Future<void> _done(Project project) async {
    await ProjectStore.instance.save(project);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => MarkScreen(project: project)));
  }

  Future<void> _pick() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Choose a video or recording',
      type: Platform.isAndroid ? FileType.any : FileType.custom,
      allowedExtensions: Platform.isAndroid ? null : _mediaExtensions,
    );
    if (file == null) {
      if (mounted) Navigator.pop(context);
      return;
    }
    final path = file.path;
    if (path != null && isDesktop) {
      await _importFile(path, file.name, copy: false);
    } else {
      await _importPlatformFile(file);
    }
  }

  /// Android hands back a content URI: copy it into the project folder.
  Future<void> _importPlatformFile(PlatformFile file) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = newId();
      _workDir = await ProjectStore.instance.createDir(id);
      final ext = p.extension(file.name).isEmpty ? '.media' : p.extension(file.name);
      final dest = File(p.join(_workDir!.path, 'source$ext'));
      _set(status: 'Copying file…', progress: 0);
      final size = await file.xFile.length();
      final sink = dest.openWrite();
      var got = 0;
      await for (final chunk in file.xFile.openRead()) {
        sink.add(chunk);
        got += chunk.length;
        if (size > 0) _set(progress: got / size);
      }
      await sink.close();
      await _finishFile(id, dest.path, file.name);
    } catch (e) {
      await _fail(e);
    }
  }

  Future<void> _importFile(String path, String name, {required bool copy}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = newId();
      var source = path;
      if (copy) {
        _workDir = await ProjectStore.instance.createDir(id);
        _set(status: 'Copying file…', clearProgress: true);
        source = (await File(path).copy(p.join(_workDir!.path, 'source${p.extension(path)}'))).path;
      }
      await _finishFile(id, source, name);
    } catch (e) {
      await _fail(e);
    }
  }

  Future<void> _finishFile(String id, String path, String name) async {
    _set(status: 'Reading file…', clearProgress: true);
    final info = await FfmpegRunner.instance.probe(path);
    if (!info.hasAudio) throw Exception('This file has no sound in it.');
    await _done(Project(
      id: id,
      title: p.basenameWithoutExtension(name),
      audioPath: path,
      videoPath: info.hasVideo ? path : null,
      duration: info.duration,
    ));
  }

  Future<void> _importLink() async {
    final id = YouTubeDownloader.parseId(_link.text);
    if (id == null) {
      setState(() => _error = "That doesn't look like a YouTube link.");
      return;
    }
    SettingsStore.instance.downloadVideoByDefault = _withVideo;
    final cancel = _cancel = CancelHandle();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final dl = YouTubeDownloader();
      _set(status: 'Looking up video…', clearProgress: true);
      final meta = await dl.fetchMeta(id);
      final projectId = newId();
      _workDir = await ProjectStore.instance.createDir(projectId);

      _set(status: 'Downloading audio…\n${meta.title}', progress: 0);
      final audio = await dl.downloadAudio(id, _workDir!, onProgress: (f) => _set(progress: f), cancel: cancel);

      String? video;
      if (_withVideo) {
        _set(status: 'Downloading video…\n${meta.title}', progress: 0);
        video = await dl.downloadVideo(id, _workDir!,
            maxHeight: SettingsStore.instance.exportDefaults.videoHeight, onProgress: (f) => _set(progress: f), cancel: cancel);
      }

      _set(status: 'Reading audio…', clearProgress: true);
      final info = await FfmpegRunner.instance.probe(audio);
      await _done(Project(
        id: projectId,
        title: meta.title,
        audioPath: audio,
        videoPath: video,
        sourceUrl: 'https://www.youtube.com/watch?v=$id',
        duration: info.duration > 0 ? info.duration : (meta.duration?.inMilliseconds ?? 0) / 1000,
      ));
    } catch (e) {
      await _fail(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(_fileMode ? 'Open file' : 'YouTube link')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: _busy ? _working(t) : (_fileMode ? _fileRetry(t) : _linkForm(t)),
          ),
        ),
      ),
    );
  }

  Widget _working(ThemeData t) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_status, textAlign: TextAlign.center, style: t.textTheme.titleMedium),
          const SizedBox(height: 20),
          LinearProgressIndicator(value: _progress, minHeight: 6, borderRadius: BorderRadius.circular(3)),
          if (_progress != null) ...[
            const SizedBox(height: 8),
            Text('${(_progress! * 100).toStringAsFixed(0)}%', style: t.textTheme.bodySmall),
          ],
          const SizedBox(height: 24),
          if (_cancel != null) TextButton(onPressed: () => _cancel?.cancel(), child: const Text('Cancel')),
        ],
      );

  Widget _fileRetry(ThemeData t) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_error != null) _ErrorBox(_error!),
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: _pick, icon: const Icon(Icons.folder_open), label: const Text('Choose a file')),
        ],
      );

  Widget _linkForm(ThemeData t) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _link,
            autofocus: _link.text.isEmpty,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: 'YouTube link',
              hintText: 'https://youtu.be/…',
              prefixIcon: const Icon(Icons.link),
              suffixIcon: IconButton(
                tooltip: 'Paste',
                icon: const Icon(Icons.content_paste),
                onPressed: () async {
                  final d = await Clipboard.getData(Clipboard.kTextPlain);
                  if (d?.text != null) _link.text = d!.text!.trim();
                },
              ),
            ),
            onSubmitted: (_) => _importLink(),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _withVideo,
            onChanged: (v) => setState(() => _withVideo = v),
            title: const Text('Also download the video'),
            subtitle: const Text('Only needed to watch while marking or to export the original footage. '
                'It can be fetched later when exporting.'),
          ),
          if (_error != null) ...[const SizedBox(height: 8), _ErrorBox(_error!)],
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _importLink,
            icon: const Icon(Icons.download),
            label: const Text('Import'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          ),
        ],
      );
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox(this.message);
  final String message;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: c.errorContainer, borderRadius: BorderRadius.circular(12)),
      child: SelectableText(message, style: TextStyle(color: c.onErrorContainer)),
    );
  }
}
