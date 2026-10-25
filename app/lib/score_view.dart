import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/gestures.dart' show DragStartBehavior, kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart' show ScenePatch;

import 'app_colors.dart';
import 'editor_controller.dart';
import 'edit_dialogs.dart';
import 'error_text.dart';
import 'image_patch.dart';
import 'spacer_dialogs.dart';
import 'ui_kit.dart';
import 'video_export.dart';

part 'score_view/attach_image.dart';

/// The curated score preview, drawn by CuratedScene.paint: a frame is a function of the
/// time alone, which video export reuses (CuratedScene.renderFrame, VideoExport).
///
/// It fills the view, or, given an [aspectRatio], shows the video's frame: that aspect ratio,
/// laid out like the video and scaled to fit ([VideoFrame]), so resizing the window never
/// changes what the score shows.
///
/// Double-click an instrument name to rename it (a text does nothing: editing the score's
/// texts is deprecated, see docs/architecture.md).
///
/// With Attach Image on (Project Settings ▸ Extensions), right-click adds an image (an SVG, PNG or
/// JPEG file, or the clipboard's) where it was clicked; click one to select it, drag it to move it, drag a
/// corner to resize it; double-click it (or right-click ▸ Crop) and the handles crop it.
/// A file dropped on it is added as an image where it is dropped ([ScoreViewState.dropImage]).
///
/// It also adds spacers: a vertical one (a staff of nothing, below the staff clicked) or a
/// horizontal one (a blank before the beat nearest the click), outlined faintly while it is on
/// (not in a video); double-click one (or right-click it) to change or remove it.
///
/// With Captions on, right-click ▸ Add Caption… adds one from where it was clicked;
/// double-click the caption showing (or right-click it) to change or remove it.
/// Where the context menu was opened: the patch, caption or spacer there, the score quarter and
/// staff spaces down, and the staff nearest.
typedef _MenuAt = ({int? patch, int? caption, String? spacer, int? gap, double quarter, double top, String? staff});

class ScoreView extends StatefulWidget {
  const ScoreView({super.key, required this.controller, this.aspectRatio});
  final EditorController controller;

  /// The video's width over its height, to show its frame; null fills the view.
  final double? aspectRatio;

  @override
  State<ScoreView> createState() => ScoreViewState();
}

class ScoreViewState extends State<ScoreView> with _AttachImage {
  void _onDoubleTap(TapDownDetails details, VideoFrame frame) {
    final scene = c.scene, curation = c.curation;
    if (scene == null || curation == null) return;
    if (!frame.rect.contains(details.localPosition)) return;
    final p = frame.toLayout(details.localPosition);
    final size = frame.layout;

    if (_patchAt(p, frame) case final i?) {
      c.images.select(i, crop: !(c.images.selected == i && c.images.cropping));
      return;
    }
    if (_captionAt(p, frame) case final i?) {
      showCaptionDialog(context, c, index: i);
      return;
    }
    if (_gapAt(p, frame) case final i?) {
      showHorizontalSpacerDialog(context, c, i);
      return;
    }
    if (_spacerAt(p, frame) case final id?) {
      showVerticalSpacerDialog(context, c, id);
      return;
    }

    final partId = scene.partLabelAt(p, c.playback.time.value, curation, size);
    if (partId == null) return;
    // A shared staff's name follows its players' (renamed in their lanes).
    final part = c.score!.metadata.parts.where((x) => x.id == partId).firstOrNull;
    if (part != null) showRenameDialog(context, c, part);
  }

  // MARK: Context menu

  final _menu = MenuController();

  /// Where the context menu was opened: the patch, caption or spacer there, or the place a new
  /// image, caption or spacer goes (a vertical one below [staff]).
  _MenuAt? _menuAt;

  /// The vertical spacer shown at [p] (layout points), by part id.
  String? _spacerAt(Offset p, VideoFrame frame) {
    final scene = c.scene, curation = c.curation;
    if (!c.spacers.enabled || scene == null || curation == null || c.spacers.vertical.isEmpty) return null;
    for (final r in scene.spacerRects(c.playback.time.value, curation, frame.layout)) {
      if (r.opacity > 0.5 && r.rect.contains(p)) return r.id;
    }
    return null;
  }

  /// The horizontal spacer at [p] (layout points), an index into [SpacerEditing.horizontal].
  int? _gapAt(Offset p, VideoFrame frame) {
    final scene = c.scene;
    if (!c.spacers.enabled || scene == null || scene.score.gaps.length != c.spacers.horizontal.length) return null;
    for (final g in scene.gapRects(c.playback.time.value, frame.layout)) {
      if (Rect.fromLTRB(g.rect.left - 2, g.rect.top, g.rect.right + 2, g.rect.bottom).contains(p)) return g.index;
    }
    return null;
  }

  /// The beat nearest score quarter [q].
  double _nearestBeat(double q) {
    final beats = c.beats, m = beats.measureAt(q);
    return [...beats.beatsIn(m), ...beats.beatsIn(m + 1)].reduce((a, b) => (a - q).abs() <= (b - q).abs() ? a : b);
  }

  /// The caption under [p] (layout points), when its text shows there.
  int? _captionAt(Offset p, VideoFrame frame) {
    final scene = c.scene, i = c.captions.at(c.playback.time.value);
    if (scene == null || i == null) return null;
    return scene.captionRect(i, frame.layout).inflate(6).contains(p) ? i : null;
  }
  void _openMenu(TapUpDetails d, VideoFrame frame) {
    final scene = c.scene;
    if (!(c.images.enabled || c.captions.enabled) || scene == null || !frame.rect.contains(d.localPosition)) return;
    final p = frame.toLayout(d.localPosition);
    final hit = _patchAt(p, frame), caption = hit == null ? _captionAt(p, frame) : null;
    final gap = hit == null && caption == null ? _gapAt(p, frame) : null;
    final spacer = hit == null && caption == null && gap == null ? _spacerAt(p, frame) : null;
    if (hit != null && hit != c.images.selected) c.images.select(hit);
    final time = c.playback.time.value;
    setState(() => _menuAt = (
          patch: hit,
          caption: caption,
          spacer: spacer,
          gap: gap,
          quarter: scene.quarterAtFrameX(p.dx, time, frame.layout),
          top: p.dy / scene.style.staffSpace,
          staff: c.curation == null ? null : scene.partNearest(p.dy, time, c.curation!, frame.layout),
        ));
    _menu.open(position: d.localPosition);
  }

  List<Widget> _menuItems() {
    final at = _menuAt;
    if (at == null) return const [];
    final patch = at.patch;
    if (patch != null) {
      if (patch >= c.images.patches.length) return const []; // removed (the menu is closing)
      final cropping = c.images.cropping && c.images.selected == patch;
      return [
        MenuItemButton(onPressed: () => c.images.select(patch, crop: !cropping), child: Text(cropping ? 'Done' : 'Crop')),
        CheckboxMenuButton(
          value: c.images.patches[patch].ink,
          onChanged: (on) => c.images.update(patch, c.images.patches[patch].copyWith(ink: on)),
          child: const Text('Score Ink'),
        ),
        MenuItemButton(
          onPressed: () => c.images.remove(patch),
          shortcut: const SingleActivator(LogicalKeyboardKey.backspace),
          child: const Text('Remove'),
        ),
      ];
    }
    if (at.caption case final i?) {
      if (i >= c.captions.captions.length) return const [];
      return [
        MenuItemButton(onPressed: () => showCaptionDialog(context, c, index: i), child: const Text('Edit Caption…')),
        MenuItemButton(onPressed: () => c.captions.remove(i), child: const Text('Remove Caption')),
      ];
    }
    if (at.gap case final i?) {
      if (i >= c.spacers.horizontal.length) return const [];
      return [
        MenuItemButton(onPressed: () => showHorizontalSpacerDialog(context, c, i), child: const Text('Edit Spacer…')),
        MenuItemButton(onPressed: () => c.spacers.removeHorizontal(i), child: const Text('Remove Spacer')),
      ];
    }
    if (at.spacer case final id?) {
      if (c.spacers.verticalOf(id) == null) return const [];
      return [
        MenuItemButton(onPressed: () => showVerticalSpacerDialog(context, c, id), child: const Text('Edit Spacer…')),
        MenuItemButton(onPressed: () => c.spacers.removeVertical(id), child: const Text('Remove Spacer')),
      ];
    }
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    return [
      if (c.images.enabled) ...[
        MenuItemButton(onPressed: () => _addFromFile(at), child: const Text('Add Image…')),
        MenuItemButton(
          onPressed: () => _paste(at),
          shortcut: SingleActivator(LogicalKeyboardKey.keyV, meta: mac, control: !mac),
          child: const Text('Paste'),
        ),
        const Divider(height: 9),
        MenuItemButton(onPressed: () => c.spacers.addVertical(below: at.staff), child: const Text('Add Vertical Spacer')),
        MenuItemButton(
            onPressed: () => c.spacers.addHorizontal(_nearestBeat(at.quarter)), child: const Text('Add Horizontal Spacer')),
      ],
      if (c.captions.enabled)
        MenuItemButton(
            onPressed: switch (c.captions.draft(at.quarter)) {
              final draft? => () => showCaptionDialog(context, c, draft: draft),
              null => null, // no room: the captions there run on to the end
            },
            child: const Text('Add Caption…')),
    ];
  }
  @override
  Widget build(BuildContext context) => Select(
        listenable: c,
        select: () => (
          score: c.score, // and with it the scene
          images: c.images.enabled,
          selected: c.images.selected,
          cropping: c.images.cropping,
          patches: c.images.patches,
          captions: c.captions.enabled,
          captionList: c.captions.captions,
          spacers: c.spacers.vertical,
          gaps: c.spacers.horizontal,
          reengraving: c.isReengraving,
        ),
        builder: (context, _) => _view(context),
      );

  Widget _view(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
      final aspectRatio = widget.aspectRatio;
      final frame = aspectRatio == null
          ? VideoFrame.fill(constraints.biggest)
          : VideoFrame.fit(constraints.biggest, aspectRatio, devicePixelRatio: devicePixelRatio);
      _frame = frame;
      final colors = context.colors;
      final panning = c.images.enabled || _drag != null;
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
        if (c.spacers.enabled && (c.spacers.vertical.isNotEmpty || c.spacers.horizontal.isNotEmpty))
          Positioned.fill(
            child: IgnorePointer(child: CustomPaint(painter: _SpacerOutlines(c, frame, colors))),
          ),
        if (c.images.enabled && c.images.selected != null)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _PatchOverlay(c, frame, colors, devicePixelRatio: devicePixelRatio)),
            ),
          ),
        Positioned.fill(
          // Kept as the overlay above comes and goes: rebuilt, it would drop a drag under way.
          key: const ValueKey('pointer'),
          child: MenuAnchor(
            controller: _menu,
            menuChildren: _menuItems(),
            child: MouseRegion(
              cursor: _drag?.grip.cursor ?? _cursor,
              onHover: (e) => _onHover(e, frame),
              child: Listener(
                behavior: HitTestBehavior.translucent, // the detector below has no child to hit
                onPointerDown: (e) => _onPointerDown(e, frame),
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  dragStartBehavior: DragStartBehavior.down, // a drag takes what was pressed, not what the slop reached
                  onDoubleTapDown: (d) => _onDoubleTap(d, frame),
                  onDoubleTap: () {},
                  onSecondaryTapUp: (d) => _openMenu(d, frame),
                  // Kept while a drag lasts: Attach Image turned off under it, its end still comes.
                  onPanStart: panning ? (d) => _onPanStart(d, frame) : null,
                  onPanUpdate: panning ? (d) => _onPanUpdate(d, frame) : null,
                  onPanEnd: panning ? (_) => _onPanEnd() : null,
                  onPanCancel: panning ? _onPanEnd : null,
                ),
              ),
            ),
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
      end: controller.playback.duration,
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

/// The spacers' outlines, faint and dashed, so what is blank can be found (the editor's only:
/// a video shows the blank).
class _SpacerOutlines extends CustomPainter {
  _SpacerOutlines(this.controller, this.frame, this.colors) : super(repaint: Listenable.merge([controller.playback.repaint, controller]));
  final EditorController controller;
  final VideoFrame frame;
  final AppColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    final scene = controller.scene, curation = controller.curation;
    if (scene == null || curation == null) return;
    final time = controller.playback.time.value;
    canvas
      ..save()
      ..clipRect(frame.rect);
    final ink = colors.textMuted.withValues(alpha: 0.45);
    for (final r in scene.spacerRects(time, curation, frame.layout)) {
      _dashed(canvas, frame.toView(r.rect).deflate(1), ink.withValues(alpha: ink.a * r.opacity));
    }
    for (final g in scene.gapRects(time, frame.layout)) {
      _dashed(canvas, frame.toView(g.rect), ink);
    }
    canvas.restore();
  }

  static void _dashed(Canvas canvas, Rect r, Color color) {
    const dash = 4.0, gap = 3.0;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    void line(Offset a, Offset b) {
      final length = (b - a).distance, step = (b - a) / length;
      for (var d = 0.0; d < length; d += dash + gap) {
        canvas.drawLine(a + step * d, a + step * (d + dash).clamp(0, length), paint);
      }
    }

    line(r.topLeft, r.topRight);
    line(r.topRight, r.bottomRight);
    line(r.bottomRight, r.bottomLeft);
    line(r.bottomLeft, r.topLeft);
  }

  @override
  bool shouldRepaint(_SpacerOutlines old) => old.frame != frame || old.colors != colors;
}
