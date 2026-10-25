part of '../score_view.dart';

/// Spacers in the score view (Attach Image): the one under the pointer is outlined, a click
/// selects one (outlined, with its handles), a drag moves it and a handle resizes it, as an
/// image's do. A vertical one moves among the staves (dropped between two) and its top or
/// bottom handle sets its height, drawn as it goes; a horizontal one moves to another beat
/// (⌘: anywhere) and its side handles set its width, engraved when it is let go.
mixin _SpacerHandles on State<ScoreView> {
  EditorController get c => widget.controller;

  /// The spacer under the pointer: a vertical one's id, or a horizontal one's index.
  Object? _hoveredSpacer;
  _SpacerDrag? _spacerDrag;

  /// Repaints the outlines (hover and drags change nothing else).
  final _spacerTick = ValueNotifier(0);

  @override
  void dispose() {
    _spacerTick.dispose();
    super.dispose();
  }

  bool get _gapsEngraved => c.scene?.score.gaps.length == c.spacers.horizontal.length;

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
    if (!c.spacers.enabled || scene == null || !_gapsEngraved) return null;
    for (final g in scene.gapRects(c.playback.time.value, frame.layout)) {
      if (_gapHit(g.rect).contains(p)) return g.index;
    }
    return null;
  }

  /// A blank is taken from a little either side of it too.
  static Rect _gapHit(Rect r) => Rect.fromLTRB(r.left - 2, r.top, r.right + 2, r.bottom);

  /// Where vertical spacer [id] is now, in layout points; null while it isn't shown.
  Rect? _verticalRect(String id, VideoFrame frame) {
    final scene = c.scene, curation = c.curation;
    if (scene == null || curation == null) return null;
    return scene.spacerRects(c.playback.time.value, curation, frame.layout).where((r) => r.id == id).firstOrNull?.rect;
  }

  /// Where horizontal spacer [index] is now, in layout points.
  Rect? _gapRect(int index, VideoFrame frame) {
    final scene = c.scene;
    if (scene == null || !_gapsEngraved) return null;
    return scene.gapRects(c.playback.time.value, frame.layout).where((g) => g.index == index).firstOrNull?.rect;
  }

  /// The selected spacer as drawn (layout points), and whether it is a vertical one.
  ({Rect rect, bool vertical})? _selectedSpacer(VideoFrame frame) {
    if (c.spacers.selectedVertical case final id?) {
      if (_verticalRect(id, frame) case final r?) return (rect: r, vertical: true);
    }
    if (c.spacers.selectedHorizontal case final i?) {
      if (_gapRect(i, frame) case final r?) return (rect: r, vertical: false);
    }
    return null;
  }

  /// A vertical spacer's height is set at its top and bottom, a horizontal one's width at its sides.
  static List<_Grip> _spacerGrips(bool vertical) => vertical ? const [_Grip.top, _Grip.bottom] : const [_Grip.left, _Grip.right];

  /// What of the selected spacer is at [view] (view points): a handle, its body, or nothing.
  _Grip? _spacerGripAt(Offset view, VideoFrame frame) {
    if (!c.spacers.enabled) return null;
    final s = _selectedSpacer(frame);
    if (s == null) return null;
    final r = frame.toView(s.rect);
    for (final g in _spacerGrips(s.vertical)) {
      if ((g.on(r) - view).distance <= _PatchOverlay.handle) return g;
    }
    return (s.vertical ? r : _gapHit(r)).contains(view) ? _Grip.body : null;
  }

  /// Selects the spacer pressed at [view] (view points), or lets go of the one selected; true
  /// when the press was on one.
  bool _spacerPointerDown(Offset view, VideoFrame frame) {
    if (!c.spacers.enabled) return false;
    if (_spacerGripAt(view, frame) != null) return true; // the selected one, to drag
    final p = frame.toLayout(view);
    if (_gapAt(p, frame) case final i?) {
      c.spacers.selectHorizontal(i);
      return true;
    }
    if (_spacerAt(p, frame) case final id?) {
      c.spacers.selectVertical(id);
      return true;
    }
    if (c.spacers.hasSelection) c.spacers.selectVertical(null);
    return false;
  }

  /// The cursor over [view]: a handle's or the body's of the selected spacer; null elsewhere.
  /// Keeps which spacer is under the pointer.
  MouseCursor? _spacerHover(Offset view, VideoFrame frame) {
    final p = frame.toLayout(view);
    final hovered = c.spacers.enabled ? _gapAt(p, frame) ?? _spacerAt(p, frame) : null;
    if (hovered != _hoveredSpacer) {
      _hoveredSpacer = hovered;
      _spacerTick.value++;
    }
    return _spacerGripAt(view, frame)?.cursor;
  }

  void _spacerPanStart(DragStartDetails d, VideoFrame frame) {
    final s = _selectedSpacer(frame), grip = _spacerGripAt(d.localPosition, frame);
    if (s == null || grip == null) return;
    final id = c.spacers.selectedVertical, gap = c.spacers.selectedHorizontal;
    if (s.vertical && grip != _Grip.body) c.beginEdit(); // its height, drawn as it goes: one Undo step
    _spacerDrag = _SpacerDrag(
      grip,
      s.rect,
      frame.toLayout(d.localPosition),
      vertical: s.vertical ? id : null,
      gap: s.vertical ? null : gap,
      height: s.vertical ? c.spacers.verticalOf(id!)!.height : 0,
      width: s.vertical ? 0 : c.spacers.horizontal[gap!].width,
    );
    _spacerTick.value++;
  }

  void _spacerPanUpdate(DragUpdateDetails d, VideoFrame frame) {
    final drag = _spacerDrag, scene = c.scene, curation = c.curation;
    if (drag == null || scene == null || curation == null) return;
    if (!c.spacers.enabled) return _spacerPanEnd(commit: false); // turned off under it
    final p = frame.toLayout(d.localPosition), delta = p - drag.origin, sp = scene.style.staffSpace;
    final time = c.playback.time.value, r = drag.rect;
    drag.moved |= delta.distance >= 3;
    switch ((drag.vertical, drag.grip)) {
      case (final id?, _Grip.body):
        // Dropped before the first staff shown whose middle is below the pointer.
        final staves = [for (final s in scene.staffRects(time, curation, frame.layout)) if (s.id != id && s.opacity > 0.5) s];
        final before = staves.where((s) => s.rect.center.dy > p.dy).firstOrNull;
        final above = before == null ? staves.lastOrNull : staves.lastWhere((s) => s.rect.bottom <= before.rect.top, orElse: () => before);
        drag
          ..ghost = r.shift(Offset(0, delta.dy))
          ..dropY = before == null
              ? (above?.rect.bottom ?? r.top) + 4
              : identical(above, before)
                  ? before.rect.top - 4
                  : (above!.rect.bottom + before.rect.top) / 2
          ..before = before?.id;
      case (final id?, final grip):
        final spacer = c.spacers.verticalOf(id);
        if (spacer == null) return;
        final height = ((drag.height + grip.dy * delta.dy / sp) * 4).round() / 4;
        c.spacers.setVertical(
            spacer.copyWith(height: height.clamp(spacer.lines ? 4.0 : VerticalSpacer.minHeight, VerticalSpacer.maxHeight)));
      case (null, _Grip.body):
        final q = scene.quarterAtFrameX(r.right + delta.dx, time, frame.layout);
        final quarter = isCommandPressed ? q : _nearestBeat(q);
        final x = scene.frameXAtQuarter(quarter, time, frame.layout);
        drag
          ..quarter = quarter
          ..ghost = Rect.fromLTRB(x - r.width, r.top, x, r.bottom);
      case (null, final grip):
        final width = ((drag.width + grip.dx * delta.dx / sp) * 2).round() / 2;
        final w = width.clamp(HorizontalSpacer.minWidth, HorizontalSpacer.maxWidth).toDouble();
        drag
          ..newWidth = w
          ..ghost = grip.dx > 0
              ? Rect.fromLTWH(r.left, r.top, w * sp, r.height)
              : Rect.fromLTRB(r.right - w * sp, r.top, r.right, r.bottom);
    }
    _spacerTick.value++;
  }

  /// Ends a drag: what it moved to, or the width it was given, goes in as one Undo step;
  /// not [commit]ting (the system took the pointer), only a height already drawn stays.
  void _spacerPanEnd({bool commit = true}) {
    final drag = _spacerDrag;
    if (drag == null) return;
    _spacerDrag = null;
    _spacerTick.value++;
    switch ((drag.vertical, drag.gap)) {
      case (_?, _) when drag.grip != _Grip.body:
        c.endEdit();
      case (final id?, _):
        if (!commit || !drag.moved || drag.dropY == null) return;
        final others = [for (final p in c.laneParts) if (p.id != id) p.id];
        final before = drag.before;
        // A pair's shared staff is its players' lane.
        final players = c.condensable.where((g) => g.id == before).firstOrNull?.partIds ?? [?before];
        final at = before == null ? others.length : others.indexWhere(players.contains);
        if (at >= 0) c.spacers.moveVertical(id, at);
      case (null, final i?) when drag.grip == _Grip.body:
        if (commit && drag.moved && drag.quarter != null) c.spacers.moveHorizontal(i, drag.quarter!);
      case (null, final i?):
        if (commit && drag.newWidth != null) c.spacers.setHorizontalWidth(i, drag.newWidth!);
      case (null, null):
        break;
    }
  }

  /// The beat nearest score quarter [q].
  double _nearestBeat(double q) {
    final beats = c.beats, m = beats.measureAt(q);
    return [...beats.beatsIn(m), ...beats.beatsIn(m + 1)].reduce((a, b) => (a - q).abs() <= (b - q).abs() ? a : b);
  }
}

/// A drag of the selected spacer by [grip], from [origin] (layout points), the spacer then
/// drawn at [rect], [height] or [width] staff spaces; what it would do so far.
class _SpacerDrag {
  _SpacerDrag(this.grip, this.rect, this.origin, {this.vertical, this.gap, required this.height, required this.width});
  final _Grip grip;
  final Rect rect;
  final Offset origin;
  final String? vertical;
  final int? gap;
  final double height, width;
  bool moved = false;

  /// Where it would go, drawn as an outline (layout points).
  Rect? ghost;

  /// A vertical one: the staff it goes before (null: after the last) and the line it drops on.
  String? before;
  double? dropY;

  /// A horizontal one: the quarter it moves to, or its new width.
  double? quarter, newWidth;
}

/// The spacer under the pointer outlined faintly, the selected one in the accent with its
/// handles, and where a drag would put it (the editor's only: a video shows the blank).
class _SpacerOverlay extends CustomPainter {
  _SpacerOverlay(this.s, this.frame, this.colors)
      : super(repaint: Listenable.merge([s.c.playback.repaint, s.c, s._spacerTick]));
  final _SpacerHandles s;
  final VideoFrame frame;
  final AppColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    final c = s.c;
    if (!c.spacers.enabled) return;
    canvas
      ..save()
      ..clipRect(frame.rect);
    final selected = s._selectedSpacer(frame);
    final hovered = switch (s._hoveredSpacer) {
      final String id when id != c.spacers.selectedVertical => s._verticalRect(id, frame),
      final int i when i != c.spacers.selectedHorizontal => s._gapRect(i, frame),
      _ => null,
    };
    if (hovered != null) _dashed(canvas, frame.toView(hovered).deflate(1), colors.textMuted.withValues(alpha: 0.6));
    final drag = s._spacerDrag;
    if (selected != null) {
      final r = frame.toView(selected.rect);
      final accent = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = colors.accentStrong;
      canvas.drawRect(r, accent);
      if (drag == null || drag.grip != _Grip.body) {
        for (final grip in _SpacerHandles._spacerGrips(selected.vertical)) {
          final box = Rect.fromCenter(center: grip.on(r), width: _PatchOverlay.handle * 2 - 2, height: _PatchOverlay.handle * 2 - 2);
          canvas
            ..drawRect(box, Paint()..color = colors.scorePaper)
            ..drawRect(box, accent);
        }
      }
    }
    if (drag != null && drag.moved) {
      if (drag.ghost case final ghost?) _dashed(canvas, frame.toView(ghost), colors.accentStrong);
      if (drag.dropY case final y?) {
        final r = frame.toView(Rect.fromLTRB(drag.rect.left, y, drag.rect.right, y));
        canvas.drawLine(r.topLeft, r.topRight, Paint()
          ..strokeWidth = 2
          ..color = colors.accentStrong);
      }
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
  bool shouldRepaint(_SpacerOverlay old) => old.frame != frame || old.colors != colors;
}
