import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'editor_controller.dart';
import 'media_converter.dart';

/// A video's size: its short side in pixels ("1080p" is 1080 pixels high when wide, 1080
/// wide when tall), the long one following from the [VideoRatio]. Every size is laid out
/// [VideoFormat.layoutShortSide] points on its short side, so they all frame the score the
/// same way; bigger ones are only sharper.
enum VideoResolution {
  sd480(480, '480p'),
  hd720(720, '720p'),
  hd1080(1080, '1080p'),
  qhd1440(1440, '1440p'),
  uhd2160(2160, '4K'),
  uhd4320(4320, '8K');

  const VideoResolution(this.shortSide, this.label);
  final int shortSide;
  final String label;

  /// The frame's pixels at [ratio], both even (H.264 in 4:2:0 needs that).
  ({int width, int height}) size(VideoRatio ratio) {
    int even(double v) => math.max(2, (v / 2).round() * 2);
    return ratio.value >= 1
        ? (width: even(shortSide * ratio.value), height: shortSide)
        : (width: shortSide, height: even(shortSide / ratio.value));
  }
}

/// A video's shape, width : height: one of the [presets], or any the user types between
/// [min] and [max] (1:4 to 4:1; wider would be more pixels than H.264 allows at 4K; at 8K it
/// allows only shapes near 16:9, see [VideoCodec.fits]).
@immutable
class VideoRatio {
  const VideoRatio(this.width, this.height);
  final double width, height;

  static const widescreen = VideoRatio(16, 9);
  static const presets = [widescreen, VideoRatio(21, 9), VideoRatio(4, 3), VideoRatio(1, 1), VideoRatio(9, 16)];
  static const min = 1 / 4, max = 4.0;

  double get value => width / height;

  /// "16:9", "2.39:1".
  String get label => '${_number(width)}:${_number(height)}';

  static String _number(double v) => v == v.roundToDouble() ? '${v.round()}' : '$v';

  /// Reads "16:9", "16/9", "1920x1080" or "1920 × 1080" (both reduced to 16:9), or one
  /// number ("2.39", read as 2.39:1). Null if it isn't a ratio within [min]…[max].
  static VideoRatio? parse(String text) {
    final parts = text.trim().split(RegExp(r'\s*[:/x×X]\s*'));
    if (parts.length > 2) return null;
    final w = double.tryParse(parts.first), h = parts.length == 2 ? double.tryParse(parts.last) : 1.0;
    if (w == null || h == null || !w.isFinite || !h.isFinite || w <= 0 || h <= 0) return null;
    if (w / h < min - 1e-9 || w / h > max + 1e-9) return null;
    // A preset's shape reads as the preset, as it's known ("21:9", not 7:3).
    for (final p in presets) {
      if ((p.value - w / h).abs() < 1e-9) return p;
    }
    if (w == w.roundToDouble() && h == h.roundToDouble()) {
      final d = _gcd(w.round(), h.round());
      return VideoRatio(w / d, h / d);
    }
    return VideoRatio(w, h);
  }

  static int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);

  @override
  bool operator ==(Object other) => other is VideoRatio && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => label;
}

/// Where a video's frame sits in a view of any size: centred, as large as fits, and laid out
/// like the video ([layout] points, [VideoFormat.layoutShortSide] on the short side) at
/// [scale] view points a layout point. The editor's preview draws through it, so it shows what the video will.
@immutable
class VideoFrame {
  const VideoFrame._(this.rect, this.layout, this.scale);

  /// The frame starts on a whole pixel at [devicePixelRatio], so the renderer's pixel
  /// snapping (crisp staff lines) lands on the screen's pixels.
  factory VideoFrame.fit(ui.Size view, double aspectRatio, {double devicePixelRatio = 1}) {
    final layout = VideoFormat.layoutOf(aspectRatio);
    final scale = view.isEmpty ? 0.0 : math.min(view.width / layout.width, view.height / layout.height);
    final size = layout * scale;
    double snap(double v) => (v * devicePixelRatio).floorToDouble() / devicePixelRatio;
    return VideoFrame._(
        ui.Offset(snap((view.width - size.width) / 2), snap((view.height - size.height) / 2)) & size, layout, scale);
  }

  /// No frame: the whole view, laid out at its own size.
  factory VideoFrame.fill(ui.Size view) => VideoFrame._(ui.Offset.zero & view, view, 1);

  /// The frame, in the view's points.
  final ui.Rect rect;
  final ui.Size layout;
  final double scale;

  /// A point in the view, in layout points.
  ui.Offset toLayout(ui.Offset p) => (p - rect.topLeft) / scale;

  /// A rectangle in layout points, in the view's.
  ui.Rect toView(ui.Rect r) => ui.Rect.fromLTWH(
      rect.left + r.left * scale, rect.top + r.top * scale, r.width * scale, r.height * scale);
}

/// What a video is written as: a container and codec FFmpeg writes it with, or PNG images, one
/// a frame, in a folder. Some keep a transparent background ([alpha]).
enum VideoCodec {
  h264('MP4 (H.264)', 'mp4', 'MP4 video', ['libx264', 'libopenh264']),
  hevc('MP4 (HEVC)', 'mp4', 'MP4 video', ['libx265']),
  prores('MOV (ProRes)', 'mov', 'QuickTime movie', ['prores_ks', 'prores_aw'], alpha: true),
  vp9('WebM (VP9)', 'webm', 'WebM video', ['libvpx-vp9'], alpha: true),
  png('PNG Sequence', '', 'Folder', ['png'], alpha: true);

  const VideoCodec(this.label, this.extension, this.typeLabel, this.encoders, {this.alpha = false});
  final String label;

  /// The file's extension; none for [png], whose frames go in a folder of that name.
  final String extension;

  /// What a save panel calls the file.
  final String typeLabel;

  /// FFmpeg's encoders for it, best first: its own or libraries built into it, the same on every
  /// platform (no VideoToolbox, no Media Foundation), so a file comes out alike everywhere.
  final List<String> encoders;

  /// Whether it can keep a transparent background.
  final bool alpha;

  /// Whether its frames are images in a folder rather than one file.
  bool get isSequence => this == png;

  /// Whether it has a sound track.
  bool get hasSound => !isSequence;

  /// The most pixels a frame may have: H.264's and HEVC's highest level (6.2) stop at about
  /// 35.6 megapixels (8K is 33.2); the others go as far as a frame can be drawn ([maxSide]).
  int get maxPixels => this == h264 || this == hevc ? 139264 * 256 : maxSide * maxSide;

  /// The longest side a frame can be drawn at (the GPU's largest texture).
  static const maxSide = 16384;

  /// Whether a frame of [width] × [height] can be written.
  bool fits(int width, int height) => math.max(width, height) <= maxSide && width * height <= maxPixels;
}

/// Light (black on white, the engraving's own colours) or dark paper, as in the app's themes.
enum VideoPaper {
  light('Light'),
  dark('Dark');

  const VideoPaper(this.label);
  final String label;

  AppColors get _colors => AppColors.of(AccentColor.sky, this == light ? ui.Brightness.light : ui.Brightness.dark);
  ui.Color get paper => _colors.scorePaper;
  ui.Color get ink => _colors.scoreInk;
}

/// What a video looks like: its pixel size, frames a second and paper, and what it is written
/// as.
@immutable
class VideoFormat {
  const VideoFormat({
    required this.width,
    required this.height,
    required this.fps,
    this.paper = VideoPaper.light,
    this.codec = VideoCodec.h264,
    this.transparent = false,
  }) : assert(width % 2 == 0 && height % 2 == 0, 'H.264 in 4:2:0 needs even sizes');

  factory VideoFormat.of(VideoResolution resolution,
      {VideoRatio ratio = VideoRatio.widescreen,
      required double fps,
      VideoPaper paper = VideoPaper.light,
      VideoCodec codec = VideoCodec.h264,
      bool transparent = false}) {
    final (:width, :height) = resolution.size(ratio);
    return VideoFormat(width: width, height: height, fps: fps, paper: paper, codec: codec, transparent: transparent);
  }

  final int width, height;

  /// Frames a second: one of [frameRates], or any between [minFps] and [maxFps] ("23.976" is
  /// 24000 / 1001, see [parseRate]).
  final double fps;
  final VideoPaper paper;
  final VideoCodec codec;

  /// No paper behind the score, only its ink (the [paper] says which colour), where the
  /// [codec] can keep it ([hasAlpha]).
  final bool transparent;

  /// Whether the frames are see-through where there is no ink.
  bool get hasAlpha => transparent && codec.alpha;

  /// The colour the frame is drawn on: the paper's, or none.
  ui.Color get paperColor => hasAlpha ? paper.paper.withValues(alpha: 0) : paper.paper;

  /// Whether the [codec] can write frames this size.
  bool get fits => codec.fits(width, height);

  /// Width over height, of the pixels themselves (the ratio, rounded to even pixels).
  double get aspectRatio => width / height;

  static const frameRates = <double>[30, 50, 60, 90, 120];
  static const minFps = 1.0, maxFps = 240.0;

  /// A frame rate as people write it: "30", "59.94", "23.976".
  static String rateLabel(double fps) => fps.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '');

  /// Reads a frame rate typed as "25", "29.97" (or "29,97") or "30000/1001"; a rate within a
  /// thousandth of one of the broadcast rates (23.976, 29.97, 59.94, 119.88) is that rate
  /// exactly, n × 1000 / 1001. Null if it isn't one between [minFps] and [maxFps].
  static double? parseRate(String text) {
    final parts = text.trim().replaceAll(',', '.').split(RegExp(r'\s*/\s*'));
    if (parts.length > 2) return null;
    final n = double.tryParse(parts.first), d = parts.length == 2 ? double.tryParse(parts.last) : 1.0;
    if (n == null || d == null || d <= 0 || !n.isFinite || !d.isFinite) return null;
    var fps = n / d;
    if (fps < minFps - 1e-9 || fps > maxFps + 1e-9) return null;
    final whole = (fps * 1001 / 1000).roundToDouble();
    if (fps != fps.roundToDouble() && (fps - whole * 1000 / 1001).abs() < 1e-3) fps = whole * 1000 / 1001;
    return fps;
  }

  /// [fps] as FFmpeg takes it: a whole number, n × 1000 / 1001 as that fraction, else decimals.
  static String rateArgument(double fps) {
    if (fps == fps.roundToDouble()) return '${fps.round()}';
    final whole = (fps * 1001 / 1000).round();
    if ((fps - whole * 1000 / 1001).abs() < 1e-9) return '${whole * 1000}/1001';
    return '$fps';
  }

  /// The short side, in points, of the preview a frame is laid out like (the height of a
  /// wide video). The score size (the staff space) means the same here as in the editor,
  /// where the score is about this high; a tall video has room for more staves.
  static const layoutShortSide = 540.0;

  /// The points a frame of [aspectRatio] is laid out in.
  static ui.Size layoutOf(double aspectRatio) => aspectRatio >= 1
      ? ui.Size(layoutShortSide * aspectRatio, layoutShortSide)
      : ui.Size(layoutShortSide, layoutShortSide / aspectRatio);

  /// Pixels per point: 2 for 1080p, whatever the ratio.
  double get devicePixelRatio => math.min(width, height) / layoutShortSide;

  /// How many frames cover [seconds] (the last one may run a little past the end).
  int frameCount(double seconds) => seconds <= 0 ? 0 : (seconds * fps - 1e-9).ceil();

  /// The playback time frame [index] shows.
  double timeOf(int index) => index / fps;
}

/// Writing the video with FFmpeg, on every platform: raw frames go in through a pipe, and out
/// comes, by [VideoFormat.codec]:
/// - MP4 that plays anywhere (QuickTime, Windows, browsers, phones, YouTube): H.264 High
///   profile, or HEVC (tagged `hvc1`, as Apple's players want it), in 4:2:0, with AAC-LC stereo
///   audio at 48 kHz and the index up front so it streams;
/// - MOV with ProRes 422 HQ, or 4444 with its alpha when transparent, and 24-bit PCM sound,
///   for editing;
/// - WebM with VP9 (4:2:0, with alpha when transparent) and Opus sound, for the web;
/// - PNG images, one a frame, numbered, without sound.
/// All in BT.709 colour, tagged so players decode it as written.
abstract final class VideoEncoder {
  /// The encoders in `ffmpeg -encoders` [listing].
  static Set<String> listed(String listing) => {
        for (final line in const LineSplitter().convert(listing))
          if (RegExp(r'^\s*V\S{5}\s+(\S+)').firstMatch(line) case final m?) m[1]!,
      };

  /// The best encoder for [codec] in `ffmpeg -encoders` [listing], or null if it has none.
  static String? pick(String listing, [VideoCodec codec = VideoCodec.h264]) =>
      codec.encoders.where(listed(listing).contains).firstOrNull;

  /// The encoders [ffmpeg] has; empty if it can't say.
  static Future<Set<String>> probeAll(String ffmpeg) async {
    final r = await Process.run(ffmpeg, ['-hide_banner', '-encoders']);
    return r.exitCode == 0 ? listed('${r.stdout}') : const {};
  }

  /// Asks [ffmpeg] which encoder for [codec] it has.
  static Future<String?> probe(String ffmpeg, [VideoCodec codec = VideoCodec.h264]) async {
    final have = await probeAll(ffmpeg);
    return codec.encoders.where(have.contains).firstOrNull;
  }

  /// The arguments for FFmpeg: [format]'s frames as raw RGBA on stdin, the sound from
  /// [audio] (none: a silent video) from [audioStart] seconds in, [seconds] long, written to
  /// [output] (for a [VideoCodec.isSequence], a file name pattern such as `take %05d.png`;
  /// its frames have no sound). A sound cut into at the start fades in over a few
  /// milliseconds, so it doesn't click; [fadeOut] fades it out (seconds into the video, and
  /// how long).
  static List<String> arguments({
    required String encoder,
    required VideoFormat format,
    required double seconds,
    required String output,
    String? audio,
    double audioStart = 0,
    ({double at, double length})? fadeOut,
  }) {
    final fps = format.fps, codec = format.codec, alpha = format.hasAlpha;
    if (!codec.hasSound) audio = null;
    // OpenH264 takes a bit rate: 0.12 bits a pixel is ample for ink on paper
    // (HEVC needs about two thirds of H.264's).
    final kbps = (format.width * format.height * fps * (codec == VideoCodec.hevc ? 0.08 : 0.12) / 1000).round();
    final pixels = switch (codec) {
      VideoCodec.h264 || VideoCodec.hevc => 'yuv420p',
      VideoCodec.prores => alpha ? 'yuva444p10le' : 'yuv422p10le',
      VideoCodec.vp9 => alpha ? 'yuva420p' : 'yuv420p',
      VideoCodec.png => alpha ? 'rgba' : 'rgb24',
    };
    return [
      '-hide_banner', '-loglevel', 'error', '-y',
      '-f', 'rawvideo', '-pix_fmt', 'rgba', '-s', '${format.width}x${format.height}', '-framerate', VideoFormat.rateArgument(fps), '-i', '-',
      if (audio != null) ...[...MediaFormats.ffmpegReaders, if (audioStart > 0) ...['-ss', audioStart.toStringAsFixed(6)], '-i', audio],
      '-map', '0:v:0',
      if (audio != null) ...['-map', '1:a:0'],
      // RGB to YUV with the HD colour matrix, and tagged so players decode it the same way.
      '-vf', codec.isSequence ? 'format=$pixels' : 'scale=out_color_matrix=bt709:out_range=tv,format=$pixels',
      '-c:v', encoder,
      ...switch (encoder) {
        'libx264' => ['-preset', 'medium', '-crf', '18', '-profile:v', 'high'],
        'libx265' => ['-preset', 'medium', '-crf', '20', '-tag:v', 'hvc1', '-x265-params', 'log-level=error'],
        // 4444 keeps the alpha (16 bits of it); 422 HQ otherwise. "apl0" as Apple's own files say.
        'prores_ks' => ['-profile:v', alpha ? '4444' : 'hq', if (alpha) ...['-alpha_bits', '16'], '-vendor', 'apl0'],
        'prores_aw' => ['-profile:v', alpha ? '4444' : 'hq', '-vendor', 'apl0'],
        // Constant quality; alt-ref frames drop the alpha in older libvpx.
        'libvpx-vp9' => [
            '-crf', '30', '-b:v', '0', '-deadline', 'good', '-cpu-used', '2', '-row-mt', '1',
            if (alpha) ...['-auto-alt-ref', '0'],
          ],
        'png' => const <String>[],
        _ => ['-b:v', '${kbps}k'],
      },
      if (!codec.isSequence) ...[
        '-g', '${(fps * 2).round()}', // a keyframe every 2 s: quick seeking, and what streaming sites like
        '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709', '-color_range', 'tv',
      ],
      if (audio != null && (audioStart > 0 || fadeOut != null))
        ...['-af', [
          if (audioStart > 0) 'afade=t=in:d=$declick',
          if (fadeOut != null)
            'afade=t=out:st=${math.max(0, fadeOut.at).toStringAsFixed(6)}:d=${fadeOut.length.toStringAsFixed(6)}',
        ].join(',')],
      if (audio != null) ...[
        ...switch (codec) {
          VideoCodec.prores => ['-c:a', 'pcm_s24le'],
          VideoCodec.vp9 => ['-c:a', 'libopus', '-b:a', '192k'],
          _ => ['-c:a', 'aac', '-b:a', '192k'],
        },
        '-ar', '48000', '-ac', '2',
      ],
      '-t', seconds.toStringAsFixed(6), // the frames' length: a longer recording is cut there
      ...switch (codec) {
        VideoCodec.h264 || VideoCodec.hevc => ['-movflags', '+faststart', '-f', 'mp4'],
        VideoCodec.prores => ['-movflags', '+faststart', '-f', 'mov'],
        VideoCodec.vp9 => ['-f', 'webm'],
        VideoCodec.png => ['-f', 'image2', '-start_number', '1'],
      },
      output,
    ];
  }

  /// What a sequence of [frames] frames in [folder], named [name], calls them, for FFmpeg:
  /// "folder/name %05d.png", numbered from 1 with as many digits as the last needs (at least
  /// 5). FFmpeg reads the whole path as the pattern, so a "%" in it is written "%%".
  static String framePattern(String folder, String name, int frames) =>
      '${_literal(folder)}/${_literal(name)} %0${math.max(5, '$frames'.length)}d.png';

  static String _literal(String text) => text.replaceAll('%', '%%');

  /// Whether every file in [folder] is a frame [framePattern] names for a folder named [name]
  /// (an earlier export, which a new one may replace).
  static bool onlyFrames(Directory folder, String name) {
    final frame = RegExp('^${RegExp.escape(name)} \\d{5,}\\.png\$');
    return folder.listSync().every((e) => e is File && frame.hasMatch(e.uri.pathSegments.last));
  }

  /// Seconds of fade where a sound is cut.
  static const declick = 0.01;
}

/// Where an export has got to.
@immutable
class ExportProgress {
  const ExportProgress(this.frame, this.frames, this.elapsed);
  final int frame, frames;
  final Duration elapsed;

  double get fraction => frames == 0 ? 0 : frame / frames;

  /// Time left at the pace so far; null until a few frames are done.
  Duration? get remaining => frame < 10
      ? null
      : Duration(microseconds: (elapsed.inMicroseconds * (frames - frame) / frame).round());
}

class VideoExportException implements Exception {
  const VideoExportException(this.message);
  final String message;

  @override
  String toString() => message;
}

class VideoExportCancelled implements Exception {
  const VideoExportCancelled();
}

/// Makes a video of the open project: the curated score scrolling past the pointer in time
/// with the recording, exactly as the preview plays it.
///
/// It works on a copy of the curation and the sync taken when it is made, with its own scene
/// (its own tile cache, at the video's pixel density), so the editor's view is untouched and
/// nothing done in the editor meanwhile can change a video half written. Make one per export
/// dialog; [dispose] it when done.
class VideoExport {
  VideoExport._(this._scene, this._curation, this._sync, this._releaseImages, {required this.duration, required this.audio});

  /// Takes what [editor] has open now. The editor must have a score.
  factory VideoExport.of(EditorController editor) {
    final score = editor.score!, sync = editor.sync!, curation = editor.curation!;
    final copy = Curation([for (final p in score.metadata.parts) p.id])
      ..load(curation.lanes, transition: curation.transition);
    final timeline = SyncMap(
        measureStarts: score.timeline.measureStarts, defaultTempo: score.metadata.tempo ?? 100, beats: score.beats)
      ..load(sync.anchors, leadIn: sync.leadIn);
    final scene = CuratedScene(score, style: RenderStyle(staffSpace: editor.staffSpace))
      ..names = editor.scene!.names
      ..condensed = editor.condensed
      ..partOrder = editor.partOrder
      ..scrollFollow = editor.scrollFollow
      ..patches = editor.scene!.patches // none while Attach Image is off
      ..captions = editor.scene!.captions // none while Captions is off
      ..captionStyle = editor.scene!.captionStyle
      ..setTimeline(timeline);
    return VideoExport._(scene, copy, timeline, editor.images.hold(),
        duration: editor.playback.duration, audio: editor.track?.path);
  }

  /// Lets go of the editor's images this export draws (see [ImageEditing.hold]).
  final VoidCallback _releaseImages;

  final CuratedScene _scene;
  final Curation _curation;
  final SyncMap _sync;

  /// Seconds of video: the whole recording or the whole piece, as playback runs.
  final double duration;

  /// Bars in the score, numbered from 1 as Go to counts them.
  int get bars => _sync.measureStarts.length - 1;

  /// Bars [first]…[last] as a performance of their own (see [ClippedTimeline]): from where
  /// [first] first sounds to where [last] next ends after that (a repeat's first time, if it
  /// has one). The video runs from that start (bar 1: from the very beginning) through the
  /// end's settle and fade ([CuratedScene.endOf]); the last bar runs to [duration], so all of
  /// them is the whole video. Null when they aren't bars, or [last] comes before [first].
  ({ScoreTimeline timeline, double start, double musicEnd, double end})? _clip(int first, int last) {
    if (first < 1 || last < first || last > bars) return null;
    if (first == 1 && last == bars) return (timeline: _sync, start: 0, musicEnd: duration, end: duration);
    final starts = _sync.measureStarts;
    final from = _sync.spans(starts[first - 1], starts[first]).firstOrNull;
    if (from == null) return null;
    final start = first == 1 ? 0.0 : from.startSeconds;
    final to = _sync.spans(starts[last - 1], starts[last]).where((s) => s.endSeconds > from.startSeconds + 1e-6).firstOrNull;
    if (to == null) return null;
    final clip = ClippedTimeline(_sync, firstPass: from.pass, start: from.start, lastPass: to.pass, end: to.end);
    final end = last == bars ? duration : CuratedScene.endOf(clip);
    return (timeline: clip, start: start, musicEnd: to.endSeconds, end: end);
  }

  /// The seconds of video bars [first]…[last] make (see [showBars]); null when they aren't a range.
  ({double start, double end})? barRange(int first, int last) {
    final c = _clip(first, last);
    return c == null ? null : (start: c.start, end: c.end);
  }

  /// Makes the video bars [first]…[last] only, as if the score were only those: it starts at
  /// [first] with the staves shown there already in place (no transition under way), and ends
  /// at [last] the way the piece ends, coming to rest and fading to paper. The music either
  /// side is still drawn. False (and nothing changed) when they aren't a range.
  bool showBars(int first, int last) {
    final c = _clip(first, last);
    if (c == null) return false;
    if (_shown != (first, last)) _scene.setTimeline(c.timeline);
    _shown = (first, last);
    span = (start: c.start, end: c.end);
    _musicEnd = c.musicEnd;
    return true;
  }

  /// The seconds of playback the video shows: all of it unless [showBars] says otherwise.
  late ({double start, double end}) span = (start: 0, end: duration);
  late double _musicEnd = duration;

  /// Where the [span]'s music ends: after it the score comes to rest and fades.
  double get musicEnd => _musicEnd;

  /// When each bar first sounds, bar 1 first (at 0, as [barRange] starts it); a bar never
  /// played is where the one before it is.
  late final List<double> barStarts = () {
    final starts = _sync.measureStarts, out = <double>[];
    for (var i = 0; i < bars; i++) {
      final at = i == 0 ? 0.0 : _sync.spans(starts[i], starts[i + 1]).firstOrNull?.startSeconds;
      out.add(at ?? out.last);
    }
    return List<double>.unmodifiable(out);
  }();
  late (int, int) _shown = (1, bars);

  /// The bar and beat sounding at [seconds], as the toolbar writes them ("12.2").
  String barBeatAt(double seconds) {
    final (:measure, :beat) = _scene.score.beats.position(_sync.quarterAtSeconds(seconds) + 1e-9);
    return '${measure + 1}.${beat.floor() + 1}';
  }

  /// The recording's audio file; null for a silent video.
  final String? audio;

  /// The pairs of players sharing a staff, as in the editor when the export was made.
  Set<String> get condensed => _scene.condensed;

  /// The instruments top to bottom, as in the editor when the export was made.
  List<String> get partOrder => _scene.partOrder;

  /// The score size, as in the editor's toolbar.
  double get staffSpace => _scene.style.staffSpace;
  set staffSpace(double value) => _scene.setStaffSpace(value);

  /// Draws the frame at [time] into [size] (points), for a still preview in the dialog;
  /// [transparent]: without the paper, its ink only.
  void paintPreview(ui.Canvas canvas, ui.Size size,
      {required double time, required VideoPaper paper, bool transparent = false, required double devicePixelRatio}) {
    // Laid out like the video (layoutShortSide points on the short side), scaled to fit.
    final scale = size.shortestSide / VideoFormat.layoutShortSide;
    canvas
      ..save()
      ..clipRect(ui.Offset.zero & size)
      ..scale(scale);
    _scene.paint(canvas, size / scale,
        time: time,
        curation: _curation,
        devicePixelRatio: devicePixelRatio * scale,
        end: span.end,
        paper: transparent ? paper.paper.withValues(alpha: 0) : paper.paper,
        ink: paper.ink);
    canvas.restore();
  }

  bool _cancelled = false;
  bool _disposed = false;
  Process? _process;

  /// Stops the export; [write] then throws [VideoExportCancelled]. The next [write] starts
  /// afresh (the dialog offers Export again).
  void cancel() {
    _cancelled = true;
    _process?.kill();
  }

  /// Writes the video to [output] (a file with the [VideoFormat.codec]'s extension; for a
  /// sequence, the folder its frames go in), reporting each frame to [onProgress]: the
  /// playback from [from] to [to] seconds (default: the [span]). The sound of bars cut off
  /// at the end ([showBars]) fades out as the score comes to rest. The file (or folder)
  /// appears only once complete; a failed or cancelled export leaves nothing behind (and an
  /// older file of that name as it was). A folder is only replaced if it holds nothing but
  /// an earlier export's frames.
  Future<void> write(
    String output, {
    required VideoFormat format,
    void Function(ExportProgress progress)? onProgress,
    double? from,
    double? to,
    String? ffmpeg,
  }) async {
    if (_disposed) throw const VideoExportCancelled();
    _cancelled = false; // a cancelled export before this one doesn't stop it
    ffmpeg ??= MediaConverter.findFfmpeg();
    if (ffmpeg == null) throw VideoExportException(missingFfmpegForVideo());
    final codec = format.codec;
    final encoder = await VideoEncoder.probe(ffmpeg, codec);
    if (encoder == null) {
      throw VideoExportException(
          'This FFmpeg can’t write ${codec.label}. Install a full build (with ${codec.encoders.first}).');
    }
    if (!format.fits) {
      throw VideoExportException('${codec.label} can’t be ${format.width} × ${format.height}. Choose a smaller size.');
    }
    final name = output.split(RegExp(r'[/\\]')).last;
    if (codec.isSequence && Directory(output).existsSync() && !VideoEncoder.onlyFrames(Directory(output), name)) {
      throw VideoExportException('“$name” already holds other files. Choose another name.');
    }

    final start = from ?? span.start, end = to ?? span.end;
    final frames = format.frameCount(end - start);
    final fadeOut = _musicEnd < end - 1e-6
        ? (at: _musicEnd - start, length: ScrollMap.settle)
        : end < duration - 1e-6
            ? (at: end - start - VideoEncoder.declick, length: VideoEncoder.declick)
            : null;
    final partial = '$output.part';
    if (codec.isSequence) {
      final folder = Directory(partial);
      if (folder.existsSync()) folder.deleteSync(recursive: true); // an export that never finished
      folder.createSync(recursive: true);
    }
    final process = _process = await Process.start(
      ffmpeg,
      VideoEncoder.arguments(
          encoder: encoder,
          format: format,
          seconds: frames / format.fps,
          output: codec.isSequence ? VideoEncoder.framePattern(partial, name, frames) : partial,
          audio: audio,
          audioStart: start,
          fadeOut: fadeOut),
    );
    final errors = StringBuffer();
    final stderr = process.stderr.transform(const Utf8Decoder(allowMalformed: true)).forEach(errors.write);
    unawaited(process.stdout.drain<void>());
    unawaited(process.stdin.done.catchError((_) {})); // a failed write is caught below

    final clock = Stopwatch()..start();
    (Object, StackTrace)? failure;
    try {
      // A few frames are drawn and read back while FFmpeg encodes the one before them.
      var i = 0;
      await for (final pixels in inOrder(frames, (i) {
        final image = _scene.renderFrame(format.width, format.height,
            time: start + format.timeOf(i),
            curation: _curation,
            devicePixelRatio: format.devicePixelRatio,
            end: span.end,
            paper: format.paperColor,
            ink: format.paper.ink);
        // FFmpeg's RGBA is straight; Flutter's is premultiplied, the same only where it is opaque.
        return image
            .toByteData(format: format.hasAlpha ? ui.ImageByteFormat.rawStraightRgba : ui.ImageByteFormat.rawRgba)
            .whenComplete(image.dispose);
      })) {
        if (_cancelled) break;
        process.stdin.add(pixels!.buffer.asUint8List(pixels.offsetInBytes, pixels.lengthInBytes));
        await process.stdin.flush(); // wait while FFmpeg catches up, instead of queueing frames
        onProgress?.call(ExportProgress(++i, frames, clock.elapsed));
      }
    } catch (e, stack) {
      failure = (e, stack); // FFmpeg quit (its exit code says why), or a frame failed
    }
    try {
      await process.stdin.close();
    } catch (_) {
      // FFmpeg has already gone
    }
    final code = await process.exitCode;
    await stderr;
    _process = null;

    final FileSystemEntity part = codec.isSequence ? Directory(partial) : File(partial);
    if (_cancelled || code != 0 || failure != null) {
      if (part.existsSync()) part.deleteSync(recursive: true);
      if (_cancelled) throw const VideoExportCancelled();
      if (code != 0) throw VideoExportException('FFmpeg couldn’t write the video.\n${_lastLines('$errors')}');
      Error.throwWithStackTrace(failure!.$1, failure.$2);
    }
    switch (FileSystemEntity.typeSync(output)) {
      case FileSystemEntityType.directory:
        // Checked before it began; an earlier export's frames only.
        if (codec.isSequence && VideoEncoder.onlyFrames(Directory(output), name)) {
          Directory(output).deleteSync(recursive: true);
        } else {
          part.deleteSync(recursive: true);
          throw VideoExportException('“$name” already holds other files. Choose another name.');
        }
      case FileSystemEntityType.notFound:
        break;
      default:
        File(output).deleteSync();
    }
    part.renameSync(output);
  }

  /// The results of jobs `0 … count - 1`, in order, with up to [ahead] of them started while
  /// waiting for the first unfinished one. The first that fails ends the stream with its
  /// error; stopping listening starts no more (those running finish unheard).
  @visibleForTesting
  static Stream<T> inOrder<T>(int count, Future<T> Function(int i) start, {int ahead = 3}) async* {
    final running = Queue<Future<T>>();
    var next = 0;
    while (next < count || running.isNotEmpty) {
      while (next < count && running.length < ahead) {
        final job = start(next++);
        unawaited(job.then((_) {}, onError: (Object _) {})); // its error is heard when it comes up
        running.add(job);
      }
      yield await running.removeFirst();
    }
  }

  void dispose() {
    _disposed = true;
    cancel();
    _scene.dispose();
    _curation.dispose();
    _sync.dispose();
    _releaseImages();
  }

  /// What to tell someone who needs FFmpeg to export a video, for their platform.
  static String missingFfmpegForVideo() =>
      MediaConverter.missingFfmpegHelp(lead: 'To export video, install FFmpeg (free), then export again:');

  static String _lastLines(String text) => text.trim().split('\n').reversed.take(4).toList().reversed.join('\n');
}
