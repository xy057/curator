import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'editor_controller.dart';
import 'project_document.dart';
import 'ui_kit.dart';

/// The one bar above the score: playback on the left, the score's own controls on the right.
/// The document's name is in the window's title bar; files are in the File menu.
class EditorToolbar extends StatelessWidget {
  const EditorToolbar({
    super.key,
    required this.controller,
    required this.document,
    required this.onEditTexts,
    required this.onExportVideo,
    required this.videoFrame,
    required this.onVideoFrame,
    required this.onClose,
  });
  final EditorController controller;
  final ProjectDocument document;
  final VoidCallback onEditTexts;
  final VoidCallback onExportVideo;

  /// Whether the score shows the video's frame rather than filling the window.
  final bool videoFrame;
  final ValueChanged<bool> onVideoFrame;
  final VoidCallback onClose;

  static const height = 46.0;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final colors = context.colors;
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: colors.surface, border: Border(bottom: BorderSide(color: colors.line))),
      child: Row(children: [
        ToolbarButton(
          icon: Icons.home_outlined,
          tooltip: 'Close project (${shortcut('⌘W')})',
          onPressed: onClose,
        ),
        const ToolbarDivider(),
        ToolbarButton(
          icon: Icons.skip_previous_rounded,
          tooltip: 'To start (Home)',
          onPressed: () => c.playback.seek(0),
        ),
        const SizedBox(width: 2),
        _PlayButton(controller: c),
        const SizedBox(width: 12),
        _TimeReadout(controller: c),
        const Spacer(),
        _SavingIndicator(document: document),
        ToolbarButton(
          icon: Icons.undo_rounded,
          tooltip: 'Undo (${shortcut('⌘Z', 'Ctrl+Z')})',
          onPressed: c.canUndo ? c.undo : null,
        ),
        ToolbarButton(
          icon: Icons.redo_rounded,
          tooltip: 'Redo (${shortcut('⇧⌘Z', 'Ctrl+Y')})',
          onPressed: c.canRedo ? c.redo : null,
        ),
        const ToolbarDivider(),
        ToolbarButton(
          icon: Icons.edit_note_rounded,
          tooltip: 'Edit score texts…',
          onPressed: c.isReengraving ? null : onEditTexts,
        ),
        ToolbarButton(
          icon: Icons.movie_outlined,
          tooltip: 'Export video… (${shortcut('⌘E')})',
          onPressed: c.isReengraving ? null : onExportVideo,
        ),
        ToolbarButton(
          icon: Icons.crop_16_9_rounded,
          tooltip: videoFrame ? 'Fill the window' : "Show the video's frame",
          selected: videoFrame,
          onPressed: () => onVideoFrame(!videoFrame),
        ),
        const ToolbarDivider(),
        Tip(
          message: 'Score size',
          child: Icon(Icons.format_size_rounded, size: 16, color: colors.textMuted),
        ),
        SizedBox(
          width: 132,
          // At the top of the window the value shows below the thumb, not above it.
          child: OverlaySemantics(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(valueIndicatorShape: const BelowValueIndicatorShape()),
              child: Slider(
                value: c.staffSpace,
                min: EditorController.minStaffSpace,
                max: EditorController.maxStaffSpace,
                divisions: 14,
                label: c.staffSpace.toStringAsFixed(1),
                onChanged: (v) => c.setStaffSpace(v, dragging: true),
                onChangeEnd: c.setStaffSpace,
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Play / pause: the icon morphs between the two.
class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.controller});
  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final playing = controller.playback.isPlaying;
    return Tip(
      message: playing ? 'Pause (Space)' : 'Play (Space)',
      child: Material(
        color: colors.accent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: controller.playback.togglePlay,
          child: SizedBox.square(
            dimension: 32,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 160),
              transitionBuilder: (child, animation) => ScaleTransition(
                scale: Tween(begin: 0.6, end: 1.0).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutBack)),
                child: FadeTransition(opacity: animation, child: child),
              ),
              child: Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                key: ValueKey(playing),
                size: 20,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "1:10.0 / 1:31.4" and the bar.beat sounding now.
class _TimeReadout extends StatelessWidget {
  const _TimeReadout({required this.controller});
  final EditorController controller;

  static String _clock(double seconds) {
    final s = seconds.clamp(0, 359999);
    final tenths = ((s * 10).floor() % 10);
    return '${s ~/ 60}:${(s.floor() % 60).toString().padLeft(2, '0')}.$tenths';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final mono = TextStyle(fontFeatures: const [FontFeature.tabularFigures()], fontSize: 13, color: colors.text);
    return ValueListenableBuilder<double>(
      valueListenable: controller.playback.time,
      builder: (context, time, _) {
        // The beat sounding now, counted the way the time signature beats (6/8: two dotted crotchets).
        var position = '1.1';
        if (controller.score != null) {
          final q = controller.timeline.quarterAtSeconds(time).clamp(0.0, controller.timeline.measureStarts.last);
          final beats = controller.beats;
          position = beats.format(beats.beatAt(q.toDouble()).start);
        }
        return Row(mainAxisSize: MainAxisSize.min, children: [
          Text.rich(TextSpan(children: [
            TextSpan(text: _clock(time), style: mono.copyWith(fontWeight: FontWeight.w500)),
            TextSpan(text: '  /  ${_clock(controller.playback.duration)}', style: mono.copyWith(color: colors.textMuted)),
          ])),
          const SizedBox(width: 10),
          Tip(
            message: 'Bar.beat sounding now',
            child: Container(
              height: 24,
              constraints: const BoxConstraints(minWidth: 52),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: colors.accentWash, borderRadius: BorderRadius.circular(6), border: Border.all(color: colors.line)),
              child: Text(position, style: mono.copyWith(fontSize: 12, fontWeight: FontWeight.w500, color: colors.text)),
            ),
          ),
        ]);
      },
    );
  }
}

/// A quiet "Saving…" while a save (or autosave) runs.
class _SavingIndicator extends StatelessWidget {
  const _SavingIndicator({required this.document});
  final ProjectDocument document;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return FadeSlideSwitcher(
      alignment: Alignment.centerRight,
      offset: const Offset(0, 0.3),
      child: !document.isSaving
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox.square(dimension: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: colors.textMuted)),
                const SizedBox(width: 6),
                Text('Saving…', style: TextStyle(fontSize: 12, color: colors.textMuted)),
              ]),
            ),
    );
  }
}
