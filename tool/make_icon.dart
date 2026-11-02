// Renders the app icons (square, macOS and Android adaptive foreground) into tool/.
// Run with: flutter test tool/make_icon.dart
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('render icons', () async {
    await render('tool/icon_square.png', radius: 0, inset: 0);
    await render('tool/icon_macos.png', radius: 0.225, inset: 100);
    // Android adaptive icon foreground: transparent, kept inside the safe zone.
    await render(
      'tool/icon_foreground.png',
      radius: 0,
      inset: 70,
      background: false,
    );
  });
}

Future<void> render(
  String path, {
  required double radius,
  required double inset,
  bool background = true,
}) async {
  const full = 1024.0;
  final size = full - inset * 2;
  final recorder = ui.PictureRecorder();
  final c = Canvas(recorder);
  c.translate(inset, inset);
  c.scale(size / full);
  const center = Offset(full / 2, full / 2);

  // Background: deep green. Square for Android (the launcher masks it),
  // rounded with a margin for macOS.
  final bg = RRect.fromRectAndRadius(
    const Rect.fromLTWH(0, 0, full, full),
    Radius.circular(full * radius),
  );
  if (background) {
    c.drawRRect(
      bg,
      Paint()
        ..shader = ui.Gradient.linear(
          const Offset(0, 0),
          const Offset(full, full),
          [const Color(0xFF1E6B5C), const Color(0xFF0B2A24)],
        ),
    );
  }

  // Eight-pointed star outline (two overlapping squares).
  final gold = Paint()
    ..color = const Color(0xFFC9A75A)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 22
    ..strokeJoin = StrokeJoin.round;
  for (final angle in [0.0, pi / 4]) {
    final path = Path();
    for (var i = 0; i < 4; i++) {
      final a = angle + i * pi / 2 + pi / 4;
      final p = center + Offset(cos(a), sin(a)) * 330;
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    path.close();
    c.drawPath(path, gold);
  }

  // Waveform bars, with one gap: the talking that gets cut out.
  final heights = [
    0.25,
    0.5,
    0.8,
    0.55,
    0.95,
    0.65,
    0.35,
    0.0,
    0.4,
    0.75,
    1.0,
    0.6,
    0.3,
  ];
  const barW = 26.0, gap = 14.0;
  final totalW = heights.length * barW + (heights.length - 1) * gap;
  var x = center.dx - totalW / 2;
  final bar = Paint()..color = const Color(0xFFF4EFE2);
  for (final h in heights) {
    if (h > 0) {
      final bh = 40 + h * 300;
      c.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, center.dy - bh / 2, barW, bh),
          const Radius.circular(barW / 2),
        ),
        bar,
      );
    } else {
      // Dashed cut line.
      final cut = Paint()
        ..color = const Color(0xFFC9A75A)
        ..strokeWidth = 8
        ..strokeCap = StrokeCap.round;
      for (var y = center.dy - 170; y < center.dy + 170; y += 36) {
        c.drawLine(Offset(x + barW / 2, y), Offset(x + barW / 2, y + 16), cut);
      }
    }
    x += barW + gap;
  }

  final image = await recorder.endRecording().toImage(
    full.toInt(),
    full.toInt(),
  );
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  File(path).writeAsBytesSync(bytes!.buffer.asUint8List());
}
