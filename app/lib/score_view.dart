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
/// With Attach Image on (Settings ▸ Extension), right-click adds an image (an SVG, PNG or
/// JPEG file, or the clipboard's) where it was clicked; click one to select it, drag it to move it, drag a
/// corner to resize it; double-click it (or right-click ▸ Crop) and the handles crop it.
/// A file dropped on it is added as an image where it is dropped ([ScoreViewState.dropImage]).
///
/// With Captions on, right-click ▸ Add Caption… adds one from where it was clicked;
/// double-click the caption showing (or right-click it) to change or remove it.
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

    final partId = scene.partLabelAt(p, c.playback.time.value, curation, size);
    if (partId == null) return;
    // A shared staff's name follows its players' (renamed in their lanes).
    final part = c.score!.metadata.parts.where((x) => x.id == partId).firstOrNull;
    if (part != null) showRenameDialog(context, c, part);
  }

  // MARK: Context menu

  final _menu = MenuController();

  /// Where the context menu was opened: the patch or caption there, or the place a new
  /// image or caption goes.
  ({int? patch, int? caption, double quarter, double top})? _menuAt;

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
    if (hit != null && hit != c.images.selected) c.images.select(hit);
    setState(() => _menuAt = (
          patch: hit,
          caption: caption,
          quarter: scene.quarterAtFrameX(p.dx, c.playback.time.value, frame.layout),
          top: p.dy / scene.style.staffSpace,
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
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    return [
      if (c.images.enabled) ...[
        MenuItemButton(onPressed: () => _addFromFile(at), child: const Text('Add Image…')),
        MenuItemButton(
          onPressed: () => _paste(at),
          shortcut: SingleActivator(LogicalKeyboardKey.keyV, meta: mac, control: !mac),
          child: const Text('Paste'),
        ),
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
        if (c.images.enabled && c.images.selected != null)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _PatchOverlay(c, frame, colors, devicePixelRatio: devicePixelRatio)),
            ),
          ),
        Positioned.fill(
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
                  onPanStart: c.images.enabled ? (d) => _onPanStart(d, frame) : null,
                  onPanUpdate: c.images.enabled ? (d) => _onPanUpdate(d, frame) : null,
                  onPanEnd: c.images.enabled ? (_) => _onPanEnd() : null,
                  onPanCancel: c.images.enabled ? _onPanEnd : null,
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
