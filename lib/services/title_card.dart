import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Draws a simple 1920x1080 title card PNG for still-image videos.
Future<File> renderTitleCard({required String title, String? subtitle, required String outputPath}) async {
  const w = 1920.0, h = 1080.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, w, h));

  canvas.drawRect(
    const Rect.fromLTWH(0, 0, w, h),
    Paint()
      ..shader = ui.Gradient.linear(
        const Offset(0, 0),
        const Offset(w, h),
        [const Color(0xFF0B2A24), const Color(0xFF123C33), const Color(0xFF071A16)],
        [0, 0.55, 1],
      ),
  );

  // Thin gold frame.
  final gold = Paint()
    ..color = const Color(0xFFC9A75A)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 3;
  canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(70, 70, w - 140, h - 140), const Radius.circular(24)), gold);
  canvas.drawRRect(
    RRect.fromRectAndRadius(const Rect.fromLTWH(88, 88, w - 176, h - 176), const Radius.circular(18)),
    gold..color = const Color(0x66C9A75A)..strokeWidth = 1.5,
  );

  void text(String s, double y, double size, Color color, {FontWeight weight = FontWeight.w500, int maxLines = 3}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(fontSize: size, color: color, fontWeight: weight, height: 1.25)),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: maxLines,
      ellipsis: '…',
    )..layout(maxWidth: w - 360);
    tp.paint(canvas, Offset((w - tp.width) / 2, y - tp.height / 2));
  }

  text('﷽', 330, 96, const Color(0xFFC9A75A), weight: FontWeight.w400, maxLines: 1);
  text(title, 560, 76, const Color(0xFFF4EFE2), weight: FontWeight.w600);
  if (subtitle != null && subtitle.trim().isNotEmpty) {
    text(subtitle, 780, 40, const Color(0xFFBFD3CC), maxLines: 2);
  }

  final image = await recorder.endRecording().toImage(w.toInt(), h.toInt());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File(outputPath);
  await file.writeAsBytes(bytes!.buffer.asUint8List());
  return file;
}
