import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'services/storage.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // The macOS app isn't sandboxed, so the picker's sandbox checks don't apply.
  if (Platform.isMacOS) await FilePicker.skipEntitlementsChecks();
  await SettingsStore.init();
  await ProjectStore.init();
  runApp(const QuranClipperApp());
}

const seed = Color(0xFF1E6B5C);
const gold = Color(0xFFC9A75A);

ThemeData _theme(Brightness b) {
  final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: b, tertiary: gold);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
    appBarTheme: const AppBarTheme(centerTitle: false),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

class QuranClipperApp extends StatelessWidget {
  const QuranClipperApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Quran Clipper',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        home: const HomeScreen(),
      );
}
