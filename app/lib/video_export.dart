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
import 'file_names.dart';
import 'media_converter.dart';
import 'l10n/l10n.dart';
import 'video_frame.dart';

export 'video_frame.dart';

/// A video's size: its short side in pixels ("1080p" is 1080 pixels high when wide, 1080
/// wide when tall), the long one following from the [VideoRatio]. Every size is laid out
/// [VideoFormat.layoutShortSide] points on its short side, so they all frame the score the
/// same way; bigger ones are only sharper. Up to 1440p: at 4:1 that is still a frame every
/// format writes and every GPU draws.
enum VideoResolution {
  sd480(480, '480p'),
  hd720(720, '720p'),
  hd1080(1080, '1080p'),
  qhd1440(1440, '1440p');

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

/// What a video is written as: a container and codec FFmpeg writes it with, or PNG images, one
/// a frame, in a folder. Some keep a transparent background ([alpha]).
enum VideoCodec {
  h264('MP4 (H.264)', 'mp4', 'MP4 video', ['libx264', 'libopenh264', 'h264_videotoolbox', 'h264_mf']),
  hevc('MP4 (HEVC)', 'mp4', 'MP4 video', ['libx265', 'hevc_videotoolbox', 'hevc_mf']),
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
  /// platform, so a file comes out alike everywhere; the platform's own (VideoToolbox, Media
  /// Foundation) last, for builds without them (an LGPL FFmpeg has no libx264).
  final List<String> encoders;

  /// Whether it can keep a transparent background.
  final bool alpha;

  /// Whether its frames are images in a folder rather than one file.
  bool get isSequence => this == png;

  /// Whether it has a sound track.
  bool get hasSound => !isSequence;
}

/// Light (black on white, the engraving's own colours) or dark paper, as in the app's themes.
enum VideoPaper {
  light('Light'),
  dark('Dark');

  const VideoPaper(this.label);
  final String label;

  ui.Brightness get _brightness => this == light ? ui.Brightness.light : ui.Brightness.dark;
  ui.Color get paper => ScorePaper.paper(_brightness);
  ui.Color get ink => ScorePaper.ink(_brightness);
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
  static const layoutShortSide = VideoFrame.layoutShortSide;

  /// The points a frame of [aspectRatio] is laid out in.
  static ui.Size layoutOf(double aspectRatio) => VideoFrame.layoutOf(aspectRatio);

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
    List<ExportSound> sounds = const [],
    ({double at, double length})? fadeOut,
  }) {
    final fps = format.fps, codec = format.codec, alpha = format.hasAlpha;
    // One recording heard throughout is read from where the video starts; several (or one
    // with silence) are cut, faded, set in place and mixed.
    if (sounds case [final only] when only.at <= 1e-6 && only.end >= seconds - 1e-6) {
      audio = only.path;
      audioStart = only.from - only.at;
      sounds = const [];
    }
    if (!codec.hasSound) {
      audio = null;
      sounds = const [];
    }
    final files = [for (final path in {for (final s in sounds) s.path}) path];
    final mix = sounds.isEmpty ? null : _mix(sounds, files, seconds, fadeOut);
    // OpenH264 and the platforms' encoders take a bit rate: 0.12 bits a pixel is ample for ink on paper
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
      for (final path in files) ...[...MediaFormats.ffmpegReaders, '-i', path],
      '-map', '0:v:0',
      if (audio != null) ...['-map', '1:a:0'],
      if (mix != null) ...['-filter_complex', mix, '-map', '[sound]'],
      // RGB to YUV with the HD colour matrix, and tagged so players decode it the same way.
      '-vf', codec.isSequence ? 'format=$pixels' : 'scale=out_color_matrix=bt709:out_range=tv,format=$pixels',
      '-c:v', encoder,
      ...switch (encoder) {
        'libx264' => ['-preset', 'medium', '-crf', '18', '-profile:v', 'high'],
        'h264_videotoolbox' => ['-b:v', '${kbps}k', '-profile:v', 'high', '-allow_sw', '1'],
        'libx265' => ['-preset', 'medium', '-crf', '20', '-tag:v', 'hvc1', '-x265-params', 'log-level=error'],
        'hevc_videotoolbox' => ['-b:v', '${kbps}k', '-tag:v', 'hvc1', '-allow_sw', '1'],
        'hevc_mf' => ['-b:v', '${kbps}k', '-tag:v', 'hvc1'],
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
      if (audio != null || mix != null) ...[
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

  /// FFmpeg's arguments writing [sounds] mixed (as [arguments] mixes them), [seconds] long, to
  /// [output] as AAC in an M4A, [fadeOut] faded out.
  static List<String> soundArguments(
      {required double seconds, required String output, required List<ExportSound> sounds, ({double at, double length})? fadeOut}) {
    final files = [for (final path in {for (final s in sounds) s.path}) path];
    return [
      '-hide_banner', '-loglevel', 'error', '-y',
      // The mix's inputs are numbered from 1 (0 is a video's frames): a silent one first.
      '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo',
      for (final path in files) ...[...MediaFormats.ffmpegReaders, '-i', path],
      '-filter_complex', _mix(sounds, files, seconds, fadeOut), '-map', '[sound]',
      '-c:a', 'aac', '-b:a', '192k', '-ar', '48000', '-ac', '2',
      '-t', seconds.toStringAsFixed(6),
      '-movflags', '+faststart', '-f', 'mp4',
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
  /// (an earlier export, which a new one may replace), or what the system leaves in a folder
  /// looked at (Finder's `.DS_Store`, Explorer's `Thumbs.db` and `desktop.ini`, a frame's `._`
  /// twin on a disk that isn't the Mac's own).
  static bool onlyFrames(Directory folder, String name) {
    final frame = RegExp('^(\\._)?${RegExp.escape(name)} \\d{5,}\\.png\$');
    return folder.listSync().every((e) {
      final file = e.uri.pathSegments.last;
      return e is File && (frame.hasMatch(file) || _systemFiles.contains(file));
    });
  }

  static const _systemFiles = {'.DS_Store', 'Thumbs.db', 'desktop.ini'};

  /// Seconds of fade where a sound is cut.
  static const declick = 0.01;

  /// FFmpeg's filter graph mixing [sounds] (their files are inputs 1, 2… in [files]' order) into
  /// `[sound]`: each cut from its file, faded as playback fades it (straight ramps, `afade`'s
  /// own), set at its time, then all added together, as they sound, and [fadeOut] after.
  static String _mix(List<ExportSound> sounds, List<String> files, double seconds, ({double at, double length})? fadeOut) {
    String n(double v) => v.toStringAsFixed(6);
    final parts = <String>[];
    for (final (i, s) in sounds.indexed) {
      // Begun before the video: from where it has got, faded in no more (but for a click).
      final cut = math.max(0.0, -s.at), at = s.at + cut, from = s.from + cut;
      final length = math.min(s.end, seconds) - at;
      if (length <= 0) continue;
      final fadeIn = cut > 0 ? declick : s.fadeIn, fadeOutAt = s.end - s.fadeOut - at;
      parts.add('[${files.indexOf(s.path) + 1}:a:0]atrim=start=${n(from)}:end=${n(from + length)},asetpts=PTS-STARTPTS,'
          'aresample=48000,aformat=channel_layouts=stereo'
          '${fadeIn > 0 ? ',afade=t=in:st=0:d=${n(fadeIn)}' : ''}'
          '${s.fadeOut > 0 && fadeOutAt < length ? ',afade=t=out:st=${n(math.max(0, fadeOutAt))}:d=${n(s.fadeOut)}' : ''}'
          ',adelay=${(at * 1000).round()}:all=1[s$i]');
    }
    final inputs = [for (final p in parts) p.substring(p.lastIndexOf('['))].join();
    final count = parts.length;
    final ending = [
      if (fadeOut != null) 'afade=t=out:st=${n(math.max(0, fadeOut.at))}:d=${n(fadeOut.length)}',
    ];
    return [
      ...parts,
      count == 0
          ? 'anullsrc=r=48000:cl=stereo,atrim=duration=${n(seconds)}[sound]'
          : '${inputs}amix=inputs=$count:normalize=0:dropout_transition=0,apad${ending.isEmpty ? '' : ',${ending.join(',')}'}[sound]',
    ].join(';');
  }
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

/// A recording's sound in a video: its file [path] from [from] seconds in at [at] seconds of the
/// performance (of the video, in [VideoEncoder.arguments]) until [end], faded in over [fadeIn]
/// and out over [fadeOut] ([PlayChunk]'s).
typedef ExportSound = ({String path, double from, double at, double end, double fadeIn, double fadeOut});

/// Makes a video of the open project: the curated score scrolling past the pointer in time
/// with the recording, exactly as the preview plays it.
///
/// It works on a copy of the curation and the sync taken when it is made, with its own scene
/// (its own tile cache, at the video's pixel density), so the editor's view is untouched and
/// nothing done in the editor meanwhile can change a video half written. Make one per export
/// dialog; [dispose] it when done.
class VideoExport {
  VideoExport._(this._scene, this._curation, this._sync, this._releaseImages, {required this.duration, required this.sounds});

  /// Takes what [editor] has open now; with [take], that recording heard whole in its own time
  /// ([EditorController.performedCopy]). The editor must have a score.
  factory VideoExport.of(EditorController editor, {String? take}) {
    final score = editor.score!, curation = editor.curation!;
    final copy = Curation([for (final p in score.metadata.parts) p.id])
      ..load(curation.lanes, transition: curation.transition);
    // The performance as it plays: one recording's sync, or several spliced by their lanes.
    final (:timeline, :chunks, :files) = editor.performedCopy(take: take);
    final scene = CuratedScene(score, style: RenderStyle(staffSpace: editor.staffSpace))
      ..settings = editor.sceneSettings // the preview's: no images or captions while their extension is off
      ..setTimeline(timeline);
    // As playback's: the whole of what is heard, or the whole piece, whichever is longer.
    final duration = math.max(CuratedScene.endOf(timeline, editor.motion), chunks.fold(0.0, (end, c) => math.max(end, c.end)));
    return VideoExport._(scene, copy, timeline, editor.images.hold(), duration: duration, sounds: [
      for (final c in chunks)
        if (files[c.take] case final path?) (path: path, from: c.from, at: c.at, end: c.end, fadeIn: c.fadeIn, fadeOut: c.fadeOut),
    ]);
  }

  /// Lets go of the editor's images this export draws (see [ImageEditing.hold]).
  final VoidCallback _releaseImages;

  final CuratedScene _scene;
  final Curation _curation;
  final ScoreTimeline _sync;

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
    final clip = ClippedTimeline.bars(_sync, first, last);
    if (clip == null) return null;
    final end = last == bars ? duration : CuratedScene.endOf(clip.timeline, _scene.motion);
    return (timeline: clip.timeline, start: clip.start, musicEnd: clip.musicEnd, end: end);
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

  /// The captions as subtitles of the video showing [span], timed from its start (the
  /// Captions extension; none while it is off).
  List<SubtitleCue> get subtitles => captionCues(_scene.captions, _scene.timeline, from: span.start, to: span.end);

  /// Writes [subtitles] as an .srt beside [video] (its name, that extension), replacing one
  /// there: it belongs to the video. Returns its path.
  Future<String> writeSubtitlesBeside(String video) async {
    final dot = video.lastIndexOf('.'), slash = video.lastIndexOf(Platform.pathSeparator);
    final path = '${dot > slash ? video.substring(0, dot) : video}.${SubtitleFormat.srt.extension}';
    await File(path).writeAsString(writeSubtitles(subtitles, SubtitleFormat.srt));
    return path;
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

  /// What is heard, in the performance's seconds: each recording's file from a time in it, faded
  /// in and out as playback fades it ([PlayChunk]); none for a silent video.
  final List<ExportSound> sounds;

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

  /// How the sound of [start]…[end] fades out: over the settle after the music, or cut (but
  /// for a click) where the video ends early; null when it runs to the end.
  ({double at, double length})? _fadeOut(double start, double end) => _musicEnd < end - 1e-6
      // A settle of 0 cuts the sound (FFmpeg's afade takes a length of 0 as its own 1 s).
      ? (at: _musicEnd - start, length: math.max(_scene.motion.settle, VideoEncoder.declick))
      : end < duration - 1e-6
          ? (at: end - start - VideoEncoder.declick, length: VideoEncoder.declick)
          : null;

  /// [sounds] heard in [start]…[end], timed from [start].
  List<ExportSound> _soundsIn(double start, double end) => [
        for (final c in sounds)
          if (c.end > start + 1e-6 && c.at < end - 1e-6)
            (path: c.path, from: c.from, at: c.at - start, end: c.end - start, fadeIn: c.fadeIn, fadeOut: c.fadeOut),
      ];

  /// Writes the sound of [span] alone to [output] (AAC in an M4A), as a video of it would have
  /// it. Throws a [VideoExportException] when FFmpeg is missing or fails.
  Future<void> writeSound(String output, {String? ffmpeg}) async {
    ffmpeg ??= MediaConverter.findFfmpeg();
    if (ffmpeg == null) throw VideoExportException(missingFfmpegForVideo());
    final (:start, :end) = span;
    final r = await Process.run(ffmpeg,
        VideoEncoder.soundArguments(seconds: end - start, output: output, sounds: _soundsIn(start, end), fadeOut: _fadeOut(start, end)));
    if (r.exitCode != 0) throw VideoExportException('${'FFmpeg couldn’t write the sound.'.tr}\n${_lastLines('${r.stderr}')}');
  }

  /// Writes the video to [output] (a file with the [VideoFormat.codec]'s extension; for a
  /// sequence, the folder its frames go in), reporting each frame to [onProgress]: the
  /// playback from [from] to [to] seconds (default: the [span]). The sound of bars cut off
  /// at the end ([showBars]) fades out as the score comes to rest. The file (or folder)
  /// appears only once complete; a failed or cancelled export leaves nothing behind (and an
  /// older file of that name as it was). A folder is only replaced if it holds nothing but
  /// an earlier export's frames; one that gains other files while the video is written keeps
  /// them, and the video goes beside it instead ("Take 2"). Returns where the video went.
  /// [onFrame] gets each frame as drawn, to show (its own handle:
  /// it disposes it), so nothing need draw the scene again at another size meanwhile, which
  /// would make the renderer draw its tiles again for every frame.
  Future<String> write(
    String output, {
    required VideoFormat format,
    void Function(ExportProgress progress)? onProgress,
    void Function(ui.Image frame)? onFrame,
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
          'This FFmpeg can’t write {format}. Install a full build (with {encoder}).'.fill({'format': codec.label.tr, 'encoder': codec.encoders.first}));
    }
    final name = fileNameOf(output);
    if (codec.isSequence && Directory(output).existsSync() && !VideoEncoder.onlyFrames(Directory(output), name)) {
      throw VideoExportException('“{name}” already holds other files. Choose another name.'.fill({'name': name}));
    }

    final start = from ?? span.start, end = to ?? span.end;
    final frames = format.frameCount(end - start);
    final fadeOut = _fadeOut(start, end);
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
          sounds: _soundsIn(start, end),
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
        onFrame?.call(image.clone());
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
      if (code != 0) throw VideoExportException('${'FFmpeg couldn’t write the video.'.tr}\n${_lastLines('$errors')}');
      Error.throwWithStackTrace(failure!.$1, failure.$2);
    }
    var target = output;
    switch (FileSystemEntity.typeSync(output)) {
      case FileSystemEntityType.directory:
        // Checked before it began, but something may have been put in it since: a finished
        // video isn't thrown away for that, it goes beside it.
        if (codec.isSequence && VideoEncoder.onlyFrames(Directory(output), name)) {
          Directory(output).deleteSync(recursive: true);
        } else {
          target = _besides(output, file: !codec.isSequence);
        }
      case FileSystemEntityType.notFound:
        break;
      default:
        File(output).deleteSync();
    }
    part.renameSync(target);
    return target;
  }

  /// [path] with the first number that names nothing added to its name, before the extension
  /// of a [file]: "Take 2", "Take 2.mp4" (a folder has none: "Op. 9 2").
  static String _besides(String path, {required bool file}) {
    final slash = path.lastIndexOf(RegExp(r'[/\\]')), dot = path.lastIndexOf('.');
    final cut = file && dot > slash + 1 ? dot : path.length;
    for (var i = 2;; i++) {
      final free = '${path.substring(0, cut)} $i${path.substring(cut)}';
      if (FileSystemEntity.typeSync(free) == FileSystemEntityType.notFound) return free;
    }
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
    _releaseImages();
  }

  /// What to tell someone who needs FFmpeg to export a video, for their platform.
  static String missingFfmpegForVideo() =>
      MediaConverter.missingFfmpegHelp(lead: 'To export video, install FFmpeg (free), then export again:'.tr);

  static String _lastLines(String text) => text.trim().split('\n').reversed.take(4).toList().reversed.join('\n');
}
