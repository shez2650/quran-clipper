import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../platform/ffmpeg_runner.dart' show CancelHandle, CancelledException;

/// YouTube said no to this stream (403 and the like). Another way of asking
/// may still work.
class StreamRefused implements Exception {
  StreamRefused(this.status);
  final int status;
  @override
  String toString() => 'YouTube refused the download (HTTP $status).';
}

/// YouTube is limiting requests from this connection.
class StreamRateLimited implements Exception {
  @override
  String toString() => 'YouTube is limiting downloads from this connection.';
}

/// Nothing arrived for too long, even after retrying.
class StreamStalled implements Exception {
  StreamStalled(this.got, this.total);
  final int got;
  final int total;
  @override
  String toString() => 'The download stopped arriving ($got of $total bytes).';
}

/// Downloads [url] into [into] in ranged pieces, checking every answer.
///
/// Unlike youtube_explode's own download, a refusal is reported straight away
/// instead of being retried forever, and a connection that goes quiet for
/// [stallAfter] is retried and then given up on. [cancel] is honoured at any
/// point, including while waiting for a reply.
Future<void> fetchInChunks({
  required Uri url,
  required int total,
  required File into,
  Map<String, String> headers = const {},
  http.Client? client,
  void Function(int got)? onBytes,
  CancelHandle? cancel,
  Duration stallAfter = const Duration(seconds: 20),
  int chunkSize = 10 * 1024 * 1024,
  int retries = 3,
}) async {
  final http_ = client ?? http.Client();
  final sink = into.openWrite();
  var got = 0;
  try {
    var failures = 0;
    while (total <= 0 || got < total) {
      final to = total > 0 ? (got + chunkSize > total ? total : got + chunkSize) - 1 : null;
      final before = got;
      try {
        final finished = await _fetchRange(
          http_,
          url,
          headers,
          from: got,
          to: to,
          stallAfter: stallAfter,
          cancel: cancel,
          onData: (data) {
            sink.add(data);
            got += data.length;
            onBytes?.call(got);
          },
        );
        failures = 0;
        if (finished || (total > 0 && got >= total)) break;
        if (got == before) throw StreamStalled(got, total);
      } on _Quiet {
        failures++;
        if (failures > retries) throw StreamStalled(got, total);
        await Future<void>.delayed(const Duration(milliseconds: 500));
      } on _ServerError {
        failures++;
        if (failures > retries) throw StreamStalled(got, total);
        await Future<void>.delayed(Duration(seconds: failures));
      } on SocketException {
        failures++;
        if (failures > retries) rethrow;
        await Future<void>.delayed(Duration(seconds: failures));
      } on http.ClientException {
        failures++;
        if (failures > retries) rethrow;
        await Future<void>.delayed(Duration(seconds: failures));
      }
    }
  } finally {
    await sink.close();
    if (client == null) http_.close();
  }
}

class _Quiet implements Exception {}

class _ServerError implements Exception {}

/// Fetches bytes [from]..[to] (to the end when [to] is null). Returns true when
/// the server sent everything there is, not just this range.
Future<bool> _fetchRange(
  http.Client client,
  Uri url,
  Map<String, String> headers, {
  required int from,
  required int? to,
  required Duration stallAfter,
  required void Function(List<int> data) onData,
  CancelHandle? cancel,
}) async {
  final done = Completer<bool>();
  var lastData = DateTime.now();
  StreamSubscription<List<int>>? sub;

  void fail(Object e) {
    if (!done.isCompleted) done.completeError(e);
  }

  // One watchdog covers waiting for the reply and waiting for data.
  final watchdog = Timer.periodic(const Duration(milliseconds: 200), (_) {
    if (cancel?.cancelled ?? false) {
      fail(CancelledException());
    } else if (DateTime.now().difference(lastData) > stallAfter) {
      fail(_Quiet());
    }
  });

  final req = http.Request('GET', url)
    ..headers.addAll(headers)
    ..headers['range'] = 'bytes=$from-${to ?? ''}';
  client.send(req).then((r) {
    if (done.isCompleted) {
      // Gave up waiting before the reply came: let the connection go.
      r.stream.listen(null).cancel();
      return;
    }
    if (r.statusCode == 429) return fail(StreamRateLimited());
    if (r.statusCode >= 500) return fail(_ServerError());
    if (r.statusCode >= 400) return fail(StreamRefused(r.statusCode));
    // 200 means the whole file came back, not just the range asked for.
    final whole = r.statusCode == 200;
    var skip = whole ? from : 0;
    lastData = DateTime.now();
    sub = r.stream.listen(
      (data) {
        lastData = DateTime.now();
        if (skip > 0) {
          if (data.length <= skip) {
            skip -= data.length;
            return;
          }
          data = data.sublist(skip);
          skip = 0;
        }
        onData(data);
      },
      onError: fail,
      onDone: () {
        if (!done.isCompleted) done.complete(whole || to == null);
      },
      cancelOnError: true,
    );
  }, onError: fail);

  try {
    return await done.future;
  } finally {
    watchdog.cancel();
    await sub?.cancel();
  }
}
