import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/models.dart';

/// App-wide preferences: export defaults and Google credentials.
class SettingsStore extends ChangeNotifier {
  SettingsStore._(this._prefs);
  static late SettingsStore instance;

  static Future<void> init() async {
    instance = SettingsStore._(await SharedPreferences.getInstance());
  }

  final SharedPreferences _prefs;

  ExportSettings get exportDefaults {
    final raw = _prefs.getString('exportDefaults');
    if (raw == null) return ExportSettings();
    try {
      return ExportSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return ExportSettings();
    }
  }

  set exportDefaults(ExportSettings s) {
    _prefs.setString('exportDefaults', jsonEncode(s.toJson()));
    notifyListeners();
  }

  /// Download video as well as audio when importing a YouTube link.
  bool get downloadVideoByDefault => _prefs.getBool('downloadVideo') ?? false;
  set downloadVideoByDefault(bool v) {
    _prefs.setBool('downloadVideo', v);
    notifyListeners();
  }

  String get googleClientId => _prefs.getString('googleClientId') ?? '';
  String get googleClientSecret => _prefs.getString('googleClientSecret') ?? '';
  void setGoogleClient(String id, String secret) {
    _prefs.setString('googleClientId', id.trim());
    _prefs.setString('googleClientSecret', secret.trim());
    notifyListeners();
  }

  /// Saved OAuth credentials JSON (access + refresh token).
  String? get googleCredentials => _prefs.getString('googleCredentials');
  set googleCredentials(String? v) {
    if (v == null) {
      _prefs.remove('googleCredentials');
    } else {
      _prefs.setString('googleCredentials', v);
    }
    notifyListeners();
  }

  String? get lastPlaylistId => _prefs.getString('lastPlaylistId');
  set lastPlaylistId(String? v) => v == null ? _prefs.remove('lastPlaylistId') : _prefs.setString('lastPlaylistId', v);

  String get youtubePrivacy => _prefs.getString('youtubePrivacy') ?? 'private';
  set youtubePrivacy(String v) => _prefs.setString('youtubePrivacy', v);
}

/// Projects live in `<app documents>/Quran Clipper/projects/<id>/project.json`
/// alongside any downloaded media and exports.
class ProjectStore extends ChangeNotifier {
  ProjectStore._(this.root);
  static late ProjectStore instance;

  static Future<void> init() async {
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory(p.join(docs.path, 'Quran Clipper', 'projects'));
    await root.create(recursive: true);
    instance = ProjectStore._(root);
    await instance.load();
  }

  final Directory root;
  final List<Project> projects = [];

  Directory dirFor(String id) => Directory(p.join(root.path, id));

  Future<void> load() async {
    projects.clear();
    await for (final e in root.list()) {
      if (e is! Directory) continue;
      final f = File(p.join(e.path, 'project.json'));
      if (!await f.exists()) continue;
      try {
        projects.add(Project.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>));
      } catch (err) {
        debugPrint('Skipping broken project ${e.path}: $err');
      }
    }
    projects.sort((a, b) => b.updated.compareTo(a.updated));
    notifyListeners();
  }

  Future<Directory> createDir(String id) => dirFor(id).create(recursive: true);

  Future<void> save(Project project) async {
    project.updated = DateTime.now();
    final dir = await createDir(project.id);
    final f = File(p.join(dir.path, 'project.json'));
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(project.toJson()));
    await tmp.rename(f.path);
    projects.removeWhere((e) => e.id == project.id);
    projects.insert(0, project);
    notifyListeners();
  }

  /// Deletes the project and every file inside its folder. Source files
  /// that live outside the folder (picked local files) are left alone.
  Future<void> delete(Project project) async {
    final dir = dirFor(project.id);
    if (await dir.exists()) await dir.delete(recursive: true);
    projects.removeWhere((e) => e.id == project.id);
    notifyListeners();
  }

  bool ownsFile(Project project, String path) => p.isWithin(dirFor(project.id).path, path);
}

/// Where finished exports go on desktop: ~/Downloads/Quran Clipper.
Future<Directory> desktopExportDir() async {
  final downloads = await getDownloadsDirectory();
  final base = downloads ?? await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(base.path, 'Quran Clipper'));
  await dir.create(recursive: true);
  return dir;
}

/// What deleting a project takes with it. On a computer exports go to the
/// Downloads folder; on a phone they live inside the project until saved.
String deleteWarning(String title, {required bool exportsInProject}) => exportsInProject
    ? '"$title" will be removed, along with its downloaded files and any exports inside the app. '
        'Copies you saved or shared elsewhere are kept.'
    : '"$title" and its downloaded files will be removed. Files you exported are kept.';

bool get isDesktop => Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// Strips characters that are not allowed in file names.
String safeFileName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (cleaned.isEmpty) return 'Recitation';
  return cleaned.length > 80 ? cleaned.substring(0, 80).trim() : cleaned;
}
