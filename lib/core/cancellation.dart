import 'dart:async';

class CancelledException implements Exception {
  @override
  String toString() => 'Cancelled';
}

/// Lets a caller stop a running ffmpeg job.
class CancelHandle {
  bool cancelled = false;
  FutureOr<void> Function()? onCancel;

  Future<void> cancel() async {
    cancelled = true;
    await onCancel?.call();
  }
}

