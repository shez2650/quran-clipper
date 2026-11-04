import 'dart:math';

/// One recited part of the source, in seconds.
class Segment {
  Segment({required this.id, required this.start, required this.end, this.label = ''});

  final String id;
  double start;
  double end;
  String label;

  double get length => end - start;

  Segment copy() => Segment(id: id, start: start, end: end, label: label);

  Map<String, dynamic> toJson() => {'id': id, 'start': start, 'end': end, 'label': label};

  factory Segment.fromJson(Map<String, dynamic> j) => Segment(
        id: j['id'] as String,
        start: (j['start'] as num).toDouble(),
        end: (j['end'] as num).toDouble(),
        label: (j['label'] as String?) ?? '',
      );
}

class Project {
  Project({
    required this.id,
    required this.title,
    required this.audioPath,
    this.videoPath,
    this.sourceUrl,
    this.duration = 0,
    List<Segment>? segments,
    DateTime? created,
    DateTime? updated,
  })  : segments = segments ?? [],
        created = created ?? DateTime.now(),
        updated = updated ?? DateTime.now();

  final String id;
  String title;

  /// File used for playback, waveform and audio rendering.
  String audioPath;

  /// File with picture, if any. Same as [audioPath] for a local video file.
  String? videoPath;

  /// YouTube link the project was imported from.
  String? sourceUrl;

  /// Source length in seconds.
  double duration;
  List<Segment> segments;
  final DateTime created;
  DateTime updated;

  double get stitchedLength => segments.fold(0.0, (a, s) => a + s.length);

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'audioPath': audioPath,
        'videoPath': videoPath,
        'sourceUrl': sourceUrl,
        'duration': duration,
        'segments': segments.map((s) => s.toJson()).toList(),
        'created': created.toIso8601String(),
        'updated': updated.toIso8601String(),
      };

  factory Project.fromJson(Map<String, dynamic> j) => Project(
        id: j['id'] as String,
        title: j['title'] as String,
        audioPath: j['audioPath'] as String,
        videoPath: j['videoPath'] as String?,
        sourceUrl: j['sourceUrl'] as String?,
        duration: (j['duration'] as num?)?.toDouble() ?? 0,
        segments: ((j['segments'] as List?) ?? [])
            .map((e) => Segment.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        created: DateTime.tryParse(j['created'] as String? ?? ''),
        updated: DateTime.tryParse(j['updated'] as String? ?? ''),
      );
}

enum AudioFormat {
  mp3('MP3', 'mp3', lossy: true),
  m4a('M4A (AAC)', 'm4a', lossy: true),
  opus('Opus', 'opus', lossy: true),
  wav('WAV', 'wav', lossy: false),
  flac('FLAC', 'flac', lossy: false);

  const AudioFormat(this.label, this.extension, {required this.lossy});
  final String label;
  final String extension;
  final bool lossy;
}

enum JoinMode {
  hardCut('Hard cut', 'Straight back to back (with an inaudible de-click)'),
  fade('Fade out / in', 'Each part fades out, the next fades in'),
  crossfade('Crossfade', 'Parts overlap and blend into each other'),
  gap('Silent gap', 'A short pause between parts');

  const JoinMode(this.label, this.description);
  final String label;
  final String description;
}

enum VideoMode {
  none('Audio only', 'Just the audio file'),
  stillImage('Still image', 'Audio over a picture (or a plain title card)'),
  original('Original footage', 'Keep the video for the recited parts');

  const VideoMode(this.label, this.description);
  final String label;
  final String description;
}

/// How loud the masjid reverb is, as a change to its tuned level.
enum ReverbAmount {
  light('Light', -4),
  normal('Normal', 0),
  strong('Strong', 4);

  const ReverbAmount(this.label, this.offsetDb);
  final String label;
  final double offsetDb;
}

class ExportSettings {
  ExportSettings({
    this.format = AudioFormat.mp3,
    this.bitrateKbps = 192,
    this.join = JoinMode.hardCut,
    this.joinSeconds = 0.5,
    this.normalize = false,
    this.fadeEdges = false,
    this.video = VideoMode.none,
    this.imagePath,
    this.videoHeight = 720,
    this.masjidReverb = false,
    this.reverbAmount = ReverbAmount.normal,
    this.reverbSparkle = true,
  });

  AudioFormat format;
  int bitrateKbps;
  JoinMode join;

  /// Length of the fade, crossfade or gap. Ignored for [JoinMode.hardCut].
  double joinSeconds;

  /// EBU R128 loudness normalisation of the whole result.
  bool normalize;

  /// Fade in at the very start and out at the very end of the result.
  bool fadeEdges;
  VideoMode video;

  /// Picture for [VideoMode.stillImage]. A title card is generated when null.
  String? imagePath;
  int videoHeight;

  /// Long, dark, wide reverb with a light clean-up of the voice before it.
  bool masjidReverb;
  ReverbAmount reverbAmount;

  /// Faint octave-up shimmer in the reverb.
  bool reverbSparkle;

  ExportSettings copy() => ExportSettings.fromJson(toJson());

  Map<String, dynamic> toJson() => {
        'format': format.name,
        'bitrateKbps': bitrateKbps,
        'join': join.name,
        'joinSeconds': joinSeconds,
        'normalize': normalize,
        'fadeEdges': fadeEdges,
        'video': video.name,
        'imagePath': imagePath,
        'videoHeight': videoHeight,
        'masjidReverb': masjidReverb,
        'reverbAmount': reverbAmount.name,
        'reverbSparkle': reverbSparkle,
      };

  factory ExportSettings.fromJson(Map<String, dynamic> j) {
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.firstWhere((v) => v.name == name, orElse: () => fallback);
    return ExportSettings(
      format: pick(AudioFormat.values, j['format'], AudioFormat.mp3),
      bitrateKbps: (j['bitrateKbps'] as num?)?.toInt() ?? 192,
      join: pick(JoinMode.values, j['join'], JoinMode.hardCut),
      joinSeconds: (j['joinSeconds'] as num?)?.toDouble() ?? 0.5,
      normalize: j['normalize'] as bool? ?? false,
      fadeEdges: j['fadeEdges'] as bool? ?? false,
      video: pick(VideoMode.values, j['video'], VideoMode.none),
      imagePath: j['imagePath'] as String?,
      videoHeight: (j['videoHeight'] as num?)?.toInt() ?? 720,
      masjidReverb: j['masjidReverb'] as bool? ?? false,
      reverbAmount: pick(ReverbAmount.values, j['reverbAmount'], ReverbAmount.normal),
      reverbSparkle: j['reverbSparkle'] as bool? ?? true,
    );
  }
}

final _rand = Random();

String newId() =>
    '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${_rand.nextInt(1 << 30).toRadixString(36)}';
