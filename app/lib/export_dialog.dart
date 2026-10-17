import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'app_settings.dart';
import 'dialog_kit.dart';
import 'edit_dialogs.dart';
import 'editor_controller.dart';
import 'error_text.dart';
import 'file_names.dart';
import 'media_converter.dart';
import 'menu_kit.dart';
import 'ui_kit.dart';
import 'video_export.dart';

/// File ▸ Export Video… (⌘E). A large still of the video on the left, the piece under it as a
/// trimmer (the bars to export, their handles dragged or typed, and the still's time, dragged to
/// scrub); on the right a sidebar: Video (format, size, frame rate: what the file is) and Picture
/// (ratio, paper, transparent, score size: what it shows). The footer says what comes out and
/// exports; while it writes, the still follows the frames written and the footer shows progress.
/// [suggestedName] is the file name offered (without extension).
Future<void> showExportDialog(BuildContext context, EditorController controller, AppSettings settings,
    {required String suggestedName}) {
  controller.playback.pause();
  return showAppDialog<void>(
    context: context,
    barrierDismissible: false, // closing mid-export would lose it: Cancel says so
    builder: (context) => _ExportDialog(controller: controller, settings: settings, suggestedName: suggestedName),
  );
}

enum _Stage { setup, writing, done, failed }

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({required this.controller, required this.settings, required this.suggestedName});
  final EditorController controller;
  final AppSettings settings;
  final String suggestedName;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  late final _export = VideoExport.of(widget.controller);
  final _ffmpeg = MediaConverter.findFfmpeg();
  AppSettings get _settings => widget.settings;

  // The bars to export: the whole piece until changed.
  late final _from = TextEditingController(text: '1');
  late final _to = TextEditingController(text: '${_export.bars}');

  /// The time the still shows, kept inside the range.
  late double _still = widget.controller.playback.time.value;

  var _stage = _Stage.setup;
  ExportProgress? _progress;
  String? _output, _error;

  /// The encoders this FFmpeg has; null until it has said (every format offered meanwhile).
  Set<String>? _encoders;

  /// The frame last drawn while the video is written: the still shows it, drawing nothing again.
  ui.Image? _written;

  void _showWritten(ui.Image? frame) {
    _written?.dispose();
    _written = frame;
  }

  @override
  void initState() {
    super.initState();
    if (_ffmpeg case final ffmpeg?) {
      VideoEncoder.probeAll(ffmpeg).then((e) {
        if (mounted && e.isNotEmpty) setState(() => _encoders = e);
      }, onError: (Object _) {}); // can't say: the export says so if it can't
    }
  }

  @override
  void dispose() {
    _showWritten(null);
    _export.dispose();
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  VideoFormat get _format => _settings.videoFormat;

  int get _first => int.tryParse(_from.text) ?? 0;
  int get _last => int.tryParse(_to.text) ?? 0;

  /// The seconds the bars typed cover; null while they aren't a range.
  ({double start, double end})? get _range => _export.barRange(_first, _last);

  bool get _whole => _first == 1 && _last == _export.bars;

  /// Whether this FFmpeg can write [codec] (yes until it has said).
  bool _canWrite(VideoCodec codec) => _encoders?.intersection(codec.encoders.toSet()).isNotEmpty ?? true;

  /// Whether the video as chosen can be written.
  bool get _writable => _ffmpeg != null && _range != null && _canWrite(_format.codec);

  void _setWhole() => _setBars(1, _export.bars);

  /// Bars [first]…[last], from the trimmer or the ↺: typed into the fields, and the still kept
  /// inside them.
  void _setBars(int first, int last, {bool showStart = false}) => setState(() {
        _from.text = '$first';
        _to.text = '$last';
        if (_export.showBars(first, last) && showStart) _still = _export.span.start;
      });

  bool get _defaultVideo =>
      _settings.videoCodec == AppSettings.defaultVideoCodec &&
      _settings.videoResolution == AppSettings.defaultVideoResolution &&
      _settings.videoFps == AppSettings.defaultVideoFps;

  void _setDefaultVideo() => setState(() => _settings
    ..videoCodec = AppSettings.defaultVideoCodec
    ..videoResolution = AppSettings.defaultVideoResolution
    ..videoFps = AppSettings.defaultVideoFps);

  /// The bars typed changed: the still shows them as the video will.
  void _barsChanged({bool start = false}) => setState(() {
        if (_export.showBars(_first, _last) && start) _still = _export.span.start; // show where it starts
      });

  Future<void> _start() async {
    if (!_writable) return;
    final codec = _format.codec, name = '${widget.suggestedName}${_whole ? '' : ' (bars $_first–$_last)'}';
    final location = await getSaveLocation(
      acceptedTypeGroups: [if (!codec.isSequence) XTypeGroup(label: codec.typeLabel, extensions: [codec.extension])],
      suggestedName: codec.isSequence ? name : '$name.${codec.extension}',
    );
    if (location == null || !mounted) return;
    // A sequence is a folder: the panel has asked about one of that name, and the export
    // replaces only an earlier export's frames.
    final path = codec.isSequence ? location.path : await confirmSavePath(context, location.path, codec.extension);
    if (path == null || !mounted) return;
    final format = _format, start = _export.span.start;
    setState(() {
      _stage = _Stage.writing;
      _output = path;
      _progress = null;
    });
    try {
      final written = await _export.write(path,
          format: format,
          ffmpeg: _ffmpeg,
          // The still follows the frames written.
          onFrame: (frame) => mounted ? _showWritten(frame) : frame.dispose(),
          onProgress: (p) {
            if (mounted) setState(() => (_progress = p, _still = start + format.timeOf(p.frame - 1)));
          });
      if (mounted) setState(() => (_stage = _Stage.done, _output = written));
    } on VideoExportCancelled {
      if (mounted) setState(() => _stage = _Stage.setup);
    } catch (e) {
      if (mounted) {
        setState(() {
          _stage = _Stage.failed;
          _error = describeError(e);
        });
      }
    } finally {
      if (mounted) setState(() => _showWritten(null));
    }
  }

  static const _sidebarWidth = 340.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final setup = _stage == _Stage.setup;
    final screen = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(32),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: math.min(1080, screen.width - 64),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _header(context),
          Divider(height: 1, color: colors.line),
          Flexible(
            // As tall as its content (a short window scrolls it), the sidebar's tone behind its
            // column all the way down.
            child: SingleChildScrollView(
              child: Stack(children: [
                Positioned(
                  top: 0,
                  bottom: 0,
                  right: 0,
                  width: _sidebarWidth + 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: colors.chrome, border: Border(left: BorderSide(color: colors.line))),
                  ),
                ),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: Padding(padding: const EdgeInsets.all(24), child: _stageArea(context))),
                  const SizedBox(width: 1),
                  SizedBox(
                    width: _sidebarWidth,
                    // Nothing changes while the video is written, or once it is.
                    child: IgnorePointer(
                      ignoring: !setup,
                      child: AnimatedOpacity(
                        opacity: setup ? 1 : 0.5,
                        duration: motion(context, 200),
                        alwaysIncludeSemantics: true,
                        child: Padding(padding: const EdgeInsets.fromLTRB(20, 18, 20, 20), child: _sidebar(context)),
                      ),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
          Divider(height: 1, color: colors.line),
          _footer(context),
        ]),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final colors = context.colors;
    return Container(
      height: 56,
      padding: const EdgeInsets.only(left: 24, right: 12),
      child: Row(children: [
        Expanded(
          child: Text(
            switch (_stage) {
              _Stage.setup => 'Export Video',
              _Stage.writing => 'Exporting Video…',
              _Stage.done => 'Video Exported',
              _Stage.failed => 'Couldn’t Export Video',
            },
            style: isRefined(context)
                ? Theme.of(context).dialogTheme.titleTextStyle
                : TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: colors.text),
          ),
        ),
        ToolbarButton(
          icon: Icons.close_rounded,
          tooltip: 'Close',
          onPressed: _stage == _Stage.writing ? null : () => Navigator.pop(context),
        ),
      ]),
    );
  }

  /// The still, the trimmer under it, and the bars typed.
  Widget _stageArea(BuildContext context) {
    final colors = context.colors;
    final format = _format;
    final range = _export.span; // the bars last shown, while those typed aren't a range
    final still = _still.clamp(range.start, range.end);
    final setup = _stage == _Stage.setup;
    final figures = TextStyle(fontSize: 13, color: colors.textMuted, fontFeatures: const [FontFeature.tabularFigures()]);
    final firstWrong = _first < 1 || _first > _export.bars, lastWrong = !firstWrong && _range == null;

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // The frame as the video will show it, in a 16:9 stage whatever the ratio, so a tall one
      // doesn't stretch the dialog and the controls stay put.
      AspectRatio(
        aspectRatio: VideoRatio.widescreen.value,
        child: Container(
          decoration: BoxDecoration(color: colors.accentWash, borderRadius: BorderRadius.circular(10)),
          padding: const EdgeInsets.all(12),
          child: Center(
            child: AspectRatio(
              aspectRatio: format.aspectRatio,
              child: DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(border: Border.all(color: colors.line)),
                child: CustomPaint(
                  // A see-through frame on a checkerboard, toned like its paper so the ink shows.
                  painter: format.hasAlpha ? _Checkerboard(format.paper) : null,
                  foregroundPainter: _StillPainter(_export,
                      frame: _written,
                      time: still,
                      paper: format.paper,
                      transparent: format.hasAlpha,
                      devicePixelRatio: MediaQuery.devicePixelRatioOf(context)),
                ),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 16),
      _Trimmer(
        duration: _export.duration,
        barStarts: _export.barStarts,
        first: _range == null ? null : _first,
        last: _range == null ? null : _last,
        musicEnd: _export.musicEnd,
        span: range,
        still: still,
        onStill: setup && _range != null ? (t) => setState(() => _still = t) : null,
        onBars: setup ? (first, last, {required bool start}) => _setBars(first, last, showStart: start) : null,
      ),
      const SizedBox(height: 6),
      Row(children: [
        Text(_export.barBeatAt(still), style: figures),
        const Spacer(),
        Text(_clock(still), style: figures),
      ]),
      const SizedBox(height: 14),
      IgnorePointer(
        ignoring: !setup,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          SizedBox(
            width: 96,
            child: _BarField(
              label: 'From bar',
              controller: _from,
              wrong: firstWrong,
              onChanged: () => _barsChanged(start: true),
              onSubmitted: _start,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 9),
            child: Text('–', style: TextStyle(color: colors.textMuted)),
          ),
          SizedBox(
            width: 96,
            child: _BarField(label: 'To bar', controller: _to, wrong: lastWrong, onChanged: _barsChanged, onSubmitted: _start),
          ),
          const SizedBox(width: 6),
          // Back to the whole piece; its room is kept so nothing jumps.
          Visibility.maintain(
            visible: !_whole,
            child: ToolbarButton(icon: Icons.restart_alt_rounded, tooltip: 'Whole piece', onPressed: _whole ? null : _setWhole),
          ),
        ]),
      ),
      if (_ffmpeg == null) ...[
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: colors.recordingWash, borderRadius: BorderRadius.circular(8)),
          child: SelectableText(VideoExport.missingFfmpegForVideo(), style: TextStyle(fontSize: 13, color: colors.text)),
        ),
      ],
    ]);
  }

  /// Video: what the file is; Picture: what it shows.
  Widget _sidebar(BuildContext context) {
    final c = widget.controller;
    final format = _format;
    final ratio = _settings.videoRatio;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Heading(
        'Video',
        // Back to an MP4, 1080p at 30; its room is kept so the rows don't move.
        trailing: Visibility.maintain(
          visible: !_defaultVideo,
          child: ToolbarButton(
            icon: Icons.restart_alt_rounded,
            tooltip: 'MP4 · 1080p · 30 fps',
            onPressed: _defaultVideo ? null : _setDefaultVideo,
          ),
        ),
      ),
      _Row(
        label: 'Format',
        child: _Select<VideoCodec>(
          value: format.codec,
          bad: !_canWrite(format.codec),
          items: [for (final c in VideoCodec.values) (c, c.label, _canWrite(c))],
          onChanged: (c) => setState(() => _settings.videoCodec = c),
        ),
      ),
      _Row(
        label: 'Size',
        child: _Select<VideoResolution>(
          value: _settings.videoResolution,
          items: [for (final r in VideoResolution.values) (r, r.label, true)],
          onChanged: (r) => setState(() => _settings.videoResolution = r),
        ),
      ),
      _Row(
        label: 'Frame rate',
        child: _FrameRate(fps: _settings.videoFps, onChanged: (f) => setState(() => _settings.videoFps = f)),
      ),
      SizedBox(height: dialogGap(context) + 8),
      const _Heading('Picture'),
      _Row(
        label: 'Ratio',
        // A typed ratio is listed after the presets, checked, Custom… under it.
        child: _Select<VideoRatio>(
          value: ratio,
          items: [
            for (final r in VideoRatio.presets) (r, r.label, true),
            if (!VideoRatio.presets.contains(ratio)) (ratio, ratio.label, true),
            (_customRatio, 'Custom…', true),
          ],
          onChanged: (r) async {
            if (r != _customRatio) return setState(() => _settings.videoRatio = r);
            final typed = await showVideoRatioDialog(context, ratio);
            if (typed != null && mounted) setState(() => _settings.videoRatio = typed);
          },
        ),
      ),
      _Row(
        label: 'Paper',
        child: AppSegmented<VideoPaper>(
          style: _segments,
          expand: true,
          segments: [for (final p in VideoPaper.values) ButtonSegment(value: p, label: Text(p.label))],
          selected: _settings.videoPaper,
          onChanged: (p) => setState(() => _settings.videoPaper = p),
        ),
      ),
      _Row(
        label: 'Transparent',
        tip: format.codec.alpha ? null : 'Not supported in MP4',
        child: format.codec.alpha
            ? AppSwitch(value: format.hasAlpha, onChanged: (v) => setState(() => _settings.videoTransparent = v))
            : const AppSwitch(value: false, onChanged: null),
      ),
      _Row(
        label: 'Score size',
        // The project's score size (the toolbar's slider): the video frames it like the editor.
        child: OverlaySemantics(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(overlayShape: const RoundSliderOverlayShape(overlayRadius: 14)),
            child: Slider(
              value: c.staffSpace,
              min: EditorController.minStaffSpace,
              max: EditorController.maxStaffSpace,
              divisions: 14,
              label: c.staffSpace.toStringAsFixed(1),
              onChanged: (v) => setState(() {
                c.setStaffSpace(v, dragging: true);
                _export.staffSpace = c.staffSpace;
              }),
              onChangeEnd: c.setStaffSpace,
            ),
          ),
        ),
      ),
    ]);
  }

  /// Custom…'s value in the ratio select.
  static const _customRatio = VideoRatio(0, 1);

  static const _segments = ButtonStyle(
    visualDensity: VisualDensity.compact,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 6)),
    textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 13)),
  );

  /// What comes out, or how it is going, and the buttons for the stage.
  Widget _footer(BuildContext context) {
    final refined = isRefined(context);
    return DialogButtons(
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, 14, refined ? 24 : 20, refined ? 16 : 14),
        child: SizedBox(
          height: 36,
          child: Row(children: [
            Expanded(
              child: switch (_stage) {
                _Stage.setup => _summary(context),
                _Stage.writing => _writing(context),
                _Stage.done => _done(context),
                _Stage.failed => _failed(context),
              },
            ),
            const SizedBox(width: 16),
            ...switch (_stage) {
              _Stage.setup => [
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _writable ? _start : null, child: const Text('Export…')),
                ],
              _Stage.writing => [TextButton(onPressed: _export.cancel, child: const Text('Cancel'))],
              _Stage.done => [
                  TextButton(onPressed: () => revealInFileManager(_output!), child: Text(_revealLabel)),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
                ],
              _Stage.failed => [
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: () => setState(() => _stage = _Stage.setup), child: const Text('Back')),
                ],
            },
          ]),
        ),
      ),
    );
  }

  TextStyle _muted(BuildContext context) =>
      TextStyle(fontSize: 13, color: context.colors.textMuted, fontFeatures: const [FontFeature.tabularFigures()]);

  /// Its length, shape, pixels, frames and sound.
  Widget _summary(BuildContext context) {
    final colors = context.colors;
    final format = _format, range = _range;
    final sound = format.codec.hasSound ? widget.controller.track : null; // a sequence's frames have none
    final muted = _muted(context);
    final length = range == null ? null : range.end - range.start;
    return Row(children: [
      Flexible(
        child: Text(
          [
            length == null ? '–' : _clock(length),
            _settings.videoRatio.label,
            '${format.width} × ${format.height}',
            '${VideoFormat.rateLabel(format.fps)} fps',
            if (length != null) '${_count(format.frameCount(length))} frames',
          ].join(' · '),
          style: muted,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      const SizedBox(width: 14),
      Icon(sound == null ? Icons.volume_off_rounded : Icons.music_note_rounded, size: 15, color: colors.textMuted),
      const SizedBox(width: 4),
      Flexible(child: Text(sound?.name ?? 'Silent', style: muted, overflow: TextOverflow.ellipsis)),
    ]);
  }

  Widget _writing(BuildContext context) {
    final p = _progress;
    final left = p?.remaining;
    return Row(children: [
      SizedBox(
        width: 220,
        child: ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(value: p?.fraction, minHeight: 6)),
      ),
      const SizedBox(width: 14),
      Flexible(
        child: Text(
          p == null
              ? 'Starting…'
              : 'Frame ${_count(p.frame)} of ${_count(p.frames)}${left == null ? '' : ' · about ${_remaining(left)} left'}',
          style: _muted(context),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ]);
  }

  Widget _done(BuildContext context) => Row(children: [
        Icon(Icons.check_circle_rounded, size: 18, color: context.colors.accent),
        const SizedBox(width: 8),
        Flexible(child: Text('Saved “${fileNameOf(_output!)}”.', overflow: TextOverflow.ellipsis)),
      ]);

  Widget _failed(BuildContext context) => Row(children: [
        Icon(Icons.error_outline_rounded, size: 18, color: Theme.of(context).colorScheme.error),
        const SizedBox(width: 8),
        // FFmpeg's last lines can be long: the whole of it is there to copy, in a tooltip too.
        Flexible(
          child: Tip(
            message: _error ?? '',
            child: SelectableText(_error ?? '', maxLines: 2, style: const TextStyle(fontSize: 13)),
          ),
        ),
      ]);

  static String get _revealLabel => Platform.isMacOS
      ? 'Show in Finder'
      : Platform.isWindows
          ? 'Show in Explorer'
          : 'Open Folder';

  static String _clock(double seconds) {
    final s = seconds.round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  static String _remaining(Duration d) =>
      d.inSeconds < 60 ? '${d.inSeconds} seconds' : '${(d.inSeconds / 60).ceil()} minutes';

  static String _count(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+$)'), (_) => ',');
}

/// Shows [path] in the platform's file manager (selected where it can be).
Future<void> revealInFileManager(String path) async {
  try {
    if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
    } else if (Platform.isWindows) {
      await Process.run('explorer.exe', ['/select,', path]);
    } else {
      await Process.run('xdg-open', [File(path).parent.path]);
    }
  } on ProcessException {
    // no file manager to show it in: the dialog has already said where it is
  }
}

/// The piece from start to end, and on it: a tick at each bar, the bars to export (their music
/// solid, the settle and fade after it fainter) with a handle at each end, and the still's time.
/// Dragging a handle picks the bar nearest (`onBars`; the first handle shows where it starts),
/// dragging anywhere else moves the still, kept inside the bars ([onStill]). Null callbacks: it
/// only shows them.
class _Trimmer extends StatefulWidget {
  const _Trimmer({
    required this.duration,
    required this.barStarts,
    required this.first,
    required this.last,
    required this.musicEnd,
    required this.span,
    required this.still,
    required this.onStill,
    required this.onBars,
  });
  final double duration;
  final List<double> barStarts;

  /// The bars shown; null while those typed aren't a range (the [span] stays the last one).
  final int? first, last;
  final double musicEnd;
  final ({double start, double end}) span;
  final double still;
  final ValueChanged<double>? onStill;
  final void Function(int first, int last, {required bool start})? onBars;

  static const height = 44.0, _handle = 10.0;

  @override
  State<_Trimmer> createState() => _TrimmerState();
}

enum _Grip { first, last, still }

class _TrimmerState extends State<_Trimmer> {
  _Grip? _grip;
  _Grip? _hover;

  double _x(double t, double width) => widget.duration <= 0 ? 0 : (t / widget.duration).clamp(0.0, 1.0) * width;
  double _t(double x, double width) => width <= 0 ? 0 : (x / width).clamp(0.0, 1.0) * widget.duration;

  /// The bar whose start is nearest [t] (from 1).
  int _barAt(double t) {
    final starts = widget.barStarts;
    var best = 0;
    for (var i = 1; i < starts.length; i++) {
      if ((starts[i] - t).abs() < (starts[best] - t).abs()) best = i;
    }
    return best + 1;
  }

  /// What a press at [x] takes: a handle within reach, else the still.
  _Grip _gripAt(double x, double width) {
    final w = widget;
    if (w.onBars != null && w.first != null) {
      final a = _x(w.span.start, width), b = _x(w.musicEnd, width);
      if ((x - a).abs() <= _Trimmer._handle && (x - a).abs() <= (x - b).abs()) return _Grip.first;
      if ((x - b).abs() <= _Trimmer._handle) return _Grip.last;
    }
    return _Grip.still;
  }

  void _drag(double x, double width) {
    final w = widget, t = _t(x, width);
    switch (_grip) {
      case _Grip.first when w.first != null:
        final first = math.min(_barAt(t), w.last!);
        if (first != w.first) w.onBars?.call(first, w.last!, start: true);
      case _Grip.last when w.last != null:
        // The bar ending nearest: the one before the bar starting there.
        final last = (_barAt(t) - 1).clamp(w.first!, w.barStarts.length);
        final end = t >= w.barStarts.last + (w.duration - w.barStarts.last) / 2 ? w.barStarts.length : last;
        if (end != w.last) w.onBars?.call(w.first!, end, start: false);
      case _Grip.still:
        w.onStill?.call(t.clamp(w.span.start, w.span.end));
      default:
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final w = widget;
    final active = w.onStill != null || w.onBars != null;
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      return MouseRegion(
        cursor: !active
            ? MouseCursor.defer
            : switch (_grip ?? _hover) {
                _Grip.first || _Grip.last => SystemMouseCursors.resizeLeftRight,
                _ => SystemMouseCursors.basic,
              },
        onHover: active ? (e) => setState(() => _hover = _gripAt(e.localPosition.dx, width)) : null,
        onExit: (_) => setState(() => _hover = null),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // What is gripped is where the press went down, not where it had moved enough to drag.
          dragStartBehavior: DragStartBehavior.down,
          onHorizontalDragStart: active
              ? (d) {
                  _grip = _gripAt(d.localPosition.dx, width);
                  _drag(d.localPosition.dx, width);
                }
              : null,
          onHorizontalDragUpdate: active ? (d) => _drag(d.localPosition.dx, width) : null,
          onHorizontalDragEnd: active ? (_) => setState(() => _grip = null) : null,
          onTapDown: active
              ? (d) {
                  _grip = _Grip.still;
                  _drag(d.localPosition.dx, width);
                  _grip = null;
                }
              : null,
          child: Semantics(
            label: 'Bars and still',
            value: w.first == null ? null : 'Bars ${w.first} to ${w.last}',
            child: SizedBox(
              height: _Trimmer.height,
              width: width,
              child: CustomPaint(
                painter: _TrimmerPainter(
                  x: (t) => _x(t, width),
                  barStarts: w.barStarts,
                  start: w.span.start,
                  musicEnd: w.musicEnd,
                  end: w.span.end,
                  still: w.still,
                  valid: w.first != null,
                  hot: _grip ?? _hover,
                  colors: colors,
                  error: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _TrimmerPainter extends CustomPainter {
  _TrimmerPainter({
    required this.x,
    required this.barStarts,
    required this.start,
    required this.musicEnd,
    required this.end,
    required this.still,
    required this.valid,
    required this.hot,
    required this.colors,
    required this.error,
  });
  final double Function(double t) x;
  final List<double> barStarts;
  final double start, musicEnd, end, still;
  final bool valid;
  final _Grip? hot;
  final AppColors colors;
  final Color error;

  @override
  void paint(Canvas canvas, Size size) {
    const track = 8.0, r = Radius.circular(6);
    final h = size.height, top = track, bottom = h - track;
    // The whole piece.
    canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTRB(0, top, size.width, bottom), r), Paint()..color = colors.line.withValues(alpha: 0.5));
    // A tick a bar, where there's room for them.
    if (barStarts.length > 1 && x(barStarts.last) / barStarts.length >= 4) {
      final tick = Paint()
        ..color = colors.textMuted.withValues(alpha: 0.35)
        ..strokeWidth = 1;
      for (final (i, t) in barStarts.indexed) {
        final px = x(t).roundToDouble() + 0.5;
        final long = i % 4 == 0;
        canvas.drawLine(Offset(px, long ? bottom - 12 : bottom - 6), Offset(px, bottom - 1), tick);
      }
    }
    // The bars: their music solid, the ending (settle and fade) fainter.
    final accent = valid ? colors.accent : error;
    final a = x(start), m = x(musicEnd), b = x(end);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(a, top, b, bottom), r), Paint()..color = accent.withValues(alpha: 0.10));
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(a, top, m, bottom), r), Paint()..color = accent.withValues(alpha: 0.22));
    canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTRB(a, top, m, bottom), r),
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
    // The handles: a grip at each end of the music.
    for (final (px, grip) in [(a, _Grip.first), (m, _Grip.last)]) {
      final handle = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(px, h / 2), width: hot == grip ? 8 : 6, height: h - track), r);
      canvas.drawRRect(handle, Paint()..color = accent);
      canvas.drawLine(Offset(px, h / 2 - 5), Offset(px, h / 2 + 5),
          Paint()
            ..color = Colors.white.withValues(alpha: 0.9)
            ..strokeWidth = 1);
    }
    // The still's time: a line through the track, a knob on top.
    final s = x(still);
    final ink = Paint()..color = colors.text;
    canvas.drawRect(Rect.fromLTWH(s - 1, 2, 2, h - 4), ink);
    canvas.drawCircle(Offset(s, 4), hot == _Grip.still ? 5 : 4, ink);
  }

  // [x] follows the width, which a closure can't be compared by.
  @override
  bool shouldRepaint(_TrimmerPainter old) => true;
}

/// A select in the sidebar, the dialog's 36 px, filling its row: [items] are a value, its name
/// and whether it can be chosen; red when [bad].
class _Select<T> extends StatelessWidget {
  const _Select({required this.value, required this.items, required this.onChanged, this.bad = false});
  final T value;
  final List<(T, String, bool)> items;
  final ValueChanged<T> onChanged;
  final bool bad;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final error = Theme.of(context).colorScheme.error;
    return AppDropdown<T>(
      value: value,
      boxed: true,
      isExpanded: true,
      style: TextStyle(fontSize: 14, color: bad ? error : colors.text),
      onChanged: (v) => v == null ? null : onChanged(v),
      items: [
        for (final (v, name, enabled) in items)
          DropdownMenuItem<T>(value: v, enabled: enabled, child: Text(name, overflow: TextOverflow.ellipsis)),
      ],
    );
  }
}

/// The frame rate: a select of [VideoFormat.frameRates] and Custom…, which turns it into a field
/// for any rate ([VideoFormat.parseRate]); Return or leaving the field sets it, a rate it can't
/// read goes back to the one before.
class _FrameRate extends StatefulWidget {
  const _FrameRate({required this.fps, required this.onChanged});
  final double fps;
  final ValueChanged<double> onChanged;

  @override
  State<_FrameRate> createState() => _FrameRateState();
}

class _FrameRateState extends State<_FrameRate> {
  static const _custom = -1.0;
  final _text = TextEditingController();
  final _focus = FocusNode();
  bool _typing = false, _bad = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _typing) _commit();
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _type() {
    _text.text = VideoFormat.rateLabel(widget.fps);
    _text.selection = TextSelection(baseOffset: 0, extentOffset: _text.text.length);
    setState(() => (_typing = true, _bad = false));
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  void _commit() {
    final fps = VideoFormat.parseRate(_text.text);
    if (fps != null) widget.onChanged(fps);
    setState(() => (_typing = false, _bad = false));
  }

  @override
  Widget build(BuildContext context) {
    if (_typing) {
      return CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => setState(() => _typing = false)},
        child: AppTextField(
          label: '',
          controller: _text,
          focusNode: _focus,
          bad: _bad,
          hint: '23.976',
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,/ ]')), LengthLimitingTextInputFormatter(12)],
          onChanged: (t) => setState(() => _bad = t.isNotEmpty && VideoFormat.parseRate(t) == null),
          onSubmitted: (_) => _bad ? null : _commit(),
        ),
      );
    }
    final fps = widget.fps;
    // A typed rate is listed after the presets, checked, Custom… under it.
    return _Select<double>(
      value: fps,
      items: [
        for (final f in VideoFormat.frameRates) (f, VideoFormat.rateLabel(f), true),
        if (!VideoFormat.frameRates.contains(fps)) (fps, VideoFormat.rateLabel(fps), true),
        (_custom, 'Custom…', true),
      ],
      onChanged: (f) => f == _custom ? _type() : widget.onChanged(f),
    );
  }
}

/// A sidebar row: its [label] at the left, [child] filling the rest.
class _Row extends StatelessWidget {
  const _Row({required this.label, this.tip, required this.child});
  final String label;

  /// Why the row can't be used: shown on hovering anywhere along it, label too.
  final String? tip;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    Widget row = Row(children: [
      SizedBox(width: 96, child: Text(label, style: TextStyle(fontSize: 14, color: context.colors.textMuted))),
      Expanded(child: Align(alignment: Alignment.centerLeft, child: child)),
    ]);
    // A clear box: the gaps between label and control are hit too.
    if (tip case final tip?) row = Tip(message: tip, child: ColoredBox(color: Colors.transparent, child: row));
    return Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: SizedBox(height: 36, child: row));
  }
}

/// A group's name: "Video", "Picture"; [trailing] at its far end.
class _Heading extends StatelessWidget {
  const _Heading(this.text, {this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: SizedBox(
          height: 24,
          child: Row(children: [
            Expanded(
              child: Text(text,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: context.colors.textMuted)),
            ),
            // A button keeps its 32 points, overhanging the heading's line rather than pushing the rows down.
            if (trailing case final t?) SizedBox(width: 32, child: OverflowBox(maxHeight: 32, child: t)),
          ]),
        ),
      );
}

/// A bar number, typed; red while it isn't one the range can take.
class _BarField extends StatelessWidget {
  const _BarField({
    required this.label,
    required this.controller,
    required this.wrong,
    required this.onChanged,
    required this.onSubmitted,
  });
  final String label;
  final TextEditingController controller;
  final bool wrong;
  final VoidCallback onChanged;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final formatters = [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(5)];
    void selectAll() => controller.selection = TextSelection(baseOffset: 0, extentOffset: controller.text.length);
    if (isRefined(context)) {
      return AppTextField(
        label: label,
        controller: controller,
        bad: wrong,
        keyboardType: TextInputType.number,
        inputFormatters: formatters,
        onChanged: (_) => onChanged(),
        onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
        onTap: selectAll,
      );
    }
    final error = Theme.of(context).colorScheme.error;
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: color, width: width));
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: formatters,
      style: const TextStyle(fontSize: 14, fontFeatures: [FontFeature.tabularFigures()]),
      onChanged: (_) => onChanged(),
      onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
      onTap: selectAll,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        enabledBorder: border(wrong ? error : colors.line),
        focusedBorder: border(wrong ? error : colors.accent, 1.5),
      ),
    );
  }
}

/// The still: the frame at [time], or, while the video is written, the [frame] last drawn for it.
class _StillPainter extends CustomPainter {
  _StillPainter(this.export,
      {this.frame, required this.time, required this.paper, required this.transparent, required this.devicePixelRatio});
  final VideoExport export;
  final ui.Image? frame;
  final double time;
  final VideoPaper paper;
  final bool transparent;
  final double devicePixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    if (frame case final frame?) {
      final source = Offset.zero & Size(frame.width.toDouble(), frame.height.toDouble());
      canvas.drawImageRect(frame, source, Offset.zero & size, Paint()..filterQuality = FilterQuality.medium);
      return;
    }
    export.paintPreview(canvas, size,
        time: time, paper: paper, transparent: transparent, devicePixelRatio: devicePixelRatio);
  }

  // The score size changes the export's scene in place, so every rebuild repaints.
  @override
  bool shouldRepaint(_StillPainter old) => true;
}

/// The usual sign of "nothing here": squares in the [paper]'s colour and a shade off it.
class _Checkerboard extends CustomPainter {
  _Checkerboard(this.paper);
  final VideoPaper paper;

  static const _square = 8.0;

  @override
  void paint(Canvas canvas, Size size) {
    final base = paper.paper;
    final shade = Color.lerp(base, paper.ink, 0.1)!;
    canvas
      ..clipRect(Offset.zero & size)
      ..drawColor(base, BlendMode.src);
    final square = Paint()..color = shade;
    for (var y = 0; y * _square < size.height; y++) {
      for (var x = y.isOdd ? 1 : 0; x * _square < size.width; x += 2) {
        canvas.drawRect(Rect.fromLTWH(x * _square, y * _square, _square, _square), square);
      }
    }
  }

  @override
  bool shouldRepaint(_Checkerboard old) => old.paper != paper;
}
