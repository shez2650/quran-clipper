import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/models.dart';
import '../core/render.dart';
import '../platform/ffmpeg_runner.dart';
import 'downloader.dart';
import 'storage.dart';
import 'title_card.dart';

class ExportResult {
  ExportResult({required this.audioPath, this.videoPath, required this.duration});
  final String audioPath;
  final String? videoPath;
  final double duration;
}

/// Turns a project's marked parts into finished files.
class Exporter {
  Exporter({required this.onStatus, required this.onProgress, CancelHandle? cancel})
      : cancel = cancel ?? CancelHandle();

  final void Function(String status) onStatus;

  /// Overall progress 0..1.
  final void Function(double fraction) onProgress;
  final CancelHandle cancel;

  Future<Directory> _outputDir(Project project) async {
    if (isDesktop) return desktopExportDir();
    final dir = Directory(p.join(ProjectStore.instance.dirFor(project.id).path, 'exports'));
    await dir.create(recursive: true);
    return dir;
  }

  /// "Title.mp3", or "Title (2).mp3" if that exists.
  String _freeName(Directory dir, String base, String ext) {
    var path = p.join(dir.path, '$base.$ext');
    var i = 2;
    while (File(path).existsSync()) {
      path = p.join(dir.path, '$base ($i).$ext');
      i++;
    }
    return path;
  }

  Future<ExportResult> run(Project project, ExportSettings s) async {
    final segs = project.segments;
    final problems = validateSegments(segs, project.duration);
    if (problems.isNotEmpty) throw FfmpegException(problems.join('\n'));

    final total = stitchedDuration(segs, s);
    final outDir = await _outputDir(project);
    final base = safeFileName(project.title);
    final workDir = ProjectStore.instance.dirFor(project.id);
    await workDir.create(recursive: true);

    // Weights of each step in the overall bar.
    final steps = <double>[if (s.video == VideoMode.original && project.videoPath == null) 0.2, 1, if (s.video != VideoMode.none) 1.5];
    final sum = steps.reduce((a, b) => a + b);
    var done = 0.0;
    void step(double weight, double fraction) => onProgress(((done + weight * fraction.clamp(0, 1)) / sum).clamp(0, 1));
    void finish(double weight) => done += weight;

    // 1. Fetch the picture if footage is wanted but only audio was downloaded.
    if (s.video == VideoMode.original && project.videoPath == null) {
      final id = project.sourceUrl == null ? null : YouTubeDownloader.parseId(project.sourceUrl!);
      if (id == null) throw FfmpegException('This project has no video to use. Choose "Still image" instead.');
      onStatus('Downloading video…');
      project.videoPath = await YouTubeDownloader().downloadVideo(id, workDir,
          maxHeight: s.videoHeight, onProgress: (f) => step(steps[0], f), cancel: cancel);
      await ProjectStore.instance.save(project);
      finish(steps[0]);
    }

    // 2. Audio file in the chosen format.
    onStatus('Cutting and joining audio…');
    final audioOut = _freeName(outDir, base, s.format.extension);
    final audioWeight = steps[steps.length - (s.video == VideoMode.none ? 1 : 2)];
    await FfmpegRunner.instance.run(
      buildAudioArgs(input: project.audioPath, segments: segs, settings: s, output: audioOut),
      onProgress: (sec) => step(audioWeight, total > 0 ? sec / total : 0),
      cancel: cancel,
    );
    finish(audioWeight);

    // 3. Optional video.
    String? videoOut;
    if (s.video != VideoMode.none) {
      final weight = steps.last;
      videoOut = _freeName(outDir, base, 'mp4');
      if (s.video == VideoMode.stillImage) {
        onStatus('Making video…');
        var image = s.imagePath;
        if (image == null || !File(image).existsSync()) {
          image = (await renderTitleCard(
            title: project.title,
            subtitle: '${segs.length} part${segs.length == 1 ? '' : 's'} · ${_mins(total)}',
            outputPath: p.join(workDir.path, 'title_card.png'),
          ))
              .path;
        }
        await FfmpegRunner.instance.run(
          buildStillImageArgs(image: image, audio: audioOut, durationSeconds: total, settings: s, output: videoOut),
          onProgress: (sec) => step(weight, total > 0 ? sec / total : 0),
          cancel: cancel,
        );
      } else {
        onStatus('Cutting and joining video…');
        await FfmpegRunner.instance.run(
          buildOriginalVideoArgs(
            audioInput: project.audioPath,
            videoInput: project.videoPath!,
            segments: segs,
            settings: s,
            output: videoOut,
          ),
          onProgress: (sec) => step(weight, total > 0 ? sec / total : 0),
          cancel: cancel,
        );
      }
      finish(weight);
    }

    onProgress(1);
    onStatus('Done');
    return ExportResult(audioPath: audioOut, videoPath: videoOut, duration: total);
  }

  static String _mins(double sec) {
    final m = (sec / 60).round();
    return m < 1 ? '${sec.round()}s' : '$m min';
  }
}
