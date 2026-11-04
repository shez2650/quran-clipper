import 'dart:math';

import 'models.dart';

/// Builds ffmpeg argument lists. Everything here is pure so it can be unit
/// tested without running ffmpeg.

const double declickSeconds = 0.01;
const double edgeFadeSeconds = 1.5;

/// Seconds of reverb ringing added after the last part.
const double reverbTailSeconds = 9;

/// Reverb gains, tuned by ear. They include the gain the impulse response
/// files were scaled by (+30.39 dB and +29.42 dB), so the real wet level is
/// [reverbWetTargetDb].
const double reverbWetDb = -49.39;
const double reverbShimmerDb = -57.42;
const double reverbWetTargetDb = -19;
const double reverbLimit = 0.84;

/// The two reverb steps that depend on which ffmpeg is running. Found by
/// testing it (see services/reverb.dart), because this differs per build.
class ReverbEngine {
  const ReverbEngine({required this.noAutoGain, required this.pitchUp});

  /// afir option that stops it normalising the impulse response.
  final String noAutoGain;

  /// Filter chain raising 48 kHz audio by an octave at the same speed.
  final String pitchUp;

  static const pitchRubberband = 'rubberband=pitch=2';
  static const pitchResample = 'asetrate=96000,aresample=48000,atempo=0.5';
}

/// Everything an export needs to apply the reverb.
class ReverbRig {
  const ReverbRig({required this.mainIr, required this.shimmerIr, required this.engine});
  final String mainIr;
  final String shimmerIr;
  final ReverbEngine engine;

  List<String> inputArgs(ExportSettings s) => ['-i', mainIr, if (s.reverbSparkle) ...['-i', shimmerIr]];
}

String _n(double v) => v.toStringAsFixed(3);
String _db(double v) => '${v.toStringAsFixed(2)}dB';

const _irFormat = 'aformat=sample_fmts=fltp:channel_layouts=stereo';

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
  final tail = s.masjidReverb ? reverbTailSeconds : 0.0;
  switch (s.join) {
    case JoinMode.gap:
      return sum + s.joinSeconds * joins + tail;
    case JoinMode.crossfade:
      return sum - crossfadeSeconds(segs, s) * joins + tail;
    case JoinMode.hardCut:
    case JoinMode.fade:
      return sum + tail;
  }
}

/// A short stretch to audition settings on, ending where a part really ends
/// so the reverb tail can be heard. Whole parts while they fit, then the last
/// seconds of the part that doesn't.
List<Segment> previewSegments(List<Segment> segs, double seconds) {
  final out = <Segment>[];
  var left = seconds;
  for (final s in segs) {
    if (left < 1) break;
    if (s.length <= left) {
      out.add(s.copy());
    } else {
      out.add(Segment(id: s.id, start: s.end - left, end: s.end, label: s.label));
    }
    left -= out.last.length;
  }
  return out;
}

/// One stream through the main impulse response and its gain.
String _wetBranch(String from, String ir, ReverbEngine e, double offsetDb, String to) =>
    '[$from][$ir]afir=${e.noAutoGain}:irfmt=input,volume=${_db(reverbWetDb + offsetDb)}[$to]';

/// Voice clean-up and reverb, from [from] to the label [reverbed]. The main
/// impulse response is input [ir], the shimmer one input [ir] + 1.
String reverbGraph(String from, ExportSettings s, ReverbEngine e, {required int ir}) {
  final offset = s.reverbAmount.offsetDb;
  final sparkle = s.reverbSparkle;
  return [
    '[$from]highpass=f=100,'
        'equalizer=f=850:t=o:w=1.2:g=3.5,'
        'equalizer=f=3500:t=o:w=1.5:g=-2,'
        'acompressor=threshold=0.063:ratio=3:attack=15:release=180,'
        'extrastereo=m=0.7,'
        'apad=pad_dur=${reverbTailSeconds.toStringAsFixed(0)},'
        'asplit=${sparkle ? 3 : 2}[rdry][rv]${sparkle ? '[rsh]' : ''}',
    '[$ir:a]$_irFormat[ir1]',
    if (sparkle) '[${ir + 1}:a]$_irFormat[ir2]',
    _wetBranch('rv', 'ir1', e, offset, 'rwet'),
    if (sparkle) ...[
      '[rsh]${e.pitchUp},highpass=f=900[rshp]',
      '[rshp][ir2]afir=${e.noAutoGain}:irfmt=input,highpass=f=1500,lowpass=f=6000,'
          'volume=${_db(reverbShimmerDb + offset)}[rshw]',
    ],
    '[rdry][rwet]${sparkle ? '[rshw]' : ''}amix=inputs=${sparkle ? 3 : 2}:normalize=0,'
        'alimiter=limit=$reverbLimit:level=0[reverbed]',
  ].join(';');
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

/// Per-part audio chains plus the join, ending in the label [aout]. With the
/// reverb on, [engine] is required and the impulse responses start at input
/// [irInput].
String audioGraph(List<Segment> segs, ExportSettings s, {int input = 0, ReverbEngine? engine, int irInput = 1}) {
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

  if (s.masjidReverb) {
    parts.add(reverbGraph(joined, s, engine!, ir: irInput));
    joined = 'reverbed';
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

  final post = <String>[
    // Hold the last frame while the reverb rings out.
    if (s.masjidReverb) 'tpad=stop_mode=clone:stop_duration=${reverbTailSeconds.toStringAsFixed(0)}',
  ];
  final total = stitchedDuration(segs, s);
  if (s.fadeEdges && total > 1) {
    final d = min(edgeFadeSeconds, total / 4);
    post.add('fade=t=in:st=0:d=${_n(d)},fade=t=out:st=${_n(total - d)}:d=${_n(d)}');
  }
  parts.add('[$joined]${post.isEmpty ? 'null' : post.join(',')}[vout]');
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
  ReverbRig? reverb,
}) =>
    [
      '-y', '-hide_banner',
      '-i', input,
      if (settings.masjidReverb) ...reverb!.inputArgs(settings),
      '-filter_complex', audioGraph(segments, settings, engine: reverb?.engine),
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
  ReverbRig? reverb,
}) {
  final sameFile = audioInput == videoInput;
  final v = sameFile ? 0 : 1;
  return [
    '-y', '-hide_banner',
    '-i', audioInput,
    if (!sameFile) ...['-i', videoInput],
    if (settings.masjidReverb) ...reverb!.inputArgs(settings),
    '-filter_complex',
    '${audioGraph(segments, settings, engine: reverb?.engine, irInput: v + 1)};'
        '${videoGraph(segments, settings, input: v)}',
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

/// Sends [click] through only the main reverb branch into raw 32-bit floats,
/// to measure the real wet level on the ffmpeg that's running.
List<String> buildWetCheckArgs({
  required String click,
  required String mainIr,
  required ReverbEngine engine,
  required String output,
}) =>
    [
      '-y', '-hide_banner',
      '-i', click,
      '-i', mainIr,
      '-filter_complex',
      '[0:a]apad=pad_dur=${reverbTailSeconds.toStringAsFixed(0)}[rv];[1:a]$_irFormat[ir1];'
          '${_wetBranch('rv', 'ir1', engine, 0, 'aout')}',
      '-map', '[aout]',
      '-c:a', 'pcm_f32le', '-f', 'f32le',
      output,
    ];

/// Fails if this ffmpeg can't run [filter].
List<String> buildFilterCheckArgs({required String input, required String filter}) => [
      '-y', '-hide_banner',
      '-i', input,
      '-af', filter,
      '-f', 'null', '-',
    ];

/// Decode to mono 16-bit PCM at a low rate, for drawing the waveform.
List<String> buildWaveformArgs({required String input, required String output, int sampleRate = 4000}) => [
      '-y', '-hide_banner', '-v', 'error',
      '-i', input,
      '-vn', '-ac', '1', '-ar', '$sampleRate',
      '-f', 's16le', '-acodec', 'pcm_s16le',
      output,
    ];
