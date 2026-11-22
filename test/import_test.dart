import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:quran_clipper/core/models.dart';
import 'package:quran_clipper/platform/ffmpeg_runner.dart';
import 'package:quran_clipper/services/downloader.dart';
import 'package:quran_clipper/services/storage.dart';
import 'package:quran_clipper/ui/choose_screen.dart';
import 'package:quran_clipper/ui/import_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Paths extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

class Probe extends Fake implements FfmpegRunner {
  @override
  Future<MediaInfo> probe(String path) async =>
      const MediaInfo(duration: 120, hasAudio: true, hasVideo: false);
}

class Downloads extends YouTubeDownloader {
  bool fail = false;
  @override
  Future<VideoMeta> fetchMeta(String id, {CancelHandle? cancel}) async =>
      VideoMeta(id: id, title: 'Recitation', author: '');
  @override
  Future<String> downloadAudio(String id, Directory dir,
      {void Function(double)? onProgress, CancelHandle? cancel}) async {
    if (fail) throw DownloadException('Private video');
    final file = File(p.join(dir.path, 'audio.m4a'));
    await file.writeAsString('test audio');
    onProgress?.call(1);
    return file.path;
  }
}

void main() {
  late Directory dir;
  late FfmpegRunner previousRunner;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('qc import ');
    PathProviderPlatform.instance = Paths(dir.path);
    SharedPreferences.setMockInitialValues({});
    await SettingsStore.init();
    await ProjectStore.init();
    previousRunner = FfmpegRunner.instance;
    FfmpegRunner.instance = Probe();
  });
  tearDown(() async {
    FfmpegRunner.instance = previousRunner;
    await dir.delete(recursive: true);
  });

  testWidgets('pasted URL imports to ordinary saved project and choice screen', (t) async {
    await t.pumpWidget(MaterialApp(home: ImportScreen(
        link: 'https://youtu.be/BaW_jenozKc', editLink: true, downloader: Downloads())));
    expect(find.text('Import'), findsOneWidget);
    await t.tap(find.text('Import'));
    for (var i = 0; i < 30 && ProjectStore.instance.projects.isEmpty; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
    }
    await t.pumpAndSettle();
    expect(find.byType(ChooseScreen), findsOneWidget);
    final project = ProjectStore.instance.projects.single;
    expect(project.title, 'Recitation');
    expect(project.duration, 120);
    expect(project.videoPath, isNull);
    expect(project.sourceUrl, 'https://www.youtube.com/watch?v=BaW_jenozKc');
    await ProjectStore.instance.load();
    final reopened = ProjectStore.instance.projects.single;
    expect(reopened.audioPath, project.audioPath);
    expect(reopened.sourceUrl, project.sourceUrl);
    reopened.segments.add(Segment(id: 's', start: 10, end: 20));
    expect(reopened.stitchedLength, 10);
    reopened.useWholeFile();
    expect(reopened.reverbOnly, isTrue);
    expect(reopened.stitchedLength, 120);
  });

  testWidgets('failed import leaves no saved project or partial folder', (t) async {
    final dl = Downloads()..fail = true;
    await t.pumpWidget(MaterialApp(home: ImportScreen(
        link: 'https://youtu.be/BaW_jenozKc', editLink: true, downloader: dl)));
    await t.tap(find.text('Import'));
    for (var i = 0; i < 30; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
    }
    expect(find.text('Private video'), findsOneWidget);
    expect(ProjectStore.instance.projects, isEmpty);
    expect(await ProjectStore.instance.root.list().toList(), isEmpty);
  });
}
