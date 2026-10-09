part of '../timeline_panel.dart';

enum _DragKind { paint, move, resizeStart, resizeEnd, scrub, marquee }

class _Drag {
  _Drag(this.kind,
      {required this.downAt, required this.downQ, required this.pass, this.lane = 0, this.grabbed, this.shown = true});
  final _DragKind kind;
  final Offset downAt;
  final double downQ; // score position under the pointer when the drag began
  final int pass; // the pass (see ScoreTimeline.passes) it began in, and stays in
  final int lane; // lane the drag began in
  final RegionRef? grabbed; // move / resize: the region under the pointer
  final bool shown; // paint: draw (true) or erase
  Map<String, List<Region>> from = const {}; // lanes as they were before the drag
  Map<RegionRef, RegionEdges> moving = const {}; // move / resize: the regions dragged, with their selected edges
  Map<RegionRef, RegionEdges> still = const {}; // resize: the rest of the selection, selected at the other side
  Map<RegionRef, RegionEdges> keep = const {}; // marquee: selection it adds to
  bool moved = false;
}

/// The box being dragged out: lanes [lane0, lane1] × score quarters [q0, q1].
typedef _Band = ({int lane0, int lane1, double q0, double q1, _DragKind kind, bool shown});

/// The pointer in the lanes: selecting, moving and trimming regions, drawing and erasing,
/// box-selecting, and moving the playhead.
mixin _RegionDrags on _LaneGeometry {
  _Drag? _drag;
  final _band = ValueNotifier<_Band?>(null);
  MouseCursor _cursor = SystemMouseCursors.basic;
  Duration _lastDown = Duration.zero;
  Offset _lastDownAt = Offset.zero;

  @override
  void dispose() {
    _band.dispose();
    super.dispose();
  }

  // MARK: Hit testing

  ({RegionRef ref, _DragKind kind})? _hit(Offset p) {
    final lane = (p.dy / _laneHeight).floor();
    if (lane < 0 || lane >= parts.length) return null;
    final id = parts[lane].id;
    for (final r in c.curation!.lane(id)) {
      for (final (:x0, :x1, :ownStart, :ownEnd) in _xs(r.start, r.end)) {
        if (p.dx < x0 - _edgeGrab || p.dx > x1 + _edgeGrab) continue;
        final ref = (partId: id, region: r);
        if (ownStart && (p.dx - x0).abs() <= _edgeGrab) return (ref: ref, kind: _DragKind.resizeStart);
        if (ownEnd && (p.dx - x1).abs() <= _edgeGrab) return (ref: ref, kind: _DragKind.resizeEnd);
        if (p.dx > x0 && p.dx < x1) return (ref: ref, kind: _DragKind.move);
      }
    }
    return null;
  }

  /// The tool a plain drag uses now: ⌥ draws with the select tool and swaps draw and erase.
  LaneTool get _tool {
    final alt = HardwareKeyboard.instance.isAltPressed;
    return switch (c.lanes.tool) {
      LaneTool.select => alt ? LaneTool.draw : LaneTool.select,
      LaneTool.draw => alt ? LaneTool.erase : LaneTool.draw,
      LaneTool.erase => alt ? LaneTool.draw : LaneTool.erase,
    };
  }

  // MARK: Pointer handling

  void _onHover(PointerHoverEvent e) {
    final cursor = _cursorAt(e.localPosition);
    if (cursor != _cursor) setState(() => _cursor = cursor);
  }

  /// The cursor over [p]: what a drag from there would do.
  MouseCursor _cursorAt(Offset p) {
    final tool = _tool;
    final hit = tool == LaneTool.select ? _hit(p) : null;
    return switch (hit?.kind) {
      _DragKind.resizeStart || _DragKind.resizeEnd => SystemMouseCursors.resizeLeftRight,
      _DragKind.move => SystemMouseCursors.grab,
      _ => tool == LaneTool.select ? SystemMouseCursors.basic : SystemMouseCursors.precise,
    };
  }

  void _onDown(PointerDownEvent e) {
    c.captions.select(null); // the Delete key goes to what was clicked here
    if (e.buttons != kPrimaryButton) return;
    final keys = HardwareKeyboard.instance;
    final curation = c.curation!;
    final p = e.localPosition;
    final q = _q(p.dx);
    final pass = _passAt(p.dx);
    final doubleClick = e.timeStamp - _lastDown < const Duration(milliseconds: 350) && (p - _lastDownAt).distance < 6;
    _lastDown = e.timeStamp;
    _lastDownAt = p;

    final tool = _tool;
    if (tool != LaneTool.select) {
      c.beginEdit();
      _drag = _Drag(_DragKind.paint,
          downAt: p, downQ: _snap(q, pass), pass: pass, lane: _laneIndex(p), shown: tool == LaneTool.draw)
        ..from = {for (final part in parts) part.id: curation.lane(part.id)};
      return;
    }

    final hit = _hit(p);
    if (hit != null) {
      final ref = hit.ref;
      // An edge selects just that edge; the middle the region, both edges.
      final edges = switch (hit.kind) {
        _DragKind.resizeStart => RegionEdges.start,
        _DragKind.resizeEnd => RegionEdges.end,
        _ => RegionEdges.both,
      };
      if (isCommandPressed) {
        c.lanes.select(ref.partId, ref.region, toggle: true, edges: edges);
        return;
      }
      if (doubleClick) {
        c.lanes.select(ref.partId, ref.region);
        showRegionDialog(context, c, ref);
        return;
      }
      if (keys.isShiftPressed) {
        c.lanes.select(ref.partId, ref.region, add: true, edges: edges);
      } else if (!c.lanes.isSelected(ref.partId, ref.region, edges)) {
        c.lanes.select(ref.partId, ref.region, edges: edges);
      }
      c.beginEdit();
      // A move takes every selected region; a trim those selected at the side grabbed.
      final selection = c.lanes.selection;
      bool dragged(RegionEdges e) => e.covers(edges) || edges == RegionEdges.both;
      _drag = _Drag(hit.kind, downAt: p, downQ: q, pass: pass, grabbed: ref)
        ..from = {for (final part in parts) part.id: curation.lane(part.id)}
        ..moving = {for (final MapEntry(key: r, value: e) in selection.entries) if (dragged(e)) r: e}
        ..still = {for (final MapEntry(key: r, value: e) in selection.entries) if (!dragged(e)) r: e};
      if (hit.kind == _DragKind.move) setState(() => _cursor = SystemMouseCursors.grabbing);
    } else if (keys.isShiftPressed || isCommandPressed) {
      _drag = _Drag(_DragKind.marquee, downAt: p, downQ: q, pass: pass, lane: _laneIndex(p))..keep = c.lanes.selection;
    } else {
      c.clearSelection();
      _drag = _Drag(_DragKind.scrub, downAt: p, downQ: q, pass: pass);
      c.playback.scrub(c.viewport.seconds(p.dx));
    }
  }

  void _onMove(PointerMoveEvent e) {
    final drag = _drag;
    if (drag == null) return;
    final p = e.localPosition;
    final q = _q(p.dx, pass: drag.pass);
    drag.moved |= (p - drag.downAt).distance >= 3;
    switch (drag.kind) {
      case _DragKind.scrub:
        c.playback.scrub(c.viewport.seconds(p.dx));
      case _DragKind.paint:
        final edge = _snap(q, drag.pass);
        _paint(drag, math.min(drag.downQ, edge), math.max(drag.downQ, edge), _laneIndex(p));
      case _DragKind.marquee:
        final lane = _laneIndex(p);
        final band = (
          lane0: math.min(drag.lane, lane),
          lane1: math.max(drag.lane, lane),
          q0: math.min(drag.downQ, q),
          q1: math.max(drag.downQ, q),
          kind: _DragKind.marquee,
          shown: true,
        );
        _band.value = band;
        final range = Region(band.q0, band.q1);
        c.lanes.selectMany([
          for (var i = band.lane0; i <= band.lane1; i++)
            for (final r in c.curation!.lane(parts[i].id))
              if (r.overlaps(range)) (partId: parts[i].id, region: r),
        ], keep: drag.keep, keepLanes: true);
      case _DragKind.move || _DragKind.resizeStart || _DragKind.resizeEnd:
        _reshape(drag, q, _laneIndex(p));
    }
  }

  /// Draw / erase: lanes between the first and current lane, over [q0, q1].
  void _paint(_Drag drag, double q0, double q1, int lane) {
    final lane0 = math.min(drag.lane, lane), lane1 = math.max(drag.lane, lane);
    _band.value = (lane0: lane0, lane1: lane1, q0: q0, q1: q1, kind: _DragKind.paint, shown: drag.shown);
    final range = Region(q0, q1);
    c.lanes.preview({
      for (final (i, part) in parts.indexed)
        part.id: i >= lane0 && i <= lane1 && range.length > 0
            ? Curation.painted(drag.from[part.id]!, range, shown: drag.shown)
            : drag.from[part.id]!,
    });
  }

  /// Move / trim: every selected region follows the grabbed one by the same amount. A move
  /// also follows the pointer up or down into other lanes, keeping the regions' spacing.
  void _reshape(_Drag drag, double q, int lane) {
    final grabbed = drag.grabbed!.region;
    final moving = drag.moving;
    final Region Function(Region) change;
    var lanes = 0; // how many lanes up (-) or down (+) the regions go
    switch (drag.kind) {
      case _DragKind.move:
        final first = moving.keys.map((r) => r.region.start).reduce(math.min);
        final last = moving.keys.map((r) => r.region.end).reduce(math.max);
        final delta = math.max(-first, math.min(_totalQuarters - last, _snap(q - (drag.downQ - grabbed.start), drag.pass) - grabbed.start));
        change = (r) => r.withBounds(r.start + delta, r.end + delta);
        final rows = [for (final r in moving.keys) _row(r.partId)];
        lanes = (lane - _row(drag.grabbed!.partId)).clamp(-rows.reduce(math.min), parts.length - 1 - rows.reduce(math.max));
      case _DragKind.resizeStart:
        final delta = _snap(q, drag.pass) - grabbed.start;
        change = (r) => r.withBounds(math.min(math.max(0.0, r.start + delta), r.end - _minLength), r.end);
      case _DragKind.resizeEnd:
        final delta = _snap(q, drag.pass) - grabbed.end;
        change = (r) => r.withBounds(r.start, math.max(math.min(_totalQuarters, r.end + delta), r.start + _minLength));
      default:
        return;
    }
    final placed = {
      for (final MapEntry(key: r, value: edges) in moving.entries)
        (partId: parts[_row(r.partId) + lanes].id, region: change(r.region)): edges,
    };
    // Always from the lanes as they were: a lane the regions passed through gets its own back.
    c.lanes.preview(relocateRegions(drag.from, moving.keys.toSet(), placed.keys));
    c.lanes.selectEdges({...drag.still, ...placed});
  }

  int _row(String partId) => parts.indexWhere((p) => p.id == partId);

  /// The drag is over: let go, or [cancelled] (the system took the pointer), when what it
  /// changed so far stays, as one Undo step, but a click draws nothing (as in the Captions lane).
  void _onUp(PointerEvent e, {bool cancelled = false}) {
    final drag = _drag;
    _drag = null;
    _band.value = null;
    if (drag?.kind == _DragKind.scrub) c.playback.endScrub();
    if (drag == null || drag.kind == _DragKind.scrub || drag.kind == _DragKind.marquee) return;
    if (drag.kind == _DragKind.paint && !drag.moved && !cancelled) {
      // A click draws (or erases) the beat under the pointer, or the bar when zoomed out.
      final starts = tl.measureStarts;
      final q = _q(drag.downAt.dx).clamp(0.0, _totalQuarters).toDouble();
      final m = c.beats.measureAt(q);
      if (m + 1 < starts.length) {
        if (beatsFit(c, q, pass: drag.pass)) {
          final beat = c.beats.beatAt(q); // a dotted crotchet in 6/8
          _paint(drag, beat.start, beat.end, drag.lane);
        } else {
          _paint(drag, starts[m], starts[m + 1], drag.lane);
        }
      }
      _band.value = null;
    }
    final selected = c.lanes.selection;
    c.endEdit();
    // After merging, keep whatever now covers the edited regions selected.
    if (drag.kind == _DragKind.paint) {
      c.clearSelection();
    } else {
      c.lanes.reselect(selected);
    }
    // What is under the pointer now (a region let go of: the open hand), as the Captions lane does.
    setState(() => _cursor = _cursorAt(e.localPosition));
  }
}
