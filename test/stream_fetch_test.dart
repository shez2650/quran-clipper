import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_clipper/platform/ffmpeg_runner.dart';
import 'package:quran_clipper/services/stream_fetch.dart';

/// A local stand-in for YouTube's video servers. [behave] decides each reply.
class _Server {
  _Server(this.body);
  final Uint8List body;
  late HttpServer server;
  final ranges = <String?>[];
  late Future<void> Function(HttpRequest req, int index) behave;

  Uri get url => Uri.parse('http://127.0.0.1:${server.port}/videoplayback');

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      ranges.add(req.headers.value('range'));
      await behave(req, ranges.length - 1);
    });
  }

  /// Replies to the requested range properly.
  Future<void> serveRange(HttpRequest req, {int? stopAfter}) async {
    final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(req.headers.value('range') ?? '')!;
    final from = int.parse(m.group(1)!);
    final to = m.group(2)!.isEmpty ? body.length - 1 : int.parse(m.group(2)!);
    final slice = body.sublist(from, to + 1);
    req.response
      ..statusCode = 206
      ..contentLength = slice.length;
    if (stopAfter != null) {
      req.response.bufferOutput = false;
      req.response.add(slice.sublist(0, stopAfter));
      await req.response.flush();
      return; // Then goes quiet, holding the connection open.
    }
    req.response.add(slice);
    await req.response.close();
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  late Directory dir;
  final body = Uint8List.fromList(List.generate(25000, (i) => i * 7 % 256));

  setUp(() => dir = Directory.systemTemp.createTempSync('qc_fetch'));
  tearDown(() => dir.delete(recursive: true));

  Future<_Server> serve(Future<void> Function(_Server s, HttpRequest req, int i) behave) async {
    final s = _Server(body);
    s.behave = (req, i) => behave(s, req, i);
    await s.start();
    addTearDown(s.close);
    return s;
  }

  Future<File> fetch(_Server s, {CancelHandle? cancel, List<int>? progress, int retries = 2}) async {
    final out = File('${dir.path}/out.part');
    await fetchInChunks(
      url: s.url,
      total: body.length,
      into: out,
      chunkSize: 10000,
      stallAfter: const Duration(milliseconds: 400),
      retries: retries,
      cancel: cancel,
      onBytes: progress?.add,
    );
    return out;
  }

  test('downloads in ranged pieces', () async {
    final s = await serve((s, req, i) => s.serveRange(req));
    final progress = <int>[];
    final out = await fetch(s, progress: progress);
    expect(out.readAsBytesSync(), body);
    expect(s.ranges, ['bytes=0-9999', 'bytes=10000-19999', 'bytes=20000-24999']);
    expect(progress.last, body.length);
  });

  test('a refusal is reported at once, not retried forever', () async {
    final s = await serve((s, req, i) async {
      req.response.statusCode = 403;
      await req.response.close();
    });
    await expectLater(fetch(s), throwsA(isA<StreamRefused>().having((e) => e.status, 'status', 403)));
    expect(s.ranges, hasLength(1));
  });

  test('rate limiting is reported as such', () async {
    final s = await serve((s, req, i) async {
      req.response.statusCode = 429;
      await req.response.close();
    });
    await expectLater(fetch(s), throwsA(isA<StreamRateLimited>()));
  });

  test('a server that never answers is given up on', () async {
    final s = await serve((s, req, i) async {}); // Never replies.
    final clock = Stopwatch()..start();
    await expectLater(fetch(s, retries: 1), throwsA(isA<StreamStalled>()));
    expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
    expect(s.ranges, hasLength(2));
  });

  test('a reply that stops halfway carries on from where it got to', () async {
    final s = await serve((s, req, i) => s.serveRange(req, stopAfter: i == 0 ? 4000 : null));
    final progress = <int>[];
    final out = await fetch(s, progress: progress);
    expect(out.readAsBytesSync(), body);
    expect(s.ranges.take(2), ['bytes=0-9999', 'bytes=4000-13999']);
    expect(progress.first, 4000);
  });

  test('a server that ignores the range still gives the right file', () async {
    final s = await serve((s, req, i) async {
      req.response
        ..statusCode = 200
        ..contentLength = body.length
        ..add(body);
      await req.response.close();
    });
    final out = await fetch(s);
    expect(out.readAsBytesSync(), body);
    expect(s.ranges, hasLength(1));
  });

  test('a passing server error is retried', () async {
    final s = await serve((s, req, i) async {
      if (i == 0) {
        req.response.statusCode = 503;
        await req.response.close();
      } else {
        await s.serveRange(req);
      }
    });
    final out = await fetch(s);
    expect(out.readAsBytesSync(), body);
  });

  test('cancel works while waiting on a silent server', () async {
    final s = await serve((s, req, i) async {});
    final cancel = CancelHandle();
    Timer(const Duration(milliseconds: 150), cancel.cancel);
    final out = File('${dir.path}/out.part');
    final clock = Stopwatch()..start();
    await expectLater(
      fetchInChunks(url: s.url, total: body.length, into: out, stallAfter: const Duration(seconds: 30), cancel: cancel),
      throwsA(isA<CancelledException>()),
    );
    expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
  });
}
