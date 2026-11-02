/// 75.25 -> "1:15.2", 3725 -> "1:02:05.0"
String formatTime(double seconds, {int decimals = 1}) {
  if (seconds.isNaN || seconds.isInfinite) return '--:--';
  final neg = seconds < 0;
  var s = seconds.abs();
  final h = s ~/ 3600;
  s -= h * 3600;
  final m = s ~/ 60;
  s -= m * 60;
  final sec = decimals == 0 ? s.floor().toString().padLeft(2, '0') : s.toStringAsFixed(decimals).padLeft(3 + decimals, '0');
  final body = h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
  return neg ? '-$body' : body;
}

/// 75 -> "1m 15s", 3725 -> "1h 2m"
String formatLength(double seconds) {
  final total = seconds.round();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  if (h > 0) return '${h}h ${m}m';
  if (m > 0) return '${m}m ${s}s';
  return '${s}s';
}

/// Accepts "75", "75.5", "1:15", "1:15.5", "1:02:05". Null if unparseable.
double? parseTime(String text) {
  final parts = text.trim().split(':');
  if (parts.isEmpty || parts.length > 3) return null;
  var total = 0.0;
  for (final p in parts) {
    final v = double.tryParse(p.trim());
    if (v == null || v < 0) return null;
    total = total * 60 + v;
  }
  return total;
}
