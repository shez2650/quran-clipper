import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import '../core/time_format.dart';
import '../services/waveform.dart';

/// Which edge of which part is being dragged.
class _EdgeDrag {
  _EdgeDrag(this.segment, this.isStart);
  final Segment segment;
  final bool isStart;
}

/// Zoomable waveform with the marked parts shaded on top.
///
/// Tap to seek, drag the background to scroll, drag a part's edge to move
/// it, pinch / ctrl+scroll to zoom.
class WaveformView extends StatefulWidget {
  const WaveformView({
    super.key,
    required this.waveform,
    required this.duration,
    required this.position,
    required this.segments,
    required this.pendingStart,
    required this.selectedId,
    required this.onSeek,
    required this.onSegmentEdited,
    required this.onEditEnd,
    required this.follow,
  });

  final Waveform? waveform;
  final double duration;
  final ValueNotifier<double> position;
  final List<Segment> segments;
  final double? pendingStart;
  final String? selectedId;
  final ValueChanged<double> onSeek;
  final VoidCallback onSegmentEdited;
  final VoidCallback onEditEnd;

  /// Keep the playhead in view while playing.
  final bool follow;

  @override
  State<WaveformView> createState() => WaveformViewState();
}

class WaveformViewState extends State<WaveformView> {
  double viewStart = 0;
  double viewSeconds = 60;
  _EdgeDrag? _drag;
  bool _panning = false;
  double _scaleStartSeconds = 60;
  double _scaleFocusTime = 0;

  double get _maxView => max(5, widget.duration);

  @override
  void initState() {
    super.initState();
    viewSeconds = min(60, _maxView);
    widget.position.addListener(_onPosition);
  }

  @override
  void didUpdateWidget(WaveformView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget;
    if (old.position != widget.position) {
      old.position.removeListener(_onPosition);
      widget.position.addListener(_onPosition);
    }
    if (old.duration != widget.duration) viewSeconds = min(viewSeconds, _maxView);
  }

  @override
  void dispose() {
    widget.position.removeListener(_onPosition);
    super.dispose();
  }

  void _onPosition() {
    if (!widget.follow || _panning || _drag != null) return;
    final pos = widget.position.value;
    if (pos < viewStart || pos > viewStart + viewSeconds * 0.92) {
      setState(() => viewStart = _clampStart(pos - viewSeconds * 0.1));
    }
  }

  double _clampStart(double s) => s.clamp(0, max(0, widget.duration - viewSeconds)).toDouble();

  void zoom(double factor, {double? around}) {
    final focus = around ?? widget.position.value;
    final rel = viewSeconds == 0 ? 0.5 : ((focus - viewStart) / viewSeconds).clamp(0.0, 1.0);
    setState(() {
      viewSeconds = (viewSeconds * factor).clamp(5.0, _maxView).toDouble();
      viewStart = _clampStart(focus - rel * viewSeconds);
    });
  }

  void showTime(double t) => setState(() => viewStart = _clampStart(t - viewSeconds * 0.2));

  double _timeAt(double x, double width) => (viewStart + x / width * viewSeconds).clamp(0, widget.duration).toDouble();

  _EdgeDrag? _edgeAt(double x, double width) {
    const grab = 14.0;
    _EdgeDrag? best;
    var bestDist = grab;
    for (final s in widget.segments) {
      for (final isStart in [true, false]) {
        final t = isStart ? s.start : s.end;
        final ex = (t - viewStart) / viewSeconds * width;
        final d = (ex - x).abs();
        if (d < bestDist) {
          bestDist = d;
          best = _EdgeDrag(s, isStart);
        }
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, c) {
      final width = c.maxWidth;
      return Column(
        children: [
          Expanded(
            child: Listener(
              onPointerSignal: (e) {
                if (e is! PointerScrollEvent) return;
                final ctrl = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
                if (ctrl) {
                  zoom(e.scrollDelta.dy > 0 ? 1.25 : 0.8, around: _timeAt(e.localPosition.dx, width));
                } else {
                  final d = e.scrollDelta.dx.abs() > e.scrollDelta.dy.abs() ? e.scrollDelta.dx : e.scrollDelta.dy;
                  setState(() => viewStart = _clampStart(viewStart + d / width * viewSeconds));
                }
              },
              child: MouseRegion(
                cursor: SystemMouseCursors.precise,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) => widget.onSeek(_timeAt(d.localPosition.dx, width)),
                  onScaleStart: (d) {
                    _scaleStartSeconds = viewSeconds;
                    _scaleFocusTime = _timeAt(d.localFocalPoint.dx, width);
                    if (d.pointerCount == 1) {
                      _drag = _edgeAt(d.localFocalPoint.dx, width);
                      _panning = _drag == null;
                    }
                  },
                  onScaleUpdate: (d) {
                    if (d.pointerCount > 1 && d.scale != 1) {
                      _drag = null;
                      final rel = ((_scaleFocusTime - viewStart) / viewSeconds).clamp(0.0, 1.0);
                      setState(() {
                        viewSeconds = (_scaleStartSeconds / d.scale).clamp(5.0, _maxView).toDouble();
                        viewStart = _clampStart(_scaleFocusTime - rel * viewSeconds);
                      });
                      return;
                    }
                    final drag = _drag;
                    if (drag != null) {
                      final t = _timeAt(d.localFocalPoint.dx, width);
                      final s = drag.segment;
                      setState(() {
                        if (drag.isStart) {
                          s.start = min(t, s.end - 0.2);
                        } else {
                          s.end = max(t, s.start + 0.2);
                        }
                      });
                      widget.onSegmentEdited();
                    } else if (_panning) {
                      setState(() => viewStart = _clampStart(viewStart - d.focalPointDelta.dx / width * viewSeconds));
                    }
                  },
                  onScaleEnd: (_) {
                    if (_drag != null) widget.onEditEnd();
                    _drag = null;
                    _panning = false;
                  },
                  child: ValueListenableBuilder<double>(
                    valueListenable: widget.position,
                    builder: (context, pos, _) => CustomPaint(
                      size: Size.infinite,
                      painter: _WavePainter(
                        waveform: widget.waveform,
                        viewStart: viewStart,
                        viewSeconds: viewSeconds,
                        position: pos,
                        segments: widget.segments,
                        pendingStart: widget.pendingStart,
                        selectedId: widget.selectedId,
                        scheme: scheme,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 22,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => showTime(d.localPosition.dx / width * widget.duration),
              onHorizontalDragUpdate: (d) =>
                  setState(() => viewStart = _clampStart(d.localPosition.dx / width * widget.duration - viewSeconds / 2)),
              child: ValueListenableBuilder<double>(
                valueListenable: widget.position,
                builder: (context, pos, _) => CustomPaint(
                  size: Size.infinite,
                  painter: _OverviewPainter(
                    waveform: widget.waveform,
                    duration: widget.duration,
                    viewStart: viewStart,
                    viewSeconds: viewSeconds,
                    position: pos,
                    segments: widget.segments,
                    scheme: scheme,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    });
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.waveform,
    required this.viewStart,
    required this.viewSeconds,
    required this.position,
    required this.segments,
    required this.pendingStart,
    required this.selectedId,
    required this.scheme,
  });

  final Waveform? waveform;
  final double viewStart, viewSeconds, position;
  final List<Segment> segments;
  final double? pendingStart;
  final String? selectedId;
  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final rr = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12));
    canvas.drawRRect(rr, Paint()..color = scheme.surfaceContainerHighest.withValues(alpha: 0.6));
    canvas.save();
    canvas.clipRRect(rr);

    double x(double t) => (t - viewStart) / viewSeconds * w;

    // Marked parts.
    for (var i = 0; i < segments.length; i++) {
      final s = segments[i];
      final l = x(s.start), r = x(s.end);
      if (r < 0 || l > w) continue;
      final selected = s.id == selectedId;
      canvas.drawRect(Rect.fromLTRB(l, 0, r, h),
          Paint()..color = scheme.primary.withValues(alpha: selected ? 0.28 : 0.16));
      final edge = Paint()
        ..color = scheme.primary
        ..strokeWidth = selected ? 3 : 2;
      canvas.drawLine(Offset(l, 0), Offset(l, h), edge);
      canvas.drawLine(Offset(r, 0), Offset(r, h), edge);
      // Grab handles.
      for (final ex in [l, r]) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(ex, h / 2), width: 8, height: 28), const Radius.circular(4)),
          Paint()..color = scheme.primary,
        );
      }
      final tp = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: TextStyle(color: scheme.onPrimary, fontSize: 11, fontWeight: FontWeight.w700),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final badge = Rect.fromLTWH(l + 4, 4, tp.width + 10, tp.height + 4);
      canvas.drawRRect(RRect.fromRectAndRadius(badge, const Radius.circular(6)), Paint()..color = scheme.primary);
      tp.paint(canvas, Offset(badge.left + 5, badge.top + 2));
    }

    // Waveform bars.
    final wf = waveform;
    if (wf != null && wf.peaks.isNotEmpty) {
      final mid = h / 2;
      final barPaint = Paint()
        ..color = scheme.onSurfaceVariant.withValues(alpha: 0.75)
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round;
      const step = 2.5;
      for (var px = 0.0; px < w; px += step) {
        final t0 = viewStart + px / w * viewSeconds;
        final t1 = viewStart + (px + step) / w * viewSeconds;
        final i0 = (t0 * wf.peaksPerSecond).floor();
        final i1 = max(i0 + 1, (t1 * wf.peaksPerSecond).ceil());
        if (i0 >= wf.peaks.length) break;
        var m = 0.0;
        for (var i = max(0, i0); i < min(i1, wf.peaks.length); i++) {
          if (wf.peaks[i] > m) m = wf.peaks[i];
        }
        final amp = max(1.0, sqrt(m) * (mid - 6));
        canvas.drawLine(Offset(px, mid - amp), Offset(px, mid + amp), barPaint);
      }
    }

    // Time ticks.
    final tick = _tickSpacing(viewSeconds);
    final tickPaint = Paint()..color = scheme.outline.withValues(alpha: 0.5);
    for (var t = (viewStart / tick).ceil() * tick; t < viewStart + viewSeconds; t += tick) {
      final tx = x(t);
      canvas.drawLine(Offset(tx, h - 8), Offset(tx, h), tickPaint);
      final tp = TextPainter(
        text: TextSpan(text: formatTime(t, decimals: 0), style: TextStyle(color: scheme.outline, fontSize: 10)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(tx + 3, h - tp.height - 2));
    }

    // Pending start marker.
    if (pendingStart != null) {
      final px = x(pendingStart!);
      final p = Paint()
        ..color = scheme.tertiary
        ..strokeWidth = 2.5;
      canvas.drawLine(Offset(px, 0), Offset(px, h), p);
      canvas.drawRect(Rect.fromLTRB(px, 0, max(px, x(position)), h), Paint()..color = scheme.tertiary.withValues(alpha: 0.12));
    }

    // Playhead.
    final ph = x(position);
    canvas.drawLine(Offset(ph, 0), Offset(ph, h), Paint()
      ..color = scheme.error
      ..strokeWidth = 2);
    canvas.drawCircle(Offset(ph, 0), 5, Paint()..color = scheme.error);
    canvas.restore();
  }

  static double _tickSpacing(double span) {
    const options = [1.0, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800];
    for (final o in options) {
      if (span / o <= 10) return o.toDouble();
    }
    return 3600;
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class _OverviewPainter extends CustomPainter {
  _OverviewPainter({
    required this.waveform,
    required this.duration,
    required this.viewStart,
    required this.viewSeconds,
    required this.position,
    required this.segments,
    required this.scheme,
  });

  final Waveform? waveform;
  final double duration, viewStart, viewSeconds, position;
  final List<Segment> segments;
  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    if (duration <= 0) return;
    final w = size.width, h = size.height;
    double x(double t) => t / duration * w;
    final rr = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6));
    canvas.drawRRect(rr, Paint()..color = scheme.surfaceContainerHighest);
    canvas.save();
    canvas.clipRRect(rr);
    final wf = waveform;
    if (wf != null && wf.peaks.isNotEmpty) {
      final p = Paint()..color = scheme.onSurfaceVariant.withValues(alpha: 0.35);
      final per = wf.peaks.length / w;
      for (var px = 0.0; px < w; px += 2) {
        final i0 = (px * per).floor();
        final i1 = min(wf.peaks.length, ((px + 2) * per).ceil());
        var m = 0.0;
        for (var i = i0; i < i1; i++) {
          if (wf.peaks[i] > m) m = wf.peaks[i];
        }
        final a = sqrt(m) * h / 2;
        canvas.drawRect(Rect.fromLTRB(px, h / 2 - a, px + 1.2, h / 2 + a), p);
      }
    }
    for (final s in segments) {
      canvas.drawRect(Rect.fromLTRB(x(s.start), 0, max(x(s.start) + 1.5, x(s.end)), h),
          Paint()..color = scheme.primary.withValues(alpha: 0.55));
    }
    canvas.drawRect(
      Rect.fromLTWH(x(viewStart), 0.5, max(3, x(viewSeconds)), h - 1),
      Paint()
        ..color = scheme.onSurface.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    canvas.drawRect(Rect.fromLTWH(x(position) - 1, 0, 2, h), Paint()..color = scheme.error);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
