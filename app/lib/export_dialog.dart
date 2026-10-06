import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'app_settings.dart';
import 'edit_dialogs.dart';
import 'editor_controller.dart';
import 'editor_toolbar.dart';
import 'error_text.dart';
import 'media_converter.dart';
import 'ui_kit.dart';
import 'video_export.dart';

/// File ▸ Export Video… (⌘E): on the left a still of the video (at the playhead, or any time
/// in the range: a slider scrubs it); on the right the bars to export (the whole piece unless
/// changed), the ratio (the toolbar's), size, frame rate, paper and score size. Then where to
/// save it, and progress until it is written.
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

  @override
  void dispose() {
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

  void _setWhole() => setState(() {
        _from.text = '1';
        _to.text = '${_export.bars}';
      });

  Future<void> _start() async {
    final range = _range;
    if (range == null) return;
    final location = await getSaveLocation(
      acceptedTypeGroups: const [XTypeGroup(label: 'MP4 video', extensions: ['mp4'])],
      suggestedName: '${widget.suggestedName}${_whole ? '' : ' (bars $_first–$_last)'}.mp4',
    );
    if (location == null || !mounted) return;
    final path = await confirmSavePath(context, location.path, 'mp4');
    if (path == null || !mounted) return;
    setState(() {
      _stage = _Stage.writing;
      _output = path;
      _progress = null;
    });
    try {
      await _export.write(path, format: _format, ffmpeg: _ffmpeg, from: range.start, to: range.end, onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (mounted) setState(() => _stage = _Stage.done);
    } on VideoExportCancelled {
      if (mounted) setState(() => _stage = _Stage.setup);
    } catch (e) {
      if (mounted) {
        setState(() {
          _stage = _Stage.failed;
          _error = describeError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final setup = _stage == _Stage.setup;
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: setup ? 840 : 480,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
            child: Text(
              switch (_stage) {
                _Stage.setup => 'Export Video',
                _Stage.writing => 'Exporting Video…',
                _Stage.done => 'Video Exported',
                _Stage.failed => 'The Video Could Not Be Exported',
              },
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: colors.text),
            ),
          ),
          Flexible(
            // A short window scrolls the dialog rather than cutting it off.
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: switch (_stage) {
                _Stage.setup => _setup(context),
                _Stage.writing => _writing(context),
                _Stage.done => _done(context),
                _Stage.failed => SelectableText(_error ?? ''),
              },
            ),
          ),
          if (setup) Divider(height: 1, color: colors.line, indent: 24, endIndent: 24),
          Padding(
            padding: EdgeInsets.fromLTRB(24, setup ? 14 : 20, 20, 18),
            child: Row(children: [
              Expanded(child: setup ? _summary(context) : const SizedBox()),
              const SizedBox(width: 12),
              ...switch (_stage) {
                _Stage.setup => [
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                    const SizedBox(width: 8),
                    FilledButton(onPressed: _ffmpeg == null || _range == null ? null : _start, child: const Text('Export…')),
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
        ]),
      ),
    );
  }

  static const _previewWidth = 420.0;

  Widget _setup(BuildContext context) {
    final colors = context.colors;
    final c = widget.controller;
    final format = _format;
    final range = _range ?? (start: 0.0, end: _export.duration);
    final still = _still.clamp(range.start, range.end);
    final figures = TextStyle(fontSize: 12.5, color: colors.textMuted, fontFeatures: const [FontFeature.tabularFigures()]);
    final segments = ButtonStyle(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 6)),
      textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 13)),
    );
    final firstWrong = _first < 1 || _first > _export.bars, lastWrong = !firstWrong && _range == null;

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: _previewWidth,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // The frame as the video will show it: in a 16:9 box whatever the ratio, so a tall
            // one doesn't stretch the dialog, and the controls stay put.
            Container(
              height: _previewWidth / VideoRatio.widescreen.value,
              decoration: BoxDecoration(color: colors.accentWash, borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.all(8),
              child: Center(
                child: AspectRatio(
                  aspectRatio: format.aspectRatio,
                  child: DecoratedBox(
                    position: DecorationPosition.foreground,
                    decoration: BoxDecoration(border: Border.all(color: colors.line)),
                    child: CustomPaint(
                      painter: _StillPainter(_export, time: still, paper: format.paper,
                          devicePixelRatio: MediaQuery.devicePixelRatioOf(context)),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(children: [
              SizedBox(width: 44, child: Text(_export.barBeatAt(still), style: figures)),
              Expanded(
                child: OverlaySemantics(
                  child: Slider(
                    value: still,
                    min: range.start,
                    max: math.max(range.end, range.start + 1e-3),
                    onChanged: _range == null ? null : (v) => setState(() => _still = v),
                  ),
                ),
              ),
              SizedBox(width: 44, child: Text(_clock(still), style: figures, textAlign: TextAlign.right)),
            ]),
          ]),
        ),
        const SizedBox(width: 28),
        Expanded(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const _Heading('Bars'),
            Row(children: [
              Expanded(
                child: _BarField(
                  label: 'From bar',
                  controller: _from,
                  wrong: firstWrong,
                  onChanged: () => setState(() {
                    if (_range case final r?) _still = r.start; // show where it starts
                  }),
                  onSubmitted: _ffmpeg == null ? null : _start,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text('–', style: TextStyle(color: colors.textMuted)),
              ),
              Expanded(
                child: _BarField(
                  label: 'To bar',
                  controller: _to,
                  wrong: lastWrong,
                  onChanged: () => setState(() {}),
                  onSubmitted: _ffmpeg == null ? null : _start,
                ),
              ),
              const SizedBox(width: 4),
              // Back to the whole piece; its room is kept so the fields don't jump.
              Visibility.maintain(
                visible: !_whole,
                child: ToolbarButton(icon: Icons.restart_alt_rounded, tooltip: 'Whole piece', onPressed: _whole ? null : _setWhole),
              ),
            ]),
            const SizedBox(height: 20),
            const _Heading('Video'),
            _Row(
              label: 'Ratio',
              child: RatioMenu(ratio: _settings.videoRatio, onSelected: (r) => setState(() => _settings.videoRatio = r)),
            ),
            _Row(
              label: 'Size',
              child: SegmentedButton<VideoResolution>(
                style: segments,
                expandedInsets: EdgeInsets.zero,
                showSelectedIcon: false,
                segments: [for (final r in VideoResolution.values) ButtonSegment(value: r, label: Text(r.label))],
                selected: {_settings.videoResolution},
                onSelectionChanged: (s) => setState(() => _settings.videoResolution = s.single),
              ),
            ),
            _Row(
              label: 'Frame rate',
              child: SegmentedButton<int>(
                style: segments,
                expandedInsets: EdgeInsets.zero,
                showSelectedIcon: false,
                segments: [for (final f in VideoFormat.frameRates) ButtonSegment(value: f, label: Text('$f'))],
                selected: {_settings.videoFps},
                onSelectionChanged: (s) => setState(() => _settings.videoFps = s.single),
              ),
            ),
            _Row(
              label: 'Paper',
              child: SegmentedButton<VideoPaper>(
                style: segments,
                expandedInsets: EdgeInsets.zero,
                showSelectedIcon: false,
                segments: [for (final p in VideoPaper.values) ButtonSegment(value: p, label: Text(p.label))],
                selected: {_settings.videoPaper},
                onSelectionChanged: (s) => setState(() => _settings.videoPaper = s.single),
              ),
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
          ]),
        ),
      ]),
      if (_ffmpeg == null) ...[
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: colors.recordingWash, borderRadius: BorderRadius.circular(8)),
          child: SelectableText(VideoExport.missingFfmpegForVideo(), style: TextStyle(fontSize: 12.5, color: colors.text)),
        ),
      ],
      const SizedBox(height: 16),
    ]);
  }

  /// What comes out: its length, shape, pixels, frames and sound.
  Widget _summary(BuildContext context) {
    final colors = context.colors;
    final format = _format, range = _range, track = widget.controller.track;
    final muted = TextStyle(fontSize: 12.5, color: colors.textMuted, fontFeatures: const [FontFeature.tabularFigures()]);
    final length = range == null ? null : range.end - range.start;
    return Row(children: [
      Flexible(
        child: Text(
          [
            length == null ? '–' : _clock(length),
            _settings.videoRatio.label,
            '${format.width} × ${format.height}',
            if (length != null) '${_count(format.frameCount(length))} frames',
          ].join(' · '),
          style: muted,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      const SizedBox(width: 14),
      Icon(track == null ? Icons.volume_off_rounded : Icons.music_note_rounded, size: 15, color: colors.textMuted),
      const SizedBox(width: 4),
      Flexible(child: Text(track?.name ?? 'Silent', style: muted, overflow: TextOverflow.ellipsis)),
    ]);
  }

  Widget _writing(BuildContext context) {
    final p = _progress;
    final left = p?.remaining;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(_basename(_output!)),
      const SizedBox(height: 12),
      ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(value: p?.fraction, minHeight: 6)),
      const SizedBox(height: 8),
      Text(
        p == null
            ? 'Starting…'
            : 'Frame ${_count(p.frame)} of ${_count(p.frames)}${left == null ? '' : ' · about ${_remaining(left)} left'}',
        style: TextStyle(fontSize: 12.5, color: context.colors.textMuted),
      ),
    ]);
  }

  Widget _done(BuildContext context) => Row(children: [
        Icon(Icons.check_circle_rounded, color: context.colors.accent),
        const SizedBox(width: 10),
        Expanded(child: Text('Saved “${_basename(_output!)}”.')),
      ]);

  static String get _revealLabel => Platform.isMacOS
      ? 'Show in Finder'
      : Platform.isWindows
          ? 'Show in Explorer'
          : 'Open Folder';

  static String _basename(String path) => path.split(RegExp(r'[/\\]')).last;

  static String _clock(double seconds) {
    final s = seconds.round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  static String _remaining(Duration d) =>
      d.inSeconds < 60 ? '${d.inSeconds} s' : '${(d.inSeconds / 60).ceil()} min';

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

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          SizedBox(width: 80, child: Text(label, style: TextStyle(fontSize: 13, color: context.colors.textMuted))),
          Expanded(child: Align(alignment: Alignment.centerLeft, child: child)),
        ]),
      );
}

/// A group's name: "Bars", "Video".
class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: context.colors.textMuted)),
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
    final error = Theme.of(context).colorScheme.error;
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: color, width: width));
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(5)],
      style: const TextStyle(fontSize: 14, fontFeatures: [FontFeature.tabularFigures()]),
      onChanged: (_) => onChanged(),
      onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
      onTap: () => controller.selection = TextSelection(baseOffset: 0, extentOffset: controller.text.length),
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        enabledBorder: border(wrong ? error : colors.line),
        focusedBorder: border(wrong ? error : colors.accent, 1.5),
        floatingLabelStyle: WidgetStateTextStyle.resolveWith((states) => TextStyle(
            color: wrong
                ? error
                : states.contains(WidgetState.focused)
                    ? colors.accentStrong
                    : colors.textMuted)),
      ),
    );
  }
}

class _StillPainter extends CustomPainter {
  _StillPainter(this.export, {required this.time, required this.paper, required this.devicePixelRatio});
  final VideoExport export;
  final double time;
  final VideoPaper paper;
  final double devicePixelRatio;

  @override
  void paint(Canvas canvas, Size size) =>
      export.paintPreview(canvas, size, time: time, paper: paper, devicePixelRatio: devicePixelRatio);

  // The score size changes the export's scene in place, so every rebuild repaints.
  @override
  bool shouldRepaint(_StillPainter old) => true;
}
