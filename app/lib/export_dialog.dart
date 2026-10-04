import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_settings.dart';
import 'edit_dialogs.dart';
import 'editor_controller.dart';
import 'error_text.dart';
import 'media_converter.dart';
import 'ui_kit.dart';
import 'video_export.dart';

/// File ▸ Export Video… (⌘E): a still of the video at the playhead (at the ratio chosen in
/// the toolbar), its size, frame rate, paper and score size; then where to save it, and
/// progress until it is written.
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

  var _stage = _Stage.setup;
  ExportProgress? _progress;
  String? _output, _error;

  @override
  void dispose() {
    _export.dispose();
    super.dispose();
  }

  VideoFormat get _format => _settings.videoFormat;

  Future<void> _start() async {
    final location = await getSaveLocation(
      acceptedTypeGroups: const [XTypeGroup(label: 'MP4 video', extensions: ['mp4'])],
      suggestedName: '${widget.suggestedName}.mp4',
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
      await _export.write(path, format: _format, ffmpeg: _ffmpeg, onProgress: (p) {
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
    return AlertDialog(
      scrollable: true, // a short window scrolls the dialog rather than cutting it off
      title: Text(switch (_stage) {
        _Stage.setup => 'Export Video',
        _Stage.writing => 'Exporting Video…',
        _Stage.done => 'Video Exported',
        _Stage.failed => 'The Video Could Not Be Exported',
      }),
      content: SizedBox(
        width: 520,
        child: AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: switch (_stage) {
            _Stage.setup => _setup(context),
            _Stage.writing => _writing(context),
            _Stage.done => _done(context),
            _Stage.failed => SingleChildScrollView(child: SelectableText(_error ?? '')),
          },
        ),
      ),
      actions: switch (_stage) {
        _Stage.setup => [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: _ffmpeg == null ? null : _start, child: const Text('Export…')),
          ],
        _Stage.writing => [TextButton(onPressed: _export.cancel, child: const Text('Cancel'))],
        _Stage.done => [
            TextButton(onPressed: () => revealInFileManager(_output!), child: Text(_revealLabel)),
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
          ],
        _Stage.failed => [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
            FilledButton(onPressed: () => setState(() => _stage = _Stage.setup), child: const Text('Back')),
          ],
      },
    );
  }

  Widget _setup(BuildContext context) {
    final colors = context.colors;
    final c = widget.controller;
    final format = _format;
    final track = c.track;
    final muted = TextStyle(fontSize: 12.5, color: colors.textMuted);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // The frame at the playhead, as the video will show it: in a 16:9 box whatever the
      // ratio, so a tall one doesn't stretch the dialog, and the controls stay put.
      SizedBox(
        height: 520 / VideoRatio.widescreen.value,
        child: Center(
          child: AspectRatio(
            aspectRatio: format.aspectRatio,
            child: DecoratedBox(
              decoration: BoxDecoration(border: Border.all(color: colors.line)),
              child: CustomPaint(
                painter: _StillPainter(_export, time: c.playback.time.value, paper: format.paper,
                    devicePixelRatio: MediaQuery.devicePixelRatioOf(context)),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 4),
      Text('At the playhead (${_clock(c.playback.time.value)})', style: muted, textAlign: TextAlign.center),
      const SizedBox(height: 14),
      _Row(
        label: 'Size',
        child: SegmentedButton<VideoResolution>(
          showSelectedIcon: false,
          segments: [for (final r in VideoResolution.values) ButtonSegment(value: r, label: Text(r.label))],
          selected: {_settings.videoResolution},
          onSelectionChanged: (s) => setState(() => _settings.videoResolution = s.single),
        ),
      ),
      _Row(
        label: 'Frame rate',
        child: SegmentedButton<int>(
          showSelectedIcon: false,
          segments: [for (final f in VideoFormat.frameRates) ButtonSegment(value: f, label: Text('$f'))],
          selected: {_settings.videoFps},
          onSelectionChanged: (s) => setState(() => _settings.videoFps = s.single),
        ),
      ),
      _Row(
        label: 'Paper',
        child: SegmentedButton<VideoPaper>(
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
      const SizedBox(height: 6),
      Text(
        '${_clock(_export.duration)} · ${_settings.videoRatio.label} · ${format.width} × ${format.height} · '
        '${_count(format.frameCount(_export.duration))} frames · MP4 (H.264, AAC): plays anywhere',
        style: muted,
      ),
      const SizedBox(height: 2),
      Text(track == null ? 'No recording: the video will be silent.' : 'Sound: ${track.name}', style: muted),
      if (_ffmpeg == null) ...[
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: colors.recordingWash, borderRadius: BorderRadius.circular(8)),
          child: SelectableText(VideoExport.missingFfmpegForVideo(), style: TextStyle(fontSize: 12.5, color: colors.text)),
        ),
      ],
    ]);
  }

  Widget _writing(BuildContext context) {
    final p = _progress;
    final left = p?.remaining;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(_basename(_output!)),
      const SizedBox(height: 12),
      LinearProgressIndicator(value: p?.fraction),
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
          SizedBox(width: 92, child: Text(label, style: TextStyle(color: context.colors.textMuted))),
          Expanded(child: Align(alignment: Alignment.centerLeft, child: child)),
        ]),
      );
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
