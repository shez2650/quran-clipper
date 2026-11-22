@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_clipper/services/downloader.dart';

/// Tries the real YouTube. Off unless LIVE_YOUTUBE=1, because it needs the
/// internet and YouTube may limit a connection that runs it often. Either the
/// audio downloads, or it fails quickly with a plain explanation: never a hang.
void main() {
  final live = Platform.environment['LIVE_YOUTUBE'] == '1';
  final ids = (Platform.environment['LIVE_YOUTUBE_IDS'] ?? 'dzLTlrwvuKs').split(',');

  for (final id in ids) {
    test('downloads the audio of $id', () async {
      final dir = Directory.systemTemp.createTempSync('qc_live');
      addTearDown(() => dir.delete(recursive: true));
      final dl = YouTubeDownloader();
      final meta = await dl.fetchMeta(id);
      final clock = Stopwatch()..start();
      var last = 0.0;
      try {
        final path = await dl.downloadAudio(id, dir, onProgress: (f) => last = f);
        // ignore: avoid_print
        print('LIVE $id "${meta.title}" ${File(path).lengthSync()} bytes in ${clock.elapsedMilliseconds}ms');
        expect(last, closeTo(1, 0.001));
      } on DownloadException catch (e) {
        // ignore: avoid_print
        print('LIVE $id refused after ${clock.elapsedMilliseconds}ms: ${dl.attempts.join(' | ')}\n  says: $e');
        expect(clock.elapsed, lessThan(const Duration(seconds: 60)));
      }
    }, skip: live ? null : 'set LIVE_YOUTUBE=1 to run', timeout: const Timeout(Duration(minutes: 3)));
  }
}
