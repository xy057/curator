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

class ScoreViewState extends State<ScoreView> {
  EditorController get c => widget.controller;

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

  // MARK: Images (Attach Image)

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

  _PatchDrag? _drag;
  MouseCursor _cursor = MouseCursor.defer;

  /// Patch [patch] as the scene draws it; null when its image isn't drawn.
  ScenePatch? _scenePatch(ImagePatch patch) {
    final art = c.images.artOf(patch);
    return art == null
        ? null
        : patch.scene(art);
  }

  /// Where patch [index] is now, in layout points.
  Rect? _rectOf(int index, VideoFrame frame) {
    final scene = c.scene, patch = _scenePatch(c.images.patches[index]);
    if (scene == null || patch == null) return null;
    return scene.patchRect(patch, c.playback.time.value, frame.layout);
  }

  /// The topmost patch at [p] (layout points).
  int? _patchAt(Offset p, VideoFrame frame) {
    if (!c.images.enabled) return null;
    for (var i = c.images.patches.length - 1; i >= 0; i--) {
      if (_rectOf(i, frame)?.contains(p) ?? false) return i;
    }
    return null;
  }

  /// What of the selected patch is at [view] (view points): a handle, its body, or nothing.
  _Grip? _gripAt(Offset view, VideoFrame frame) {
    final i = c.images.selected;
    final rect = i == null ? null : _rectOf(i, frame);
    if (rect == null) return null;
    final r = frame.toView(rect);
    // The nearest handle; but inside a patch too small for its handles, nearer the middle
    // than any handle, the body (a handle is then taken from just outside).
    _Grip? grip;
    var distance = _PatchOverlay.handle;
    for (final g in _Grip.handles(cropping: c.images.cropping)) {
      final d = (g.on(r) - view).distance;
      if (d <= distance) (grip, distance) = (g, d);
    }
    return r.contains(view) && (grip == null || (r.center - view).distance < distance) ? _Grip.body : grip;
  }

  void _onPointerDown(PointerDownEvent e, VideoFrame frame) {
    if (!c.images.enabled || e.buttons != kPrimaryButton) return;
    if (_gripAt(e.localPosition, frame) != null) return; // the selected one, to drag
    final hit = _patchAt(frame.toLayout(e.localPosition), frame);
    c.images.select(hit, crop: hit != null && hit == c.images.selected && c.images.cropping);
  }

  void _onPanStart(DragStartDetails d, VideoFrame frame) {
    final i = c.images.selected, grip = _gripAt(d.localPosition, frame);
    final rect = i == null ? null : _rectOf(i, frame);
    if (i == null || grip == null || rect == null) return;
    c.beginEdit();
    _drag = _PatchDrag(i, grip, c.images.patches[i], rect, frame.toLayout(d.localPosition), cropping: c.images.cropping);
  }

  void _onPanUpdate(DragUpdateDetails d, VideoFrame frame) {
    final drag = _drag, scene = c.scene;
    if (drag == null || scene == null) return;
    final rect = drag.rectFor(frame.toLayout(d.localPosition));
    final sp = scene.style.staffSpace;
    final crop = drag.cropping ? drag.cropFor(rect) : drag.start.crop;
    c.images.update(
      drag.index,
      drag.start.copyWith(
        quarter: scene.quarterAtFrameX(rect.left, c.playback.time.value, frame.layout),
        top: rect.top / sp,
        width: rect.width / sp,
        height: rect.height / sp,
        crop: crop,
      ),
    );
  }

  void _onPanEnd() {
    if (_drag == null) return;
    _drag = null;
    c.endEdit();
  }

  void _onHover(PointerHoverEvent e, VideoFrame frame) {
    final cursor = c.images.enabled ? (_gripAt(e.localPosition, frame)?.cursor ?? MouseCursor.defer) : MouseCursor.defer;
    if (cursor != _cursor) setState(() => _cursor = cursor);
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

  /// An SVG (drawn as vectors) or a PNG / JPEG: the file's type says which.
  Future<void> _addFromFile(({int? patch, int? caption, double quarter, double top}) at) async {
    final file = await openFile(acceptedTypeGroups: [ImageKind.types]);
    final kind = file == null ? null : ImageKind.ofPath(file.name);
    if (file == null || kind == null) return;
    try {
      await c.images.add(kind, await file.readAsBytes(), quarter: at.quarter, top: at.top, extension: file.name.split('.').last);
    } catch (e) {
      _say('Could not add the image: ${describeError(e)}');
    }
  }

  Future<void> _paste(({int? patch, int? caption, double quarter, double top}) at) async {
    try {
      if (!await c.images.paste(quarter: at.quarter, top: at.top)) _say('No image to paste.');
    } catch (e) {
      _say('Could not paste the image: ${describeError(e)}');
    }
  }

  /// The frame as last laid out.
  VideoFrame? _frame;

  /// Adds the image file at [path] where it was dropped ([global]: a point in the window),
  /// its top-left corner there; says why when it can't.
  Future<void> dropImage(String path, Offset global) async {
    final scene = c.scene, frame = _frame, box = context.findRenderObject() as RenderBox?;
    if (scene == null || frame == null || box == null) return;
    if (!c.images.enabled) return _say('Attach Image is off.');
    final kind = ImageKind.ofPath(path);
    if (kind == null) return _say('Not an SVG, PNG or JPEG.');
    final r = frame.rect, local = box.globalToLocal(global);
    final p = frame.toLayout(Offset(local.dx.clamp(r.left, r.right), local.dy.clamp(r.top, r.bottom)));
    try {
      await c.images.add(kind, await File(path).readAsBytes(),
          quarter: scene.quarterAtFrameX(p.dx, c.playback.time.value, frame.layout),
          top: p.dy / scene.style.staffSpace,
          extension: path.split('.').last);
    } catch (e) {
      _say('Could not add the image: ${describeError(e)}');
    }
  }

  void _say(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
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

/// What part of a selected patch a drag takes: its body (moves it), a corner or, while
/// cropping, an edge. [dx] / [dy]: which side it is on (-1 left / top, 1 right / bottom).
enum _Grip {
  body(0, 0),
  topLeft(-1, -1),
  top(0, -1),
  topRight(1, -1),
  right(1, 0),
  bottomRight(1, 1),
  bottom(0, 1),
  bottomLeft(-1, 1),
  left(-1, 0);

  const _Grip(this.dx, this.dy);
  final int dx, dy;

  bool get isCorner => dx != 0 && dy != 0;

  /// Corners resize; cropping, the edges crop too.
  static Iterable<_Grip> handles({required bool cropping}) =>
      values.where((g) => g != body && (cropping || g.isCorner));

  Offset on(Rect r) => Offset(r.left + (dx + 1) / 2 * r.width, r.top + (dy + 1) / 2 * r.height);

  MouseCursor get cursor => switch (this) {
        body => SystemMouseCursors.move,
        topLeft || bottomRight => SystemMouseCursors.resizeUpLeftDownRight,
        topRight || bottomLeft => SystemMouseCursors.resizeUpRightDownLeft,
        left || right => SystemMouseCursors.resizeLeftRight,
        top || bottom => SystemMouseCursors.resizeUpDown,
      };
}

/// A drag of patch [index] by [grip], from [origin] (layout points), the patch then [start]
/// drawn at [rect].
class _PatchDrag {
  _PatchDrag(this.index, this.grip, this.start, this.rect, this.origin, {required this.cropping});
  final int index;
  final _Grip grip;
  final ImagePatch start;
  final Rect rect;
  final Offset origin;
  final bool cropping;

  /// The smallest a patch gets, in layout points.
  static const minSide = 8.0;

  /// The whole image, uncropped, as [rect] shows part of it.
  Rect get _full {
    final c = start.crop, w = rect.width / c.width, h = rect.height / c.height;
    return Rect.fromLTWH(rect.left - c.left * w, rect.top - c.top * h, w, h);
  }

  /// Where the patch goes with the pointer at [p].
  Rect rectFor(Offset p) {
    final d = p - origin;
    if (grip == _Grip.body) return rect.shift(d);
    if (cropping) {
      // A patch already smaller than minSide may stay that small, never smaller.
      final f = _full, minWidth = math.min(minSide, rect.width), minHeight = math.min(minSide, rect.height);
      var Rect(:left, :top, :right, :bottom) = rect;
      if (grip.dx < 0) left = (left + d.dx).clamp(math.min(f.left, rect.left), right - minWidth);
      if (grip.dx > 0) right = (right + d.dx).clamp(left + minWidth, math.max(f.right, rect.right));
      if (grip.dy < 0) top = (top + d.dy).clamp(math.min(f.top, rect.top), bottom - minHeight);
      if (grip.dy > 0) bottom = (bottom + d.dy).clamp(top + minHeight, math.max(f.bottom, rect.bottom));
      return Rect.fromLTRB(left, top, right, bottom);
    }
    // A corner: the opposite one stays, the shape is kept; one smaller than minSide doesn't
    // jump to it.
    final ax = grip.dx < 0 ? rect.right : rect.left, ay = grip.dy < 0 ? rect.bottom : rect.top;
    final corner = grip.on(rect) + d; // taken a little off the corner, it doesn't jump either
    final f = math.max(
      math.max(grip.dx * (corner.dx - ax) / rect.width, grip.dy * (corner.dy - ay) / rect.height),
      math.min(1.0, minSide / math.min(rect.width, rect.height)),
    );
    final w = rect.width * f, h = rect.height * f;
    return Rect.fromLTWH(grip.dx < 0 ? ax - w : ax, grip.dy < 0 ? ay - h : ay, w, h);
  }

  /// The part of the image [shown] shows, cropping.
  Rect cropFor(Rect shown) {
    final f = _full;
    return Rect.fromLTRB(
      ((shown.left - f.left) / f.width).clamp(0.0, 1.0),
      ((shown.top - f.top) / f.height).clamp(0.0, 1.0),
      ((shown.right - f.left) / f.width).clamp(0.0, 1.0),
      ((shown.bottom - f.top) / f.height).clamp(0.0, 1.0),
    );
  }
}

/// The selected patch's outline and handles; cropping, the whole image faintly behind.
class _PatchOverlay extends CustomPainter {
  _PatchOverlay(this.controller, this.frame, this.colors, {required this.devicePixelRatio})
      : super(repaint: Listenable.merge([controller.playback.repaint, controller]));
  final EditorController controller;
  final VideoFrame frame;
  final AppColors colors;
  final double devicePixelRatio;

  /// A handle's half size, and how near counts as on it (view points).
  static const handle = 6.0;

  @override
  void paint(Canvas canvas, Size size) {
    final images = controller.images, scene = controller.scene, i = images.selected;
    if (scene == null || i == null || i >= images.patches.length) return;
    final patch = images.patches[i], art = images.artOf(patch);
    if (art == null) return;
    final scenePatch = patch.scene(art);
    final r = frame.toView(scene.patchRect(scenePatch, controller.playback.time.value, frame.layout));
    canvas
      ..save()
      ..clipRect(frame.rect);
    if (images.cropping) {
      final c = patch.crop, w = r.width / c.width, h = r.height / c.height;
      final full = Rect.fromLTWH(r.left - c.left * w, r.top - c.top * h, w, h);
      art.paint(canvas, Offset.zero & art.size, full, opacity: 0.3);
      canvas.drawRect(full, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = colors.accent.withValues(alpha: 0.5));
    }
    canvas.drawRect(r, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = colors.accentStrong);
    for (final grip in _Grip.handles(cropping: images.cropping)) {
      final box = Rect.fromCenter(center: grip.on(r), width: handle * 2 - 2, height: handle * 2 - 2);
      canvas
        ..drawRect(box, Paint()..color = colors.scorePaper)
        ..drawRect(box, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = colors.accentStrong);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PatchOverlay old) => true;
}
