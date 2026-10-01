import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart' show RenderStyle;

import 'app_colors.dart';
import 'editor_controller.dart';
import 'edit_dialogs.dart';
import 'video_export.dart';

/// The curated score preview, drawn by CuratedScene.paint: a frame is a function of the
/// time alone, which video export reuses (CuratedScene.renderFrame, VideoExport).
///
/// It fills the view, or, given an [aspectRatio], shows the video's frame: that aspect ratio,
/// laid out like the video and scaled to fit ([VideoFrame]), so resizing the window never
/// changes what the score shows.
///
/// Double-click a text (tempo mark, "arco", "dolce"…) to edit it in place — Enter saves,
/// Esc cancels, an empty text removes it. Double-click an instrument name to rename it.
class ScoreView extends StatefulWidget {
  const ScoreView({super.key, required this.controller, this.aspectRatio});
  final EditorController controller;

  /// The video's width over its height, to show its frame; null fills the view.
  final double? aspectRatio;

  @override
  State<ScoreView> createState() => _ScoreViewState();
}

class _ScoreViewState extends State<ScoreView> {
  EditorController get c => widget.controller;

  /// The text being edited in place, and where it is drawn (layout points, see [VideoFrame]).
  ({String id, Rect rect})? _editing;
  final _field = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onDoubleTap(TapDownDetails details, VideoFrame frame) {
    final scene = c.scene, curation = c.curation;
    if (scene == null || curation == null) return;
    if (!frame.rect.contains(details.localPosition)) return;
    final p = frame.toLayout(details.localPosition);
    final size = frame.layout;

    final partId = scene.partLabelAt(p, c.playback.time.value, curation, size);
    if (partId != null) {
      // A shared staff's name follows its players' (renamed in their lanes).
      final part = c.score!.metadata.parts.where((x) => x.id == partId).firstOrNull;
      if (part != null) showRenameDialog(context, c, part);
      return;
    }

    final hit = scene.textAt(p, c.playback.time.value, curation, size);
    final text = hit == null ? null : c.textById(hit.id);
    if (hit == null || text == null) return;
    c.playback.pause();
    _field.text = text.current;
    _field.selection = TextSelection(baseOffset: 0, extentOffset: _field.text.length);
    setState(() => _editing = hit);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  void _commit() {
    final editing = _editing;
    if (editing == null) return;
    setState(() => _editing = null);
    final current = c.textById(editing.id)?.current;
    if (_field.text != current) c.editText(editing.id, _field.text);
  }

  void _cancel() => setState(() => _editing = null);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
      final aspectRatio = widget.aspectRatio;
      final frame = aspectRatio == null
          ? VideoFrame.fill(constraints.biggest)
          : VideoFrame.fit(constraints.biggest, aspectRatio, devicePixelRatio: devicePixelRatio);
      final colors = context.colors;
      final editing = _editing;
      final editRect = editing == null ? null : frame.toView(editing.rect);
      return Stack(children: [
        Positioned.fill(child: ColoredBox(color: aspectRatio == null ? colors.scorePaper : colors.surface)),
        Positioned.fromRect(
          rect: frame.rect,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(border: aspectRatio == null ? null : Border.all(color: colors.line)),
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _ScorePainter(c, devicePixelRatio, colors, scale: frame.scale),
                size: Size.infinite,
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onDoubleTapDown: (d) => _onDoubleTap(d, frame),
            onDoubleTap: () {},
          ),
        ),
        if (editing != null && editRect != null)
          Positioned(
            left: math.max(4, editRect.left - 8),
            top: math.max(4, editRect.center.dy - 18),
            width: math.max(editRect.width + 60, 200),
            child: _InlineEditor(
              controller: _field,
              focus: _focus,
              onCommit: _commit,
              onCancel: _cancel,
              onRevert: () {
                final original = c.textById(editing.id)?.original.text;
                if (original != null) _field.text = original;
              },
            ),
          ),
        if (c.isReengraving)
          Positioned(
            right: 12,
            top: 10,
            child: Row(children: [
              const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 6),
              Text('Engraving…', style: TextStyle(fontSize: 12, color: context.colors.textMuted)),
            ]),
          ),
      ]);
    });
  }
}

class _InlineEditor extends StatelessWidget {
  static const _score = RenderStyle();

  const _InlineEditor({
    required this.controller,
    required this.focus,
    required this.onCommit,
    required this.onCancel,
    required this.onRevert,
  });
  final TextEditingController controller;
  final FocusNode focus;
  final VoidCallback onCommit;
  final VoidCallback onCancel;
  final VoidCallback onRevert;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      elevation: 4,
      shadowColor: colors.accentStrong.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(8),
      color: colors.scorePaper,
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): onCancel},
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focus,
              // The score's own text font and ink: the edit looks like the text it becomes.
              style: TextStyle(fontFamily: _score.textFontFamily, fontSize: 16, color: colors.scoreInk),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                hintText: 'Empty removes the text',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: colors.accent),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: colors.accentStrong, width: 1.5),
                ),
              ),
              onSubmitted: (_) => onCommit(),
              onTapOutside: (_) => onCommit(),
            ),
          ),
          IconButton(
            tooltip: 'Revert',
            icon: Icon(Icons.history, size: 18, color: colors.textMuted),
            onPressed: onRevert,
          ),
        ]),
      ),
    );
  }
}

class _ScorePainter extends CustomPainter {
  _ScorePainter(this.controller, this.devicePixelRatio, this.colors, {required this.scale})
      : super(repaint: controller.playback.repaint);
  final EditorController controller;
  final double devicePixelRatio;
  final AppColors colors;

  /// View points a layout point ([VideoFrame.scale]): 1 when filling the view.
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final scene = controller.scene, curation = controller.curation;
    if (scene == null || curation == null || size.isEmpty) return;
    // Laid out at the frame's layout size, scaled to fit, as the export dialog's still is
    // (VideoExport.paintPreview).
    canvas
      ..clipRect(Offset.zero & size)
      ..scale(scale);
    scene.paint(
      canvas,
      size / scale,
      time: controller.playback.time.value,
      curation: curation,
      devicePixelRatio: devicePixelRatio * scale,
      paper: colors.scorePaper,
      ink: colors.scoreInk,
    );
  }

  @override
  bool shouldRepaint(_ScorePainter old) =>
      old.controller != controller ||
      old.devicePixelRatio != devicePixelRatio ||
      old.scale != scale ||
      old.colors.scorePaper != colors.scorePaper ||
      old.colors.scoreInk != colors.scoreInk;
}
