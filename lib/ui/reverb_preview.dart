import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';
import '../core/render.dart';
import '../core/time_format.dart';
import '../platform/ffmpeg_runner.dart';
import '../services/reverb.dart';

const _previewSeconds = 20.0;

/// Renders a short stretch with the current settings, so they can be judged
/// by ear without a full export. Switches between "with reverb" and "original"
/// at the same moment, to compare them.
class ReverbPreview extends StatefulWidget {
  const ReverbPreview({super.key, required this.project, required this.settings, required this.enabled});

  final Project project;
  final ExportSettings settings;
  final bool enabled;

  @override
  State<ReverbPreview> createState() => _ReverbPreviewState();
}

class _ReverbPreviewState extends State<ReverbPreview> {
  Player? _player;
  final _subs = <StreamSubscription<dynamic>>[];
  final _files = <String, String>{};
  Directory? _dir;
  CancelHandle? _cancel;

  bool _busy = false;
  bool _withReverb = true;
  bool _playing = false;
  String? _loaded;
  String? _error;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  late ReverbAmount _amount;
  late bool _sparkle;

  @override
  void initState() {
    super.initState();
    _amount = widget.settings.reverbAmount;
    _sparkle = widget.settings.reverbSparkle;
  }

  /// Everything that changes what the preview sounds like.
  String _key(bool withReverb) {
    final s = widget.settings;
    return jsonEncode([
      withReverb,
      if (withReverb) ...[s.reverbAmount.name, s.reverbSparkle],
      s.join.name,
      s.joinSeconds,
      s.normalize,
      [for (final seg in widget.project.segments) seg.start, for (final seg in widget.project.segments) seg.end],
    ]);
  }

  bool get _stale => _loaded != null && _loaded != _key(_withReverb);

  @override
  void didUpdateWidget(ReverbPreview old) {
    super.didUpdateWidget(old);
    if (!widget.enabled && old.enabled) _player?.pause();
    // Trying Light against Strong should just keep playing.
    final s = widget.settings;
    if (s.reverbAmount != _amount || s.reverbSparkle != _sparkle) {
      _amount = s.reverbAmount;
      _sparkle = s.reverbSparkle;
      if (_playing && _withReverb) WidgetsBinding.instance.addPostFrameCallback((_) => _load(true));
    }
  }

  @override
  void dispose() {
    _cancel?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _player?.dispose();
    final dir = _dir;
    if (dir != null) dir.delete(recursive: true).catchError((_) => dir);
    super.dispose();
  }

  Player _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final player = _player = Player();
    _subs.addAll([
      player.stream.playing.listen((v) => mounted ? setState(() => _playing = v) : null),
      player.stream.position.listen((v) => mounted ? setState(() => _position = v) : null),
      player.stream.duration.listen((v) => mounted ? setState(() => _duration = v) : null),
      player.stream.completed.listen((done) async {
        if (!done) return;
        await player.pause();
        await player.seek(Duration.zero);
      }),
    ]);
    return player;
  }

  /// Plays with or without reverb, carrying on from the current moment.
  Future<void> _load(bool withReverb) async {
    final key = _key(withReverb);
    final cancelPrevious = _cancel;
    final cancel = _cancel = CancelHandle();
    await cancelPrevious?.cancel();
    setState(() {
      _busy = true;
      _error = null;
      _withReverb = withReverb;
    });
    try {
      var path = _files[key];
      if (path == null) {
        final dir = _dir ??= Directory(p.join((await getTemporaryDirectory()).path, 'quran_clipper_preview'));
        path = await renderPreview(
          project: widget.project,
          settings: widget.settings,
          withReverb: withReverb,
          dir: dir,
          seconds: _previewSeconds,
          cancel: cancel,
        );
        _files[key] = path;
      }
      if (!mounted || cancel.cancelled) return;
      // Carry on from where playback has got to by now.
      var at = _loaded == null ? Duration.zero : _position;
      if (!withReverb) {
        // The original has no tail, so don't start past its end.
        final dry = widget.settings.copy()..masjidReverb = false;
        final end = stitchedDuration(previewSegments(widget.project.segments, _previewSeconds), dry) - 1;
        if (at.inMilliseconds / 1000 > end) at = Duration.zero;
      }
      await _ensurePlayer().open(Media(path, start: at));
      if (!mounted) return;
      setState(() {
        _loaded = key;
        _busy = false;
      });
    } on CancelledException {
      // A newer request took over.
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final ready = widget.enabled && widget.project.segments.isNotEmpty;
    if (_loaded == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OutlinedButton.icon(
              onPressed: ready && !_busy ? () => _load(true) : null,
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.headphones),
              label: Text(_busy ? 'Making a preview…' : 'Hear a 20-second preview'),
            ),
            if (_error != null) _errorText(t),
          ],
        ),
      );
    }

    final total = _duration.inMilliseconds;
    final fraction = total == 0 ? 0.0 : (_position.inMilliseconds / total).clamp(0.0, 1.0);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _busy
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
                      )
                    : IconButton.filled(
                        tooltip: _playing ? 'Pause' : 'Play',
                        icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                        onPressed: ready ? () => _player?.playOrPause() : null,
                      ),
                Expanded(
                  child: Slider(
                    value: fraction,
                    onChanged: ready && !_busy && total > 0
                        ? (v) => _player?.seek(Duration(milliseconds: (v * total).round()))
                        : null,
                  ),
                ),
                Text(
                  '${formatTime(_position.inMilliseconds / 1000, decimals: 0)} / '
                  '${formatTime(total / 1000, decimals: 0)}',
                  style: t.textTheme.labelMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('With reverb')),
                ButtonSegment(value: false, label: Text('Original')),
              ],
              selected: {_withReverb},
              onSelectionChanged: ready && !_busy ? (v) => _load(v.first) : null,
            ),
            if (_stale && !_busy) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: ready ? () => _load(_withReverb) : null,
                icon: const Icon(Icons.refresh),
                label: const Text('Settings changed: update the preview'),
              ),
            ],
            if (_error != null) _errorText(t),
          ],
        ),
      ),
    );
  }

  Widget _errorText(ThemeData t) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: SelectableText(_error!, style: TextStyle(color: t.colorScheme.error)),
      );
}
