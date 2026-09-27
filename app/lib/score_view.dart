import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart' show RenderStyle;

import 'app_colors.dart';
import 'editor_controller.dart';
import 'edit_dialogs.dart';

/// The curated score preview, drawn by CuratedScene.paint: a frame is a function of the
/// time alone, which video export reuses (CuratedScene.renderFrame, VideoExport).
///
/// Double-click a text (tempo mark, "arco", "dolce"…) to edit it in place — Enter saves,
/// Esc cancels, an empty text removes it. Double-click an instrument name to rename it.
class ScoreView extends StatefulWidget {
  const ScoreView({super.key, required this.controller});
  final EditorController controller;

  @override
  State<ScoreView> createState() => _ScoreViewState();
}

class _ScoreViewState extends State<ScoreView> {
  EditorController get c => widget.controller;

  /// The text being edited in place, and where it is drawn.
  ({String id, Rect rect})? _editing;
  final _field = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onDoubleTap(TapDownDetails details, Size size) {
    final scene = c.scene, curation = c.curation;
    if (scene == null || curation == null) return;
    final p = details.localPosition;

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
      final size = constraints.biggest;
      final editing = _editing;
      return Stack(children: [
        Positioned.fill(child: ColoredBox(color: context.colors.scorePaper)),
        Positioned.fill(
          child: GestureDetector(
            onDoubleTapDown: (d) => _onDoubleTap(d, size),
            onDoubleTap: () {},
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _ScorePainter(c, MediaQuery.devicePixelRatioOf(context), context.colors),
                size: Size.infinite,
              ),
            ),
          ),
        ),
        if (editing != null)
          Positioned(
            left: math.max(4, editing.rect.left - 8),
            top: math.max(4, editing.rect.center.dy - 18),
            width: math.max(editing.rect.width + 60, 200),
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
            tooltip: 'Back to the text in the file',
            icon: Icon(Icons.history, size: 18, color: colors.textMuted),
            onPressed: onRevert,
          ),
        ]),
      ),
    );
  }
}

class _ScorePainter extends CustomPainter {
  _ScorePainter(this.controller, this.devicePixelRatio, this.colors) : super(repaint: controller.playback.repaint);
  final EditorController controller;
  final double devicePixelRatio;
  final AppColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    final scene = controller.scene, curation = controller.curation;
    if (scene == null || curation == null) return;
    canvas.clipRect(Offset.zero & size);
    scene.paint(
      canvas,
      size,
      time: controller.playback.time.value,
      curation: curation,
      devicePixelRatio: devicePixelRatio,
      paper: colors.scorePaper,
      ink: colors.scoreInk,
    );
  }

  @override
  bool shouldRepaint(_ScorePainter old) =>
      old.controller != controller ||
      old.devicePixelRatio != devicePixelRatio ||
      old.colors.scorePaper != colors.scorePaper ||
      old.colors.scoreInk != colors.scoreInk;
}
