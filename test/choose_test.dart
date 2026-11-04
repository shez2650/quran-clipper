import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:quran_clipper/core/models.dart';
import 'package:quran_clipper/services/storage.dart';
import 'package:quran_clipper/ui/choose_screen.dart';
import 'package:quran_clipper/ui/export_screen.dart';
import 'package:quran_clipper/ui/mark_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePaths extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  _FakePaths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

Project sample({double duration = 600, List<Segment>? segments, bool reverbOnly = false}) => Project(
      id: 'p',
      title: 'Surah Ar-Rahman',
      audioPath: '/nowhere/source.mp3',
      duration: duration,
      segments: segments,
      reverbOnly: reverbOnly,
    );

void main() {
  late Directory dir;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('qc_choose');
    PathProviderPlatform.instance = _FakePaths(dir.path);
    await ProjectStore.init();
  });
  tearDownAll(() => dir.delete(recursive: true));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SettingsStore.init();
  });

  /// Tall enough that the whole screen is built, not just what's scrolled to.
  Future<void> show(WidgetTester t, Widget screen) async {
    t.view.physicalSize = const Size(1000, 3000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: screen));
    await t.pump();
  }

  group('project', () {
    test('using the whole file makes one part covering all of it', () {
      final p = sample()..useWholeFile();
      expect(p.reverbOnly, isTrue);
      expect(p.segments.single.start, 0);
      expect(p.segments.single.end, 600);
    });

    test('switching to clipping starts with no parts', () {
      final p = sample()
        ..useWholeFile()
        ..useForClipping();
      expect(p.reverbOnly, isFalse);
      expect(p.segments, isEmpty);
    });

    test('reverb-only survives saving, and older projects load as clips', () {
      final p = sample()..useWholeFile();
      final back = Project.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(back.reverbOnly, isTrue);
      expect(back.segments, hasLength(1));

      final old = p.toJson()..remove('reverbOnly');
      expect(Project.fromJson(old).reverbOnly, isFalse);
    });

    test('the right screen opens for each kind of project', () {
      expect(screenFor(sample()), isA<ChooseScreen>());
      expect(screenFor(sample(segments: [Segment(id: 'a', start: 1, end: 2)])), isA<MarkScreen>());
      expect(screenFor(sample()..useWholeFile()), isA<ExportScreen>());
    });
  });

  group('settings', () {
    test('a whole file forces the reverb on and needs no join', () {
      final s = ExportSettings(join: JoinMode.crossfade, reverbAmount: ReverbAmount.strong).forWholeFile();
      expect(s.masjidReverb, isTrue);
      expect(s.join, JoinMode.hardCut);
      expect(s.reverbAmount, ReverbAmount.strong);
    });

    test('defaults saved from the reverb screen leave ordinary exports alone', () {
      final saved = ExportSettings(join: JoinMode.gap, joinSeconds: 2);
      final chosen = saved.forWholeFile()
        ..reverbAmount = ReverbAmount.light
        ..reverbSparkle = false
        ..format = AudioFormat.flac;
      final next = chosen.defaultsKeeping(saved);
      expect(next.masjidReverb, isFalse);
      expect(next.join, JoinMode.gap);
      expect(next.joinSeconds, 2);
      expect(next.reverbAmount, ReverbAmount.light);
      expect(next.reverbSparkle, isFalse);
      expect(next.format, AudioFormat.flac);
    });
  });

  group('choice screen', () {
    testWidgets('offers both and shows the length', (t) async {
      await show(t, ChooseScreen(project: sample()));
      expect(find.text('Mark and clip'), findsOneWidget);
      expect(find.text('Just add reverb'), findsOneWidget);
      expect(find.text('10m 0s'), findsOneWidget);
    });

    testWidgets('Just add reverb goes straight to the reverb screen', (t) async {
      final p = sample();
      await show(t, ChooseScreen(project: p));
      await t.runAsync(() async {
        await t.tap(find.text('Just add reverb'));
        await t.pump();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await t.pumpAndSettle();
      expect(find.byType(ExportScreen), findsOneWidget);
      expect(p.reverbOnly, isTrue);
      expect(p.segments, hasLength(1));
      expect(File('${dir.path}/Quran Clipper/projects/p/project.json').existsSync(), isTrue);
    });

    testWidgets("can't go straight to reverb when the length is unknown", (t) async {
      final p = sample(duration: 0);
      await show(t, ChooseScreen(project: p));
      await t.tap(find.text('Just add reverb'), warnIfMissed: false);
      await t.pump();
      expect(find.byType(ChooseScreen), findsOneWidget);
      expect(p.reverbOnly, isFalse);
      expect(find.textContaining("couldn't be read"), findsOneWidget);
    });
  });

  group('reverb screen', () {
    testWidgets('leads with the reverb and hides what a whole file does not need', (t) async {
      await show(t, ExportScreen(project: sample()..useWholeFile()));
      expect(find.text('Masjid reverb'), findsOneWidget); // The title, not a switch.
      expect(find.text('Clip instead'), findsOneWidget);
      expect(find.text('Whole file → 10:09 long'), findsOneWidget);
      expect(find.text('Between parts'), findsNothing);
      expect(find.text('Amount'), findsOneWidget);
      expect(find.text('Sparkle'), findsOneWidget);
      expect(find.text('Hear a 20-second preview'), findsOneWidget);
      expect(find.text('Export MP3'), findsOneWidget);
      expect(find.text('Export and upload to YouTube'), findsOneWidget);
      expect(t.getTopLeft(find.text('Amount')).dy, lessThan(t.getTopLeft(find.text('Audio format')).dy));
    });

    testWidgets('the normal export screen is as it was', (t) async {
      final p = sample(segments: [Segment(id: 'a', start: 1, end: 2)]);
      await show(t, ExportScreen(project: p));
      expect(find.text('Export'), findsOneWidget);
      expect(find.text('Clip instead'), findsNothing);
      expect(find.text('Between parts'), findsOneWidget);
      expect(find.text('Masjid reverb'), findsOneWidget); // The switch.
      expect(find.text('Amount'), findsNothing);
      expect(find.text('1 part → 0:01 long'), findsOneWidget);
    });
  });
}
