import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/models.dart';
import '../core/time_format.dart';
import '../services/storage.dart';
import '../services/waveform.dart';
import 'export_screen.dart';
import 'waveform_view.dart';

class MarkScreen extends StatefulWidget {
  const MarkScreen({super.key, required this.project});
  final Project project;

  @override
  State<MarkScreen> createState() => _MarkScreenState();
}

class _MarkScreenState extends State<MarkScreen> with SingleTickerProviderStateMixin {
  Project get project => widget.project;

  late final Player _player = Player(configuration: const PlayerConfiguration(title: 'Quran Clipper'));
  VideoController? _video;
  final _waveKey = GlobalKey<WaveformViewState>();
  final _focus = FocusNode();

  Waveform? _waveform;
  String? _waveError;

  final position = ValueNotifier<double>(0);
  double _reported = 0;
  DateTime _reportedAt = DateTime.now();
  bool _playing = false;
  double _rate = 1;
  late final Ticker _ticker;
  final _subs = <StreamSubscription<dynamic>>[];

  double? _pendingStart;
  String? _selectedId;
  bool _showVideo = true;

  /// Parts to play back to back (preview), and where to stop.
  List<Segment>? _queue;
  int _queueIndex = 0;
  double? _stopAt;

  final _undo = <List<Segment>>[];
  Timer? _saveTimer;
  bool _dirty = false;

  double get _duration => project.duration > 0 ? project.duration : 1;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    HardwareKeyboard.instance.addHandler(_onKey);
    _initPlayer();
    _initWaveform();
  }

  Future<void> _initPlayer() async {
    final hasVideo = project.videoPath != null && File(project.videoPath!).existsSync();
    if (hasVideo) _video = VideoController(_player);
    try {
      final native = _player.platform as dynamic;
      await native.setProperty('hr-seek', 'yes');
      await native.setProperty('keep-open', 'yes');
    } catch (_) {}

    _subs.add(
      _player.stream.position.listen((d) {
        _reported = d.inMicroseconds / 1e6;
        _reportedAt = DateTime.now();
        if (!_playing) position.value = _reported;
        _checkStop(_reported);
      }),
    );
    _subs.add(
      _player.stream.playing.listen((p) {
        _reportedAt = DateTime.now();
        setState(() => _playing = p);
      }),
    );
    _subs.add(
      _player.stream.duration.listen((d) {
        final s = d.inMicroseconds / 1e6;
        if (s > 0 && project.duration <= 0) {
          project.duration = s;
          _changed();
        }
      }),
    );
    _subs.add(
      _player.stream.completed.listen((done) {
        if (done) _queue = null;
      }),
    );

    if (hasVideo && project.videoPath != project.audioPath) {
      await _player.open(Media(project.videoPath!), play: false);
      await _player.setAudioTrack(AudioTrack.uri(project.audioPath));
    } else {
      await _player.open(Media(hasVideo ? project.videoPath! : project.audioPath), play: false);
    }
    if (mounted) setState(() {});
  }

  Future<void> _initWaveform() async {
    try {
      final dir = await ProjectStore.instance.createDir(project.id);
      final wf = await loadWaveform(project.audioPath, dir);
      if (mounted) setState(() => _waveform = wf);
    } catch (e) {
      if (mounted) setState(() => _waveError = e.toString());
    }
  }

  void _onTick(Duration _) {
    if (!_playing) return;
    final elapsed = DateTime.now().difference(_reportedAt).inMicroseconds / 1e6;
    final t = min(_duration, _reported + elapsed * _rate);
    position.value = t;
    _checkStop(t);
  }

  void _checkStop(double t) {
    final stop = _stopAt;
    if (stop == null || t < stop) return;
    final q = _queue;
    if (q != null && _queueIndex + 1 < q.length) {
      _queueIndex++;
      final next = q[_queueIndex];
      _stopAt = next.end;
      _seek(next.start);
      setState(() => _selectedId = next.id);
    } else {
      _stopAt = null;
      _queue = null;
      _player.pause();
      _seek(stop);
      setState(() {});
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_onKey);
    if (_dirty) ProjectStore.instance.save(project);
    for (final s in _subs) {
      s.cancel();
    }
    _ticker.dispose();
    _player.dispose();
    _focus.dispose();
    position.dispose();
    super.dispose();
  }

  // ---- playback ----

  void _seek(double t) {
    t = t.clamp(0, _duration).toDouble();
    position.value = t;
    _reported = t;
    _reportedAt = DateTime.now();
    _player.seek(Duration(microseconds: (t * 1e6).round()));
  }

  void _userSeek(double t) {
    _stopAt = null;
    _queue = null;
    _seek(t);
    _waveKey.currentState?.followPlayhead();
  }

  void _toggle() {
    if (_playing) {
      _player.pause();
      _stopAt = null;
      _queue = null;
    } else {
      _player.play();
    }
  }

  void _skip(double by) => _userSeek(position.value + by);

  void _playRange(double start, double end) {
    _queue = null;
    _stopAt = end;
    _seek(start);
    _waveKey.currentState?.followPlayhead();
    _player.play();
  }

  void _playQueue(List<Segment> parts) {
    if (parts.isEmpty) return;
    _queue = List.of(parts);
    _queueIndex = 0;
    _stopAt = parts.first.end;
    setState(() => _selectedId = parts.first.id);
    _seek(parts.first.start);
    _waveKey.currentState?.followPlayhead();
    _player.play();
  }

  Future<void> _setRate(double r) async {
    await _player.setRate(r);
    setState(() => _rate = r);
  }

  // ---- editing ----

  void _remember() {
    _undo.add([for (final s in project.segments) s.copy()]);
    if (_undo.length > 50) _undo.removeAt(0);
  }

  void _changed() {
    setState(() {});
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), () {
      _dirty = false;
      ProjectStore.instance.save(project);
    });
  }

  void _undoLast() {
    if (_undo.isEmpty) return;
    project.segments = _undo.removeLast();
    _changed();
  }

  void _markStart() {
    setState(() => _pendingStart = position.value);
  }

  void _markEnd() {
    final start = _pendingStart;
    final end = position.value;
    if (start == null) {
      _toast('Press "Mark start" at the beginning of the recitation first.');
      return;
    }
    if (end - start < 0.2) {
      _toast('The end needs to be after the start. Play on a bit, then mark the end.');
      return;
    }
    _remember();
    final seg = Segment(id: newId(), start: start, end: end);
    // Keep time order unless the user has rearranged parts.
    final idx = project.segments.indexWhere((s) => s.start > start);
    if (idx == -1 || !_isSorted()) {
      project.segments.add(seg);
    } else {
      project.segments.insert(idx, seg);
    }
    _pendingStart = null;
    _selectedId = seg.id;
    _changed();
  }

  bool _isSorted() {
    for (var i = 1; i < project.segments.length; i++) {
      if (project.segments[i].start < project.segments[i - 1].start) return false;
    }
    return true;
  }

  void _delete(Segment s) {
    _remember();
    project.segments.removeWhere((e) => e.id == s.id);
    _changed();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Part deleted'),
          action: SnackBarAction(label: 'Undo', onPressed: _undoLast),
        ),
      );
  }

  void _nudge(Segment s, {required bool start, required double by}) {
    _remember();
    if (start) {
      s.start = (s.start + by).clamp(0, s.end - 0.2).toDouble();
      _seek(s.start);
    } else {
      s.end = (s.end + by).clamp(s.start + 0.2, _duration).toDouble();
      _seek(max(s.start, s.end - 2));
    }
    _changed();
  }

  Future<void> _editTime(Segment s, {required bool start}) async {
    final ctrl = TextEditingController(text: formatTime(start ? s.start : s.end, decimals: 2));
    final result = await showDialog<double>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(start ? 'Start time' : 'End time'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(helperText: 'e.g. 1:23.5 or 83.5'),
          onSubmitted: (v) => Navigator.pop(c, parseTime(v)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, position.value), child: const Text('Use playhead')),
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, parseTime(ctrl.text)), child: const Text('Set')),
        ],
      ),
    );
    if (result == null) return;
    _remember();
    if (start) {
      s.start = result.clamp(0, s.end - 0.2).toDouble();
    } else {
      s.end = result.clamp(s.start + 0.2, _duration).toDouble();
    }
    _changed();
  }

  Future<void> _rename(Segment s) async {
    final ctrl = TextEditingController(text: s.label);
    final v = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Name this part'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'e.g. Al-Mulk 1–10'),
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctrl.text), child: const Text('Save')),
        ],
      ),
    );
    if (v == null) return;
    s.label = v.trim();
    _changed();
  }

  Future<void> _renameProject() async {
    final ctrl = TextEditingController(text: project.title);
    final v = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Title'),
        content: TextField(controller: ctrl, autofocus: true, onSubmitted: (v) => Navigator.pop(c, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctrl.text), child: const Text('Save')),
        ],
      ),
    );
    if (v == null || v.trim().isEmpty) return;
    project.title = v.trim();
    _changed();
  }

  void _sortByTime() {
    _remember();
    project.segments.sort((a, b) => a.start.compareTo(b.start));
    _changed();
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _export() async {
    _player.pause();
    _saveTimer?.cancel();
    _dirty = false;
    await ProjectStore.instance.save(project);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ExportScreen(project: project)));
  }

  void _help() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (c) => const _HelpSheet(),
  );

  // ---- UI ----

  /// Keys that may auto-repeat while held.
  static final _repeatable = {
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.comma,
    LogicalKeyboardKey.period,
  };

  /// Handles shortcuts before focused buttons see them, so Space never
  /// re-presses the last clicked button. Text fields keep their keys.
  bool _onKey(KeyEvent e) {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;
    if (e is KeyUpEvent) return false;
    if (e is KeyRepeatEvent && !_repeatable.contains(e.logicalKey)) return false;
    final focused = FocusManager.instance.primaryFocus?.context?.widget;
    if (focused is EditableText) return false;
    for (final entry in _shortcuts.entries) {
      if (entry.key.accepts(e, HardwareKeyboard.instance)) {
        entry.value();
        return true;
      }
    }
    return false;
  }

  Map<SingleActivator, VoidCallback> get _shortcuts => {
    const SingleActivator(LogicalKeyboardKey.space): _toggle,
    const SingleActivator(LogicalKeyboardKey.keyI): _markStart,
    const SingleActivator(LogicalKeyboardKey.keyO): _markEnd,
    const SingleActivator(LogicalKeyboardKey.bracketLeft): _markStart,
    const SingleActivator(LogicalKeyboardKey.bracketRight): _markEnd,
    const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _skip(-1),
    const SingleActivator(LogicalKeyboardKey.arrowRight): () => _skip(1),
    const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): () => _skip(-5),
    const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): () => _skip(5),
    const SingleActivator(LogicalKeyboardKey.comma): () => _skip(-0.1),
    const SingleActivator(LogicalKeyboardKey.period): () => _skip(0.1),
    const SingleActivator(LogicalKeyboardKey.keyP): () => _playQueue(project.segments),
    const SingleActivator(LogicalKeyboardKey.equal): () => _waveKey.currentState?.zoom(0.7),
    const SingleActivator(LogicalKeyboardKey.minus): () => _waveKey.currentState?.zoom(1.4),
    const SingleActivator(LogicalKeyboardKey.escape): () => setState(() => _pendingStart = null),
    const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _undoLast,
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _undoLast,
    const SingleActivator(LogicalKeyboardKey.keyE, meta: true): _export,
    const SingleActivator(LogicalKeyboardKey.keyE, control: true): _export,
  };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      child: Scaffold(
        appBar: AppBar(
          title: GestureDetector(
            onTap: _renameProject,
            child: Text(project.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          actions: [
            IconButton(tooltip: 'How to use', icon: const Icon(Icons.help_outline), onPressed: _help),
            IconButton(tooltip: 'Undo', icon: const Icon(Icons.undo), onPressed: _undo.isEmpty ? null : _undoLast),
            Padding(
              padding: const EdgeInsets.only(right: 8, left: 4),
              child: FilledButton.icon(
                onPressed: project.segments.isEmpty ? null : _export,
                icon: const Icon(Icons.ios_share, size: 18),
                label: const Text('Export'),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _editor(t, wide)),
                    VerticalDivider(width: 1, color: t.colorScheme.outlineVariant),
                    SizedBox(width: 400, child: _partsPanel(t)),
                  ],
                )
              : Column(
                  children: [
                    _editor(t, wide),
                    Divider(height: 1, color: t.colorScheme.outlineVariant),
                    Expanded(child: _partsPanel(t)),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _editor(ThemeData t, bool wide) {
    final screenH = MediaQuery.sizeOf(context).height;
    final hasVideo = _video != null;
    final videoBox = hasVideo && _showVideo
        ? ConstrainedBox(
            constraints: BoxConstraints(maxHeight: wide ? screenH * 0.42 : screenH * 0.22),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Video(controller: _video!, controls: NoVideoControls, fill: Colors.black),
              ),
            ),
          )
        : null;

    final waveHeight = wide ? max(160.0, screenH * 0.28) : (hasVideo && _showVideo ? 120.0 : 170.0);
    final column = Column(
      mainAxisSize: wide ? MainAxisSize.max : MainAxisSize.min,
      children: [
        if (videoBox != null) ...[Center(child: videoBox), const SizedBox(height: 10)],
        SizedBox(
          height: waveHeight + 28,
          child: _waveform == null && _waveError == null
              ? _WaveLoading(theme: t)
              : _waveError != null
              ? Center(child: Text('Waveform unavailable: $_waveError', textAlign: TextAlign.center))
              : WaveformView(
                  key: _waveKey,
                  waveform: _waveform,
                  duration: _duration,
                  position: position,
                  segments: project.segments,
                  pendingStart: _pendingStart,
                  selectedId: _selectedId,
                  onSeek: _userSeek,
                  onSegmentEdited: () => setState(() {}),
                  onEditEnd: () {
                    _remember();
                    _changed();
                  },
                  follow: _playing,
                ),
        ),
        const SizedBox(height: 8),
        _transport(t, hasVideo),
        const SizedBox(height: 10),
        _markButtons(t),
        if (wide) const Spacer(),
      ],
    );
    return Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 12), child: column);
  }

  Widget _transport(ThemeData t, bool hasVideo) => Row(
    children: [
      ValueListenableBuilder<double>(
        valueListenable: position,
        builder: (context, pos, _) => Text(
          '${formatTime(pos)} / ${formatTime(_duration, decimals: 0)}',
          style: t.textTheme.labelLarge?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
        ),
      ),
      const Spacer(),
      IconButton(tooltip: 'Back 5s', icon: const Icon(Icons.replay_5), onPressed: () => _skip(-5)),
      IconButton(tooltip: 'Back 1s', icon: const Icon(Icons.keyboard_arrow_left), onPressed: () => _skip(-1)),
      IconButton.filled(
        iconSize: 30,
        tooltip: _playing ? 'Pause (Space)' : 'Play (Space)',
        icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
        onPressed: _toggle,
      ),
      IconButton(tooltip: 'Forward 1s', icon: const Icon(Icons.keyboard_arrow_right), onPressed: () => _skip(1)),
      IconButton(tooltip: 'Forward 5s', icon: const Icon(Icons.forward_5), onPressed: () => _skip(5)),
      const Spacer(),
      // Zoom items keep the menu open so you can press them repeatedly.
      MenuAnchor(
        builder: (context, menu, _) => IconButton(
          tooltip: 'More',
          icon: const Icon(Icons.tune),
          onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        ),
        menuChildren: [
          MenuItemButton(
            closeOnActivate: false,
            leadingIcon: const Icon(Icons.zoom_in),
            onPressed: () => _waveKey.currentState?.zoom(0.6),
            child: const Text('Zoom in'),
          ),
          MenuItemButton(
            closeOnActivate: false,
            leadingIcon: const Icon(Icons.zoom_out),
            onPressed: () => _waveKey.currentState?.zoom(1.6),
            child: const Text('Zoom out'),
          ),
          if (hasVideo)
            MenuItemButton(
              leadingIcon: Icon(_showVideo ? Icons.videocam_off_outlined : Icons.videocam_outlined),
              onPressed: () => setState(() => _showVideo = !_showVideo),
              child: Text(_showVideo ? 'Hide video' : 'Show video'),
            ),
          const Divider(height: 8),
          for (final r in [0.75, 1.0, 1.25, 1.5, 2.0])
            MenuItemButton(
              leadingIcon: Icon(_rate == r ? Icons.check : null),
              onPressed: () => _setRate(r),
              child: Text('Speed ${r}x'),
            ),
          const Divider(height: 8),
          MenuItemButton(
            leadingIcon: const Icon(Icons.close),
            onPressed: () {},
            child: const Text('Close'),
          ),
        ],
      ),
    ],
  );

  Widget _markButtons(ThemeData t) {
    final pending = _pendingStart;
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: _markStart,
                icon: const Icon(Icons.flag_outlined),
                label: const Text('Mark start'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(54),
                  backgroundColor: pending != null ? t.colorScheme.tertiaryContainer : null,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: pending == null ? null : _markEnd,
                icon: const Icon(Icons.sports_score),
                label: const Text('Mark end'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
              ),
            ),
          ],
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          child: pending == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Icon(Icons.radio_button_checked, size: 16, color: t.colorScheme.tertiary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Started at ${formatTime(pending)} — play on and press Mark end when the recitation stops.',
                          style: t.textTheme.bodySmall,
                        ),
                      ),
                      TextButton(onPressed: () => setState(() => _pendingStart = null), child: const Text('Clear')),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _partsPanel(ThemeData t) {
    final parts = project.segments;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
          child: Row(
            children: [
              Text('Parts', style: t.textTheme.titleMedium),
              const SizedBox(width: 8),
              if (parts.isNotEmpty)
                Text(
                  '${parts.length} · ${formatLength(project.stitchedLength)}',
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
              const Spacer(),
              if (parts.length > 1 && !_isSorted())
                IconButton(tooltip: 'Sort by time', icon: const Icon(Icons.sort), onPressed: _sortByTime),
              TextButton.icon(
                onPressed: parts.isEmpty ? null : () => _playQueue(parts),
                icon: const Icon(Icons.playlist_play),
                label: const Text('Preview all'),
              ),
            ],
          ),
        ),
        Expanded(
          child: parts.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No parts yet.\nPlay until a recitation begins, press Mark start, '
                      'then press Mark end when it finishes. Repeat for each recitation.',
                      textAlign: TextAlign.center,
                      style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                    ),
                  ),
                )
              : ReorderableListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                  buildDefaultDragHandles: false,
                  itemCount: parts.length,
                  onReorderItem: (from, to) {
                    _remember();
                    parts.insert(to, parts.removeAt(from));
                    _changed();
                  },
                  itemBuilder: (context, i) => _PartTile(
                    key: ValueKey(parts[i].id),
                    index: i,
                    segment: parts[i],
                    selected: parts[i].id == _selectedId,
                    onTap: () {
                      setState(() => _selectedId = parts[i].id);
                      _waveKey.currentState?.showTime(parts[i].start);
                      _userSeek(parts[i].start);
                    },
                    onPlay: () => _playRange(parts[i].start, parts[i].end),
                    onPlayEnd: () => _playRange(max(parts[i].start, parts[i].end - 3), parts[i].end),
                    onNudge: (start, by) => _nudge(parts[i], start: start, by: by),
                    onEditTime: (start) => _editTime(parts[i], start: start),
                    onRename: () => _rename(parts[i]),
                    onDelete: () => _delete(parts[i]),
                    onSetToPlayhead: (start) {
                      _remember();
                      final s = parts[i];
                      if (start) {
                        s.start = min(position.value, s.end - 0.2);
                      } else {
                        s.end = max(position.value, s.start + 0.2);
                      }
                      _changed();
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

class _PartTile extends StatelessWidget {
  const _PartTile({
    super.key,
    required this.index,
    required this.segment,
    required this.selected,
    required this.onTap,
    required this.onPlay,
    required this.onPlayEnd,
    required this.onNudge,
    required this.onEditTime,
    required this.onRename,
    required this.onDelete,
    required this.onSetToPlayhead,
  });

  final int index;
  final Segment segment;
  final bool selected;
  final VoidCallback onTap, onPlay, onPlayEnd, onRename, onDelete;
  final void Function(bool start, double by) onNudge;
  final void Function(bool start) onEditTime;
  final void Function(bool start) onSetToPlayhead;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = segment;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        color: selected ? t.colorScheme.secondaryContainer : null,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 4, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ReorderableDragStartListener(
                      index: index,
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(Icons.drag_indicator, color: t.colorScheme.outline),
                      ),
                    ),
                    CircleAvatar(
                      radius: 13,
                      backgroundColor: t.colorScheme.primary,
                      child: Text('${index + 1}', style: TextStyle(color: t.colorScheme.onPrimary, fontSize: 12)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.label.isEmpty ? 'Part ${index + 1}' : s.label,
                            style: t.textTheme.titleSmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(formatLength(s.length), style: t.textTheme.bodySmall),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Play this part',
                      icon: const Icon(Icons.play_circle_outline),
                      onPressed: onPlay,
                    ),
                    PopupMenuButton<String>(
                      onSelected: (v) {
                        switch (v) {
                          case 'end':
                            onPlayEnd();
                          case 'rename':
                            onRename();
                          case 'startHere':
                            onSetToPlayhead(true);
                          case 'endHere':
                            onSetToPlayhead(false);
                          case 'delete':
                            onDelete();
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'end', child: Text('Play last 3 seconds')),
                        PopupMenuItem(value: 'rename', child: Text('Rename')),
                        PopupMenuItem(value: 'startHere', child: Text('Set start to playhead')),
                        PopupMenuItem(value: 'endHere', child: Text('Set end to playhead')),
                        PopupMenuDivider(),
                        PopupMenuItem(value: 'delete', child: Text('Delete')),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    _EdgeEditor(
                      label: 'Start',
                      time: s.start,
                      onNudge: (by) => onNudge(true, by),
                      onEdit: () => onEditTime(true),
                    ),
                    _EdgeEditor(
                      label: 'End',
                      time: s.end,
                      onNudge: (by) => onNudge(false, by),
                      onEdit: () => onEditTime(false),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Start  [-]  1:23.4  [+]" with tap-to-type and long-press for 1s steps.
class _EdgeEditor extends StatelessWidget {
  const _EdgeEditor({required this.label, required this.time, required this.onNudge, required this.onEdit});
  final String label;
  final double time;
  final ValueChanged<double> onNudge;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget nudge(IconData icon, double by, String tip) => Tooltip(
      message: '$tip (hold for 1s)',
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => onNudge(by),
        onLongPress: () => onNudge(by * 10),
        child: Padding(padding: const EdgeInsets.all(6), child: Icon(icon, size: 18)),
      ),
    );
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: t.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 10),
            child: Text(label, style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ),
          nudge(Icons.remove, -0.1, '-0.1s'),
          InkWell(
            onTap: onEdit,
            child: Text(
              formatTime(time, decimals: 2),
              style: t.textTheme.labelLarge?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
          nudge(Icons.add, 0.1, '+0.1s'),
        ],
      ),
    );
  }
}

class _WaveLoading extends StatelessWidget {
  const _WaveLoading({required this.theme});
  final ThemeData theme;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(12),
    ),
    alignment: Alignment.center,
    child: const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
        SizedBox(height: 10),
        Text('Drawing waveform…'),
      ],
    ),
  );
}

class _HelpSheet extends StatelessWidget {
  const _HelpSheet();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget row(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(width: 120, child: Text(k, style: t.textTheme.labelLarge)),
          Expanded(child: Text(v)),
        ],
      ),
    );
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('How to mark', style: t.textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text(
              '1. Play until a recitation begins and press Mark start.\n'
              '2. Let it play. When the recitation stops, press Mark end.\n'
              '3. Repeat for every recitation. Talking parts are simply skipped.\n'
              '4. Fine-tune: drag the edges on the waveform, use −/+ (hold for 1s), or tap a time to type it.\n'
              '5. Press Preview all to hear the joins, then Export.',
            ),
            const SizedBox(height: 16),
            Text('Waveform', style: t.textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text(
              'Tap to jump. Drag to scroll. While playing, the view follows the playhead until you scroll; '
              'tap "Back to playhead" to follow it again. Pinch or Ctrl/⌘ + scroll to zoom. '
              'The strip underneath shows the whole file. Tap it to jump there.',
            ),
            const SizedBox(height: 16),
            Text('Keyboard (computer)', style: t.textTheme.titleMedium),
            const SizedBox(height: 4),
            row('Space', 'Play / pause'),
            row('I  or  [', 'Mark start'),
            row('O  or  ]', 'Mark end'),
            row('← / →', 'Back / forward 1s (Shift: 5s)'),
            row(', / .', 'Back / forward 0.1s'),
            row('+ / −', 'Zoom in / out'),
            row('P', 'Preview all parts'),
            row('Ctrl/⌘ Z', 'Undo'),
            row('Ctrl/⌘ E', 'Export'),
            row('Esc', 'Cancel a started mark'),
          ],
        ),
      ),
    );
  }
}
