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
  hd720(720, '720p'),
  hd1080(1080, '1080p'),
  qhd1440(1440, '1440p'),
  uhd2160(2160, '4K');

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
/// [min] and [max] (1:4 to 4:1; wider would be more pixels than H.264 allows at 4K).
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

/// What a video looks like: its pixel size, frames a second and paper.
@immutable
class VideoFormat {
  const VideoFormat({required this.width, required this.height, required this.fps, this.paper = VideoPaper.light})
      : assert(width % 2 == 0 && height % 2 == 0, 'H.264 in 4:2:0 needs even sizes');

  factory VideoFormat.of(VideoResolution resolution,
      {VideoRatio ratio = VideoRatio.widescreen, required int fps, VideoPaper paper = VideoPaper.light}) {
    final (:width, :height) = resolution.size(ratio);
    return VideoFormat(width: width, height: height, fps: fps, paper: paper);
  }

  final int width, height, fps;
  final VideoPaper paper;

  /// Width over height, of the pixels themselves (the ratio, rounded to even pixels).
  double get aspectRatio => width / height;

  static const frameRates = [24, 25, 30, 50, 60];

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

/// Writing the video with FFmpeg, on every platform: raw frames go in through a pipe, an MP4
/// comes out that plays anywhere (QuickTime, Windows, browsers, phones, YouTube): H.264 High
/// profile in 4:2:0 with BT.709 colour, AAC-LC stereo audio at 48 kHz, the index up front so it
/// streams.
abstract final class VideoEncoder {
  /// H.264 encoders in order of preference. libx264 is in most builds (Homebrew, Gyan's
  /// Windows builds, Linux distributions); the others are the platforms' own, for FFmpeg
  /// builds without it.
  static const preferred = ['libx264', 'h264_videotoolbox', 'h264_mf', 'libopenh264'];

  /// The best H.264 encoder in `ffmpeg -encoders` [listing], or null if it has none.
  static String? pick(String listing) {
    final available = {
      for (final line in const LineSplitter().convert(listing))
        if (RegExp(r'^\s*V\S{5}\s+(\S+)').firstMatch(line) case final m?) m[1]!,
    };
    return preferred.where(available.contains).firstOrNull;
  }

  /// Asks [ffmpeg] which H.264 encoder it has.
  static Future<String?> probe(String ffmpeg) async {
    final r = await Process.run(ffmpeg, ['-hide_banner', '-encoders']);
    return r.exitCode == 0 ? pick('${r.stdout}') : null;
  }

  /// The arguments for FFmpeg: [format]'s frames as raw RGBA on stdin, the sound from
  /// [audio] (none: a silent video) from [audioStart] seconds in, [seconds] long, written as
  /// MP4 to [output]. A sound cut into at the start fades in over a few milliseconds, so it
  /// doesn't click; [fadeOut] fades it out (seconds into the video, and how long).
  static List<String> arguments({
    required String encoder,
    required VideoFormat format,
    required double seconds,
    required String output,
    String? audio,
    double audioStart = 0,
    ({double at, double length})? fadeOut,
  }) {
    final fps = format.fps;
    // Hardware and OpenH264 encoders take a bit rate: 0.12 bits a pixel is ample for ink on paper.
    final kbps = (format.width * format.height * fps * 0.12 / 1000).round();
    return [
      '-hide_banner', '-loglevel', 'error', '-y',
      '-f', 'rawvideo', '-pix_fmt', 'rgba', '-s', '${format.width}x${format.height}', '-framerate', '$fps', '-i', '-',
      if (audio != null) ...[...MediaFormats.ffmpegReaders, if (audioStart > 0) ...['-ss', audioStart.toStringAsFixed(6)], '-i', audio],
      '-map', '0:v:0',
      if (audio != null) ...['-map', '1:a:0'],
      // RGB to 4:2:0 with the HD colour matrix, and tagged so players decode it the same way.
      '-vf', 'scale=out_color_matrix=bt709:out_range=tv,format=yuv420p',
      '-c:v', encoder,
      ...switch (encoder) {
        'libx264' => ['-preset', 'medium', '-crf', '18', '-profile:v', 'high'],
        'h264_videotoolbox' => ['-b:v', '${kbps}k', '-profile:v', 'high', '-allow_sw', '1'],
        _ => ['-b:v', '${kbps}k'],
      },
      '-g', '${fps * 2}', // a keyframe every 2 s: quick seeking, and what streaming sites like
      '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709', '-color_range', 'tv',
      if (audio != null && (audioStart > 0 || fadeOut != null))
        ...['-af', [
          if (audioStart > 0) 'afade=t=in:d=$declick',
          if (fadeOut != null)
            'afade=t=out:st=${math.max(0, fadeOut.at).toStringAsFixed(6)}:d=${fadeOut.length.toStringAsFixed(6)}',
        ].join(',')],
      if (audio != null) ...['-c:a', 'aac', '-b:a', '192k', '-ar', '48000', '-ac', '2'],
      '-t', seconds.toStringAsFixed(6), // the frames' length: a longer recording is cut there
      '-movflags', '+faststart',
      '-f', 'mp4', output,
    ];
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

  /// Draws the frame at [time] into [size] (points), for a still preview in the dialog.
  void paintPreview(ui.Canvas canvas, ui.Size size,
      {required double time, required VideoPaper paper, required double devicePixelRatio}) {
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
        paper: paper.paper,
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

  /// Writes the video to [output] (an .mp4), reporting each frame to [onProgress]: the
  /// playback from [from] to [to] seconds (default: the [span]). The sound of bars cut off
  /// at the end ([showBars]) fades out as the score comes to rest. The file
  /// appears only once complete; a failed or cancelled export leaves nothing behind (and an
  /// older file of that name as it was).
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
    final encoder = await VideoEncoder.probe(ffmpeg);
    if (encoder == null) {
      throw const VideoExportException(
          'This FFmpeg cannot write H.264 video. Install a full build of FFmpeg (with libx264).');
    }

    final start = from ?? span.start, end = to ?? span.end;
    final frames = format.frameCount(end - start);
    final fadeOut = _musicEnd < end - 1e-6
        ? (at: _musicEnd - start, length: ScrollMap.settle)
        : end < duration - 1e-6
            ? (at: end - start - VideoEncoder.declick, length: VideoEncoder.declick)
            : null;
    final partial = '$output.part';
    final process = _process = await Process.start(
      ffmpeg,
      VideoEncoder.arguments(
          encoder: encoder,
          format: format,
          seconds: frames / format.fps,
          output: partial,
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
            paper: format.paper.paper,
            ink: format.paper.ink);
        return image.toByteData(format: ui.ImageByteFormat.rawRgba).whenComplete(image.dispose);
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

    final part = File(partial);
    if (_cancelled || code != 0 || failure != null) {
      if (part.existsSync()) part.deleteSync();
      if (_cancelled) throw const VideoExportCancelled();
      if (code != 0) throw VideoExportException('FFmpeg could not write the video.\n${_lastLines('$errors')}');
      Error.throwWithStackTrace(failure!.$1, failure.$2);
    }
    final target = File(output);
    if (target.existsSync()) target.deleteSync();
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
      MediaConverter.missingFfmpegHelp(lead: 'Exporting a video needs FFmpeg (free). Install it once, then export again:');

  static String _lastLines(String text) => text.trim().split('\n').reversed.take(4).toList().reversed.join('\n');
}
