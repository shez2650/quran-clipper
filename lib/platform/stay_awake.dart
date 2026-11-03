import 'dart:io';

import 'package:flutter/services.dart';

/// Keeps the app running in the background on Android while [work] runs, by
/// starting a foreground service (shown as a notification). Without it the
/// phone freezes the app soon after you switch away, which stalls downloads,
/// exports and uploads, and breaks Google sign-in. Does nothing elsewhere.
class StayAwake {
  static const _channel = MethodChannel('quran_clipper/keep_alive');
  static int _active = 0;

  static Future<T> during<T>(String text, Future<T> Function() work) async {
    if (!Platform.isAndroid) return work();
    _active++;
    try {
      await _channel.invokeMethod('start', {'text': text});
    } catch (_) {
      // Best effort: the work still runs, it just may pause in the background.
    }
    try {
      return await work();
    } finally {
      if (--_active == 0) {
        try {
          await _channel.invokeMethod('stop');
        } catch (_) {}
      }
    }
  }
}
