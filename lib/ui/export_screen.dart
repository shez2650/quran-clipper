import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/models.dart';
import '../core/render.dart';
import '../core/time_format.dart';
import '../platform/ffmpeg_runner.dart';
import '../platform/stay_awake.dart';
import '../services/exporter.dart';
import '../services/storage.dart';
import 'mark_screen.dart';
import 'reverb_preview.dart';
import 'stall_hint.dart';
import 'upload_sheet.dart';

class ExportScreen extends StatefulWidget {
  const ExportScreen({super.key, required this.project});
  final Project project;

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  Project get project => widget.project;
  late ExportSettings s = SettingsStore.instance.exportDefaults;

  bool _running = false;
  String _status = '';
  double _progress = 0;
  CancelHandle? _cancel;
  final _scroll = ScrollController();
  ExportResult? _result;
  String? _error;
  Timer? _stallTimer;
  bool _stalled = false;

  bool get _canUseFootage => project.videoPath != null || project.sourceUrl != null;

  /// The whole file going straight through the reverb, with no cutting.
  bool get _reverbOnly => project.reverbOnly;

  @override
  void initState() {
    super.initState();
    if (_reverbOnly) s = s.forWholeFile();
    if (s.video == VideoMode.original && !_canUseFootage) s.video = VideoMode.stillImage;
    if (s.imagePath != null && !File(s.imagePath!).existsSync()) s.imagePath = null;
  }

  @override
  void dispose() {
    _cancel?.cancel();
    _stallTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _run({bool thenUpload = false}) async {
    final settings = s.copy();
    if (thenUpload && settings.video == VideoMode.none) settings.video = VideoMode.stillImage;
    final cancel = _cancel = CancelHandle();
    setState(() {
      _running = true;
      _error = null;
      _result = null;
      _progress = 0;
      _stalled = false;
    });
    _stallTimer?.cancel();
    _stallTimer = Timer(stallHintAfter, () {
      if (mounted && _running && _progress == 0) setState(() => _stalled = true);
    });
    // The progress card sits at the top, so bring it into view.
    _scroll.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    try {
      final r = await StayAwake.during(
        'Exporting ${project.title}…',
        () => Exporter(
          cancel: cancel,
          onStatus: (v) => mounted ? setState(() => _status = v) : null,
          onProgress: (v) => mounted
              ? setState(() {
                  _progress = v;
                  if (v > 0) _stalled = false;
                })
              : null,
        ).run(project, settings),
      );
      if (!mounted) return;
      setState(() => _result = r);
      if (thenUpload && r.videoPath != null) _upload(r.videoPath!);
    } on CancelledException {
      if (mounted) setState(() => _status = 'Cancelled');
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      _stallTimer?.cancel();
      if (mounted) {
        setState(() {
          _running = false;
          _stalled = false;
        });
      }
    }
  }

  /// From the reverb-only screen: mark parts by hand instead.
  Future<void> _clipInstead() async {
    project.useForClipping();
    await ProjectStore.instance.save(project);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => MarkScreen(project: project)));
  }

  void _saveDefaults() {
    final store = SettingsStore.instance;
    store.exportDefaults = _reverbOnly ? s.defaultsKeeping(store.exportDefaults) : s.copy();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved as your default settings')));
  }

  Future<void> _pickImage() async {
    final f = await FilePicker.pickFile(type: FileType.image, dialogTitle: 'Choose a picture');
    if (f == null) return;
    var path = f.path;
    if (path == null || Platform.isAndroid) {
      final dir = await ProjectStore.instance.createDir(project.id);
      final dest = File(p.join(dir.path, 'cover${p.extension(f.name)}'));
      final sink = dest.openWrite();
      await sink.addStream(f.xFile.openRead());
      await sink.close();
      path = dest.path;
    }
    setState(() => s.imagePath = path);
  }

  String _description() {
    final b = StringBuffer();
    if (project.sourceUrl != null) b.writeln('Source: ${project.sourceUrl}\n');
    if (_reverbOnly) {
      b.writeln('Masjid reverb added with Quran Clipper.');
      return b.toString();
    }
    b.writeln('Parts:');
    for (var i = 0; i < project.segments.length; i++) {
      final seg = project.segments[i];
      b.writeln('${i + 1}. ${seg.label.isEmpty ? '' : '${seg.label} '}(${formatTime(seg.start, decimals: 0)}–${formatTime(seg.end, decimals: 0)})');
    }
    b.writeln('\nStitched with Quran Clipper.');
    return b.toString();
  }

  void _upload(String videoPath) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => UploadSheet(videoPath: videoPath, title: project.title, description: _description()),
      );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final total = stitchedDuration(project.segments, s);
    return Scaffold(
      appBar: AppBar(
        title: Text(_reverbOnly ? 'Masjid reverb' : 'Export'),
        actions: [
          if (_reverbOnly)
            TextButton.icon(
              onPressed: _running ? null : _clipInstead,
              icon: const Icon(Icons.content_cut),
              label: const Text('Clip instead'),
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(Icons.graphic_eq, color: t.colorScheme.primary, size: 32),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(project.title, style: t.textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                            Text(
                                '${_reverbOnly ? 'Whole file' : '${project.segments.length} part${project.segments.length == 1 ? '' : 's'}'}'
                                ' → ${formatTime(total, decimals: 0)} long',
                                style: t.textTheme.bodyMedium),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_running || _result != null || _error != null) ...[const SizedBox(height: 12), _statusCard(t)],
              if (_reverbOnly) ...[
                _section(t, 'Reverb'),
                Text(
                  'A long, dark, wide echo with a light clean-up of the voice. '
                  'Adds ${reverbTailSeconds.toStringAsFixed(0)} seconds at the end for it to ring out.',
                  style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                ..._reverbControls(),
              ],
              _section(t, 'Audio format'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final f in AudioFormat.values)
                    ChoiceChip(
                      label: Text(f.label),
                      selected: s.format == f,
                      onSelected: _running ? null : (_) => setState(() => s.format = f),
                    ),
                ],
              ),
              if (s.format.lossy) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('Quality'),
                    const SizedBox(width: 16),
                    DropdownButton<int>(
                      value: s.bitrateKbps,
                      onChanged: _running ? null : (v) => setState(() => s.bitrateKbps = v!),
                      items: [
                        for (final b in const [96, 128, 160, 192, 256, 320])
                          DropdownMenuItem(value: b, child: Text('$b kbps${b == 192 ? ' (recommended)' : ''}')),
                      ],
                    ),
                  ],
                ),
              ],
              if (!_reverbOnly) ...[
                _section(t, 'Between parts'),
                RadioGroup<JoinMode>(
                  groupValue: s.join,
                  onChanged: (v) => _running ? null : setState(() => s.join = v!),
                  child: Column(
                    children: [
                      for (final j in JoinMode.values)
                        RadioListTile<JoinMode>(
                          value: j,
                          contentPadding: EdgeInsets.zero,
                          title: Text(j.label),
                          subtitle: Text(j.description),
                        ),
                    ],
                  ),
                ),
                if (s.join != JoinMode.hardCut)
                  Row(
                    children: [
                      SizedBox(width: 110, child: Text('${s.join == JoinMode.gap ? 'Gap' : 'Fade'}: ${s.joinSeconds.toStringAsFixed(1)}s')),
                      Expanded(
                        child: Slider(
                          min: 0.1,
                          max: s.join == JoinMode.gap ? 5 : 3,
                          divisions: s.join == JoinMode.gap ? 49 : 29,
                          value: s.joinSeconds.clamp(0.1, s.join == JoinMode.gap ? 5 : 3).toDouble(),
                          onChanged: _running ? null : (v) => setState(() => s.joinSeconds = v),
                        ),
                      ),
                    ],
                  ),
              ],
              _section(t, 'Extras'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Even out the volume'),
                subtitle: const Text('Loudness normalisation, useful when parts were recorded at different levels'),
                value: s.normalize,
                onChanged: _running ? null : (v) => setState(() => s.normalize = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Fade in at the start and out at the end'),
                value: s.fadeEdges,
                onChanged: _running ? null : (v) => setState(() => s.fadeEdges = v),
              ),
              if (!_reverbOnly) ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Masjid reverb'),
                  subtitle: Text(
                    'A long, dark, wide echo with a light clean-up of the voice. '
                    'Adds ${reverbTailSeconds.toStringAsFixed(0)} seconds at the end for it to ring out.',
                  ),
                  value: s.masjidReverb,
                  onChanged: _running ? null : (v) => setState(() => s.masjidReverb = v),
                ),
                if (s.masjidReverb) ...[const SizedBox(height: 4), ..._reverbControls()],
              ],
              _section(t, 'Video'),
              RadioGroup<VideoMode>(
                groupValue: s.video,
                onChanged: (v) => _running ? null : setState(() => s.video = v!),
                child: Column(
                  children: [
                    for (final v in VideoMode.values)
                      RadioListTile<VideoMode>(
                        value: v,
                        enabled: v != VideoMode.original || _canUseFootage,
                        contentPadding: EdgeInsets.zero,
                        title: Text(v.label),
                        subtitle: Text(v == VideoMode.original && !_canUseFootage
                            ? 'This source has no picture'
                            : v == VideoMode.original && project.videoPath == null
                                ? '${_videoDescription(v)} (video will be downloaded)'
                                : _videoDescription(v)),
                      ),
                  ],
                ),
              ),
              if (s.video == VideoMode.stillImage)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      if (s.imagePath != null)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(File(s.imagePath!), width: 96, height: 54, fit: BoxFit.cover),
                        )
                      else
                        Container(
                          width: 96,
                          height: 54,
                          decoration: BoxDecoration(color: const Color(0xFF123C33), borderRadius: BorderRadius.circular(8)),
                          alignment: Alignment.center,
                          child: const Text('Title card', style: TextStyle(color: Color(0xFFC9A75A), fontSize: 11)),
                        ),
                      const SizedBox(width: 12),
                      OutlinedButton(onPressed: _running ? null : _pickImage, child: const Text('Choose picture')),
                      if (s.imagePath != null)
                        TextButton(
                          onPressed: _running ? null : () => setState(() => s.imagePath = null),
                          child: const Text('Use title card'),
                        ),
                    ],
                  ),
                ),
              if (s.video != VideoMode.none)
                Row(
                  children: [
                    const Text('Resolution'),
                    const SizedBox(width: 16),
                    DropdownButton<int>(
                      value: s.videoHeight,
                      onChanged: _running ? null : (v) => setState(() => s.videoHeight = v!),
                      items: const [
                        DropdownMenuItem(value: 480, child: Text('480p')),
                        DropdownMenuItem(value: 720, child: Text('720p')),
                        DropdownMenuItem(value: 1080, child: Text('1080p')),
                      ],
                    ),
                  ],
                ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _running ? null : _saveDefaults,
                  icon: const Icon(Icons.bookmark_add_outlined),
                  label: const Text('Make these my defaults'),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _running ? null : () => _run(),
                icon: const Icon(Icons.save_alt),
                label: Text(s.video == VideoMode.none ? 'Export ${s.format.label}' : 'Export ${s.format.label} + video'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _running ? null : () => _run(thenUpload: true),
                icon: const Icon(Icons.smart_display_outlined),
                label: const Text('Export and upload to YouTube'),
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              ),
              if (s.video == VideoMode.none)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'YouTube needs a video, so a still-image video is made automatically for the upload.',
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _videoDescription(VideoMode v) => _reverbOnly && v == VideoMode.original ? 'Keep the video' : v.description;

  List<Widget> _reverbControls() => [
        Row(
          children: [
            const Text('Amount'),
            const SizedBox(width: 16),
            Expanded(
              child: SegmentedButton<ReverbAmount>(
                segments: [
                  for (final a in ReverbAmount.values) ButtonSegment(value: a, label: Text(a.label)),
                ],
                selected: {s.reverbAmount},
                onSelectionChanged: _running ? null : (v) => setState(() => s.reverbAmount = v.first),
              ),
            ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Sparkle'),
          subtitle: const Text('A faint shimmer an octave above the voice'),
          value: s.reverbSparkle,
          onChanged: _running ? null : (v) => setState(() => s.reverbSparkle = v),
        ),
        ReverbPreview(project: project, settings: s, enabled: !_running),
      ];

  Widget _section(ThemeData t, String title) => Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 8),
        child: Text(title, style: t.textTheme.titleMedium?.copyWith(color: t.colorScheme.primary)),
      );

  Widget _statusCard(ThemeData t) {
    if (_running) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(_status, style: t.textTheme.titleSmall)),
                  Text('${(_progress * 100).toStringAsFixed(0)}%'),
                ],
              ),
              const SizedBox(height: 10),
              LinearProgressIndicator(value: _progress, minHeight: 6, borderRadius: BorderRadius.circular(3)),
              if (_stalled) const StallHint(),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: () => _cancel?.cancel(), child: const Text('Cancel')),
              ),
            ],
          ),
        ),
      );
    }
    if (_error != null) {
      return Card(
        color: t.colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SelectableText('Export failed:\n$_error', style: TextStyle(color: t.colorScheme.onErrorContainer)),
        ),
      );
    }
    final r = _result!;
    return Card(
      color: t.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.check_circle, color: t.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Done: ${formatTime(r.duration, decimals: 0)} long · took ${formatLength(r.took.inMilliseconds / 1000)}',
                    style: t.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _FileRow(path: r.audioPath),
            if (r.videoPath != null) ...[
              _FileRow(path: r.videoPath!),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: () => _upload(r.videoPath!),
                icon: const Icon(Icons.smart_display_outlined),
                label: const Text('Upload video to YouTube'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One exported file with open / share / save actions.
class _FileRow extends StatelessWidget {
  const _FileRow({required this.path});
  final String path;

  Future<void> _reveal() async {
    if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
    } else if (Platform.isWindows) {
      await Process.run('explorer', ['/select,', path]);
    }
  }

  Future<void> _saveAs(BuildContext context) async {
    final bytes = await File(path).readAsBytes();
    final ext = p.extension(path).replaceFirst('.', '');
    final mime = const {
          'mp3': 'audio/mpeg',
          'm4a': 'audio/mp4',
          'opus': 'audio/ogg',
          'wav': 'audio/wav',
          'flac': 'audio/flac',
          'mp4': 'video/mp4',
        }[ext] ??
        'application/octet-stream';
    final uri = await FilePicker.saveFile(fileName: p.basename(path), bytes: bytes, mimeType: mime);
    if (uri != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final name = p.basename(path);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(name.endsWith('.mp4') ? Icons.movie_outlined : Icons.audio_file_outlined, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(name, style: t.textTheme.bodyMedium, overflow: TextOverflow.ellipsis)),
          if (isDesktop) ...[
            IconButton(
              tooltip: 'Open',
              icon: const Icon(Icons.play_arrow),
              onPressed: () => launchUrl(Uri.file(path)),
            ),
            IconButton(
              tooltip: Platform.isMacOS ? 'Show in Finder' : 'Show in folder',
              icon: const Icon(Icons.folder_open),
              onPressed: _reveal,
            ),
          ] else ...[
            IconButton(tooltip: 'Save to…', icon: const Icon(Icons.save_alt), onPressed: () => _saveAs(context)),
          ],
          IconButton(
            tooltip: 'Share',
            icon: const Icon(Icons.share),
            onPressed: () => SharePlus.instance.share(ShareParams(files: [XFile(path)])),
          ),
        ],
      ),
    );
  }
}
