part of '../timeline_panel.dart';

/// The shadow under lanes that are held: one for the whole block.
List<BoxShadow> _liftShadow(AppColors colors) =>
    [BoxShadow(color: colors.text.withValues(alpha: 0.18), blurRadius: 8, offset: const Offset(0, 2))];

class _LanesPainter extends CustomPainter {
  _LanesPainter(this.s, this.colors, Listenable repaint) : super(repaint: repaint);
  final _InstrumentLanesState s;
  final AppColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final c = s.c;
    final parts = s.parts;
    // Only the lanes in view: a score has many, and the canvas is as tall as all of them.
    final view = s._inView;
    bool shown(double top) => top + _laneHeight > view.top && top < view.bottom;

    // The stripes stay put; each lane's content is drawn at its own top, which moves while a
    // lane is being moved (see _InstrumentLanesState._tick).
    for (var i = 0; i < parts.length; i++) {
      if (!shown(i * _laneHeight)) continue;
      canvas.drawRect(Rect.fromLTWH(0, i * _laneHeight, size.width, _laneHeight),
          Paint()..color = i.isEven ? colors.surface : colors.accentWash);
    }
    paintBarGrid(canvas, size, c, colors);

    // The lanes lit up with the name under the mouse: the selection lights up as one.
    final hovered = s._hoverGroup;
    for (var i = 0; i < parts.length; i++) {
      if (hovered.contains(parts[i].id)) {
        canvas.drawRect(Rect.fromLTWH(0, s._rowTop(i), size.width, _laneHeight), Paint()..color = colors.accent.withValues(alpha: 0.06));
      }
    }

    bool held(int i) => s._held.contains(parts[i].id);
    for (var i = 0; i < parts.length; i++) {
      if (!held(i) && shown(s._rowTop(i))) _paintLane(canvas, size, i, s._rowTop(i));
    }
    final blocks = s._heldBlocks(size.width);
    if (blocks.isNotEmpty) {
      // Held lanes float above the others as one block, on one shadow.
      for (final block in blocks) {
        for (final shadow in _liftShadow(colors)) {
          canvas.drawRect(block.shift(shadow.offset), shadow.toPaint());
        }
        canvas.drawRect(block, Paint()..color = colors.surface);
      }
      for (var i = 0; i < parts.length; i++) {
        if (!held(i)) continue;
        canvas.drawRect(Rect.fromLTWH(0, s._rowTop(i), size.width, _laneHeight), Paint()..color = colors.accentSoft);
        _paintLane(canvas, size, i, s._rowTop(i));
      }
    }

    // The box being dragged: a selection outline, or the stretch being drawn or erased.
    final band = s._band.value;
    if (band != null) {
      final color = band.kind == _DragKind.marquee || band.shown ? colors.accentStrong : colors.erase;
      for (final (:x0, :x1, ownStart: _, ownEnd: _) in s._xs(band.q0, band.q1)) {
        final rect = Rect.fromLTRB(x0, band.lane0 * _laneHeight + 1, x1, (band.lane1 + 1) * _laneHeight - 1);
        canvas.drawRect(rect, Paint()..color = color.withValues(alpha: 0.08));
        canvas.drawRect(
          rect,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = color.withValues(alpha: 0.6),
        );
      }
    }
  }

  /// Lane [i]'s content with its top at [top]: where the part plays, and its regions.
  void _paintLane(Canvas canvas, Size size, int i, double top) {
    final c = s.c;
    final parts = s.parts;
    final starts = s.tl.measureStarts;

    // Where each part actually plays (either player, for a condensed pair): a thin hint along
    // the bottom of its lane, one unbroken line for each run of bars the part plays in.
    final activity = Paint()..color = colors.activity;
    final playing = s.score.metadata.activeMeasures;
    final ids = c.condensedGroupOf(parts[i].id)?.partIds ?? [parts[i].id];
    final lists = [for (final id in ids) playing[id] ?? const <bool>[]];
    final active = [
      for (var m = 0; m < lists.map((l) => l.length).reduce(math.max); m++) lists.any((l) => l.elementAtOrNull(m) == true),
    ];
    final y = top + _laneHeight - 5;
    final bars = math.min(active.length, starts.length - 1);
    for (var m = 0; m < bars; m++) {
      if (!active[m]) continue;
      final first = m;
      while (m + 1 < bars && active[m + 1]) {
        m++;
      }
      for (final (:x0, :x1, ownStart: _, ownEnd: _) in s._xs(starts[first], starts[m + 1])) {
        if (x1 < 0 || x0 > size.width) continue;
        canvas.drawRRect(RRect.fromLTRBR(x0 + 1, y, x1 - 1, y + 2, const Radius.circular(1)), activity);
      }
    }

    final selection = c.lanes.selection;
    for (final r in c.curation!.lane(parts[i].id)) {
      final edges = selection[(partId: parts[i].id, region: r)];
      final selected = edges == RegionEdges.both;
      // Once in every pass that plays it; square where a warp cuts it.
      for (final (:x0, :x1, :ownStart, :ownEnd) in s._xs(r.start, r.end)) {
        if (x1 < 0 || x0 > size.width) continue;
        const round = Radius.circular(4);
        final rect = RRect.fromLTRBAndCorners(x0, top + 4, x1, top + _laneHeight - 7,
            topLeft: ownStart ? round : Radius.zero,
            bottomLeft: ownStart ? round : Radius.zero,
            topRight: ownEnd ? round : Radius.zero,
            bottomRight: ownEnd ? round : Radius.zero);
        canvas.drawRRect(rect, Paint()..color = selected ? colors.accent : colors.accentSoft);
        canvas.drawRRect(
          rect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = selected ? 1.5 : 1
            ..color = selected ? colors.accentStrong : colors.accent,
        );
        // A region selected by one edge: a bar on that edge.
        if (edges != null && !selected && (edges.hasStart ? ownStart : ownEnd)) {
          final x = edges.hasStart ? x0 : x1 - 3;
          canvas.drawRRect(RRect.fromLTRBR(x, rect.top, x + 3, rect.bottom, const Radius.circular(1.5)), Paint()..color = colors.accentStrong);
        }
        // An edge with a transition of its own says so beside it, where the region has room.
        TextPainter? label(double? seconds) => seconds == null
            ? null
            : (TextPainter(
                text: TextSpan(text: '$seconds s', style: TextStyle(fontSize: 10, color: selected ? colors.surface : colors.accentStrong)),
                textDirection: TextDirection.ltr,
              )..layout());
        final atStart = ownStart ? label(r.transitionIn) : null, atEnd = ownEnd ? label(r.transitionOut) : null;
        if ((atStart?.width ?? -5) + (atEnd?.width ?? -5) + 20 <= x1 - x0) {
          atStart?.paint(canvas, Offset(x0 + 5, rect.center.dy - atStart.height / 2));
          atEnd?.paint(canvas, Offset(x1 - 5 - atEnd.width, rect.center.dy - atEnd.height / 2));
        }
        atStart?.dispose();
        atEnd?.dispose();
      }
    }
  }

  @override
  bool shouldRepaint(_LanesPainter old) => true;
}
