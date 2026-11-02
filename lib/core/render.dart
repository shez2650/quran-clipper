import 'dart:math';

import 'models.dart';

/// Builds ffmpeg argument lists. Everything here is pure so it can be unit
/// tested without running ffmpeg.

const double declickSeconds = 0.01;
const double edgeFadeSeconds = 1.5;

String _n(double v) => v.toStringAsFixed(3);

/// Crossfade length actually used: never more than half the shortest part,
/// otherwise ffmpeg's acrossfade fails.
double crossfadeSeconds(List<Segment> segs, ExportSettings s) {
  if (segs.length < 2) return 0;
  final shortest = segs.map((e) => e.length).reduce(min);
  return max(0, min(s.joinSeconds, shortest / 2 - 0.01));
}

/// Length of the finished recitation in seconds.
double stitchedDuration(List<Segment> segs, ExportSettings s) {
  if (segs.isEmpty) return 0;
  final sum = segs.fold(0.0, (a, e) => a + e.length);
  final joins = segs.length - 1;
  switch (s.join) {
    case JoinMode.gap:
      return sum + s.joinSeconds * joins;
    case JoinMode.crossfade:
      return sum - crossfadeSeconds(segs, s) * joins;
    case JoinMode.hardCut:
    case JoinMode.fade:
      return sum;
  }
}

/// Problems that would stop a render, in plain words. Empty when fine.
List<String> validateSegments(List<Segment> segs, double sourceDuration) {
  final problems = <String>[];
  if (segs.isEmpty) problems.add('Mark at least one part first.');
  for (var i = 0; i < segs.length; i++) {
    final s = segs[i];
    final name = 'Part ${i + 1}';
    if (s.start < 0) problems.add('$name starts before the beginning.');
    if (s.end <= s.start) problems.add('$name ends before it starts.');
    if (s.length > 0 && s.length < 0.2) problems.add('$name is shorter than 0.2s.');
    if (sourceDuration > 0 && s.start >= sourceDuration) {
      problems.add('$name starts after the end of the source.');
    }
  }
  return problems;
}

/// Per-part audio chains plus the join, ending in the label [aout].
String audioGraph(List<Segment> segs, ExportSettings s, {int input = 0}) {
  final parts = <String>[];
  final n = segs.length;
  final xf = s.join == JoinMode.crossfade ? crossfadeSeconds(segs, s) : 0.0;

  for (var i = 0; i < n; i++) {
    final seg = segs[i];
    final len = seg.length;
    final f = StringBuffer('[$input:a]atrim=start=${_n(seg.start)}:end=${_n(seg.end)},'
        'asetpts=PTS-STARTPTS,aresample=48000,'
        'aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo');
    switch (s.join) {
      case JoinMode.hardCut:
      case JoinMode.gap:
        if (len > declickSeconds * 4) {
          f.write(',afade=t=in:d=${_n(declickSeconds)}'
              ',afade=t=out:st=${_n(len - declickSeconds)}:d=${_n(declickSeconds)}');
        }
        if (s.join == JoinMode.gap && i < n - 1 && s.joinSeconds > 0) {
          f.write(',apad=pad_dur=${_n(s.joinSeconds)}');
        }
      case JoinMode.fade:
        final d = min(s.joinSeconds, len / 2);
        if (d > 0 && i > 0) f.write(',afade=t=in:d=${_n(d)}');
        if (d > 0 && i < n - 1) f.write(',afade=t=out:st=${_n(len - d)}:d=${_n(d)}');
      case JoinMode.crossfade:
        break;
    }
    f.write('[a$i]');
    parts.add(f.toString());
  }

  String joined;
  if (n == 1) {
    joined = 'a0';
  } else if (s.join == JoinMode.crossfade && xf > 0) {
    var prev = 'a0';
    for (var i = 1; i < n; i++) {
      final out = 'x$i';
      parts.add('[$prev][a$i]acrossfade=d=${_n(xf)}:c1=tri:c2=tri[$out]');
      prev = out;
    }
    joined = prev;
  } else {
    parts.add('${List.generate(n, (i) => '[a$i]').join()}concat=n=$n:v=0:a=1[acat]');
    joined = 'acat';
  }

  final post = <String>[];
  if (s.normalize) post.add('loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000');
  final total = stitchedDuration(segs, s);
  if (s.fadeEdges && total > 1) {
    final d = min(edgeFadeSeconds, total / 4);
    post.add('afade=t=in:d=${_n(d)},afade=t=out:st=${_n(total - d)}:d=${_n(d)}');
  }
  parts.add('[$joined]${post.isEmpty ? 'anull' : post.join(',')}[aout]');
  return parts.join(';');
}

/// Per-part video chains matching [audioGraph] timing, ending in [vout].
String videoGraph(List<Segment> segs, ExportSettings s, {int input = 0}) {
  final parts = <String>[];
  final n = segs.length;
  final h = s.videoHeight;
  final xf = s.join == JoinMode.crossfade ? crossfadeSeconds(segs, s) : 0.0;

  for (var i = 0; i < n; i++) {
    final seg = segs[i];
    final len = seg.length;
    final f = StringBuffer('[$input:v]trim=start=${_n(seg.start)}:end=${_n(seg.end)},'
        // Never upscale: a 360p source stays 360p.
        "setpts=PTS-STARTPTS,scale=-2:'trunc(min($h,ih)/2)*2',fps=30,format=yuv420p,setsar=1");
    switch (s.join) {
      case JoinMode.gap:
        if (i < n - 1 && s.joinSeconds > 0) {
          f.write(',tpad=stop_mode=add:stop_duration=${_n(s.joinSeconds)}:color=black');
        }
      case JoinMode.fade:
        final d = min(s.joinSeconds, len / 2);
        if (d > 0 && i > 0) f.write(',fade=t=in:st=0:d=${_n(d)}');
        if (d > 0 && i < n - 1) f.write(',fade=t=out:st=${_n(len - d)}:d=${_n(d)}');
      case JoinMode.hardCut:
      case JoinMode.crossfade:
        break;
    }
    f.write('[v$i]');
    parts.add(f.toString());
  }

  String joined;
  if (n == 1) {
    joined = 'v0';
  } else if (s.join == JoinMode.crossfade && xf > 0) {
    var prev = 'v0';
    var offset = 0.0;
    for (var i = 1; i < n; i++) {
      offset += segs[i - 1].length - xf;
      final out = 'y$i';
      parts.add('[$prev][v$i]xfade=transition=fade:duration=${_n(xf)}:offset=${_n(offset)}[$out]');
      prev = out;
    }
    joined = prev;
  } else {
    parts.add('${List.generate(n, (i) => '[v$i]').join()}concat=n=$n:v=1:a=0[vcat]');
    joined = 'vcat';
  }

  final total = stitchedDuration(segs, s);
  if (s.fadeEdges && total > 1) {
    final d = min(edgeFadeSeconds, total / 4);
    parts.add('[$joined]fade=t=in:st=0:d=${_n(d)},fade=t=out:st=${_n(total - d)}:d=${_n(d)}[vout]');
  } else {
    parts.add('[$joined]null[vout]');
  }
  return parts.join(';');
}

List<String> audioEncoderArgs(AudioFormat f, int kbps) {
  switch (f) {
    case AudioFormat.mp3:
      return ['-c:a', 'libmp3lame', '-b:a', '${kbps}k'];
    case AudioFormat.m4a:
      return ['-c:a', 'aac', '-b:a', '${kbps}k', '-movflags', '+faststart'];
    case AudioFormat.opus:
      return ['-c:a', 'libopus', '-b:a', '${min(kbps, 256)}k'];
    case AudioFormat.wav:
      return ['-c:a', 'pcm_s16le'];
    case AudioFormat.flac:
      return ['-c:a', 'flac'];
  }
}

/// Cut + join the audio into [output].
List<String> buildAudioArgs({
  required String input,
  required List<Segment> segments,
  required ExportSettings settings,
  required String output,
}) =>
    [
      '-y', '-hide_banner',
      '-i', input,
      '-filter_complex', audioGraph(segments, settings),
      '-map', '[aout]',
      '-vn', '-map_metadata', '-1',
      ...audioEncoderArgs(settings.format, settings.bitrateKbps),
      output,
    ];

/// Cut + join picture and sound into an MP4 in one pass.
List<String> buildOriginalVideoArgs({
  required String audioInput,
  required String videoInput,
  required List<Segment> segments,
  required ExportSettings settings,
  required String output,
}) {
  final sameFile = audioInput == videoInput;
  final v = sameFile ? 0 : 1;
  return [
    '-y', '-hide_banner',
    '-i', audioInput,
    if (!sameFile) ...['-i', videoInput],
    '-filter_complex',
    '${audioGraph(segments, settings)};${videoGraph(segments, settings, input: v)}',
    '-map', '[vout]', '-map', '[aout]',
    '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23', '-pix_fmt', 'yuv420p',
    '-c:a', 'aac', '-b:a', '${max(settings.bitrateKbps, 128)}k',
    '-map_metadata', '-1',
    '-movflags', '+faststart',
    output,
  ];
}

/// Put an already-rendered [audio] file under a still [image].
List<String> buildStillImageArgs({
  required String image,
  required String audio,
  required double durationSeconds,
  required ExportSettings settings,
  required String output,
}) {
  final h = settings.videoHeight;
  final w = (h * 16 / 9).round() ~/ 2 * 2;
  final copyAudio = settings.format == AudioFormat.m4a;
  return [
    '-y', '-hide_banner',
    '-loop', '1', '-framerate', '2', '-i', image,
    '-i', audio,
    '-filter_complex',
    '[0:v]scale=$w:$h:force_original_aspect_ratio=decrease,'
        'pad=$w:$h:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,format=yuv420p[v]',
    '-map', '[v]', '-map', '1:a',
    '-c:v', 'libx264', '-preset', 'veryfast', '-tune', 'stillimage', '-r', '2',
    if (copyAudio) ...['-c:a', 'copy'] else ...['-c:a', 'aac', '-b:a', '${max(settings.bitrateKbps, 128)}k'],
    '-t', _n(durationSeconds),
    '-movflags', '+faststart',
    output,
  ];
}

/// Decode to mono 16-bit PCM at a low rate, for drawing the waveform.
List<String> buildWaveformArgs({required String input, required String output, int sampleRate = 4000}) => [
      '-y', '-hide_banner', '-v', 'error',
      '-i', input,
      '-vn', '-ac', '1', '-ar', '$sampleRate',
      '-f', 's16le', '-acodec', 'pcm_s16le',
      output,
    ];
