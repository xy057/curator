import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'app_settings.dart';
import 'condensing_dialog.dart';
import 'editor_controller.dart';
import 'edit_dialogs.dart';
import 'lanes_common.dart';
import 'ui_kit.dart';

/// Instruments tab: one lane per instrument; a region is a stretch of the video where that
/// instrument's staff is shown.
///
/// Select tool (V): click a region to select it, or one of its edges to select just that
/// edge · ⇧-click adds · ⌘-click toggles · ⇧/⌘-drag on empty space box-selects · drag the
/// selection to move it, along the lane (←/→ from the keyboard) and up or down into other
/// lanes · ↑/↓ select the lane above / below · drag an edge to trim every region selected
/// at that side · the toolbar sets the selected edges' transition (both of a whole region)
/// · double-click a region for its bars and transitions · click empty space to move the
/// playhead · ⌥-drag draws.
/// Draw (D) / Erase (E): drag across lanes and bars to show / hide those instruments there;
/// a click does one beat when zoomed in far enough to snap to beats, otherwise one bar.
/// ⌥ swaps the two.
/// Edges snap to beats (bars when zoomed out); hold ⌘ while dragging for free placement.
/// An instrument's name: click selects its lane, ⇧-click adds it, ⌘-click selects every lane
/// from the last one clicked; double-click renames. Click and hold, then drag up or down, to
/// move it (its staff moves with it in the preview): Violin I at the top, say. Holding a
/// selected lane moves every selected lane, together.
class InstrumentLanes extends StatefulWidget {
  const InstrumentLanes({super.key, required this.controller});
  final EditorController controller;

  @override
  State<InstrumentLanes> createState() => _InstrumentLanesState();
}

const _laneHeight = 26.0;
const _edgeGrab = 6.0;
const _minLength = 0.25; // a sixteenth: regions never collapse to nothing

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

class _InstrumentLanesState extends State<InstrumentLanes> with SingleTickerProviderStateMixin {
  EditorController get c => widget.controller;
  LoadedScore get score => c.score!;
  ScoreTimeline get tl => c.timeline;
  List<ScorePart> get parts => _reordered ?? c.laneParts;

  _Drag? _drag;
  final _band = ValueNotifier<_Band?>(null);
  MouseCursor _cursor = SystemMouseCursors.basic;
  final _vScroll = ScrollController();
  Duration _lastDown = Duration.zero;
  Offset _lastDownAt = Offset.zero;

  /// ⌘ (Ctrl) held: scrolling zooms the time axis (see [ViewportGestures]), so the lanes
  /// must not scroll vertically at the same time.
  final _zooming = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    _motion = createTicker(_tick);
    c.addListener(_orderChanged);
  }

  bool _onKey(KeyEvent _) {
    if (mounted) _zooming.value = isZoomModifierPressed;
    return false; // only watching: the key still goes to the shortcuts
  }

  // MARK: Moving lanes

  /// The lane held by its name, and the lanes moving with it (itself, or every selected lane
  /// when it is one of them), top to bottom; the lanes as they will be when let go, and where
  /// the pointer is.
  String? _lifted;
  List<String> _held = const [];
  List<ScorePart>? _reordered;
  Offset _liftPointer = Offset.zero;
  double _grab = 0; // where the held name was taken, from the top of the held block

  /// How far each held lane was from its place in the block when lifted, and how far the
  /// block has gathered (0…1): all of them close up together, then move as one.
  Map<String, double> _gatherFrom = const {};
  double _gathered = 1;
  final _headersKey = GlobalKey();
  final _viewportKey = GlobalKey();

  /// Lanes on their way to their place (their top, by part id): the held one follows the
  /// pointer, the others slide aside, and the held one settles into its place when let go.
  final _rowY = <String, double>{};
  late final Ticker _motion;
  Duration _lastTick = Duration.zero;

  /// A frame of lanes moving: the names and the lanes are drawn again where they now are,
  /// and nothing else is built.
  final _frame = RepaintSignal();

  /// The top of lane [i] as drawn now.
  double _rowTop(int i) => _rowY[parts[i].id] ?? i * _laneHeight;

  /// The held lanes as objects: each run of held lanes that touch is one block, and once
  /// they have gathered (as they are lifted) there is one. Empty when none is held.
  List<Rect> _heldBlocks(double width) {
    final rows = [for (var i = 0; i < parts.length; i++) if (_held.contains(parts[i].id)) _rowTop(i)]..sort();
    final blocks = <Rect>[];
    for (final top in rows) {
      final last = blocks.lastOrNull;
      if (last != null && top <= last.bottom + 0.5) {
        blocks.last = Rect.fromLTRB(0, last.top, width, top + _laneHeight);
      } else {
        blocks.add(Rect.fromLTWH(0, top, width, _laneHeight));
      }
    }
    return blocks;
  }

  /// The lane name under the mouse, and so the lanes that light up: the whole selection, as
  /// one object, when it is one of them (a hold would move them all); none while one is held.
  String? _hoveredLane;
  Set<String> get _hoverGroup {
    final hovered = _hoveredLane;
    if (hovered == null || _lifted != null) return const {};
    final selected = c.lanes.selectedPartIds;
    return selected.contains(hovered) ? selected : {hovered};
  }

  void _hover(String partId, bool inside) {
    final next = inside ? partId : (_hoveredLane == partId ? null : _hoveredLane);
    if (next != _hoveredLane) setState(() => _hoveredLane = next);
  }

  /// The lanes' order as last drawn at rest (part ids).
  List<String> _shownOrder = const [];

  /// Lanes moved some other way (the ⋯ menu, Undo, condensing) slide to their new places too.
  void _orderChanged() {
    final ids = [for (final p in c.laneParts) p.id];
    if (_lifted != null || listEquals(ids, _shownOrder)) return;
    _slideFrom(_shownOrder);
    _shownOrder = ids;
  }

  /// Lanes not already moving start from where they are in [order] (part ids, top to bottom).
  void _slideFrom(List<String> order) {
    if (order.isEmpty) return;
    for (final (i, id) in order.indexed) {
      _rowY.putIfAbsent(id, () => i * _laneHeight);
    }
    _animate();
  }

  void _lift(String partId, Offset global) {
    final lanes = c.laneParts;
    final i = lanes.indexWhere((p) => p.id == partId);
    final box = _headersKey.currentContext?.findRenderObject() as RenderBox?;
    if (i < 0 || box == null) return;
    // A selected lane takes the whole selection with it, gathered into one block.
    final selected = c.lanes.selectedPartIds;
    final held = selected.contains(partId) ? [for (final p in lanes) if (selected.contains(p.id)) p.id] : [partId];
    if (!selected.contains(partId)) c.clearSelection();
    final blockTop = _rowTop(i) - held.indexOf(partId) * _laneHeight;
    _grab = box.globalToLocal(global).dy - blockTop;
    _gatherFrom = {
      for (final (k, id) in held.indexed) id: _rowTop(lanes.indexWhere((p) => p.id == id)) - (blockTop + k * _laneHeight),
    };
    _gathered = 0;
    _liftPointer = global;
    setState(() {
      _lifted = partId;
      _held = held;
      _reordered = lanes;
    });
    _animate();
  }

  void _dragLifted(Offset global) => _liftPointer = global;

  void _dropLifted() {
    final held = _held, lanes = _reordered;
    setState(() {
      _lifted = null;
      _held = const [];
      _reordered = null;
    });
    if (lanes == null) return;
    _shownOrder = [for (final p in lanes) p.id]; // already there, but for the held ones
    c.moveLanes(held, lanes.indexWhere((p) => held.contains(p.id)));
    _animate(); // the held lanes settle into their places
  }

  void _animate() {
    if (_motion.isActive) return;
    _lastTick = Duration.zero;
    _motion.start();
  }

  /// One frame of moving lanes: scroll near the panel's edges, follow the pointer, put the
  /// held lane where it now is, and ease every other lane towards its place.
  void _tick(Duration elapsed) {
    final dt = ((elapsed - _lastTick).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _lastTick = elapsed;
    final lifted = _lifted;
    var blockTop = 0.0;
    if (lifted != null) {
      _scrollNearEdge(dt);
      final box = _headersKey.currentContext?.findRenderObject() as RenderBox?;
      final lanes = _reordered!;
      final others = [for (final p in lanes) if (!_held.contains(p.id)) p];
      if (box != null) {
        blockTop = (box.globalToLocal(_liftPointer).dy - _grab).clamp(0.0, others.length * _laneHeight);
        // The block follows the pointer exactly; its lanes close up on the held one together.
        _gathered = math.min(1, _gathered + dt / 0.15);
        final closing = 1 - _gathered * _gathered * (3 - 2 * _gathered);
        for (final (k, id) in _held.indexed) {
          _rowY[id] = blockTop + k * _laneHeight + (_gatherFrom[id] ?? 0) * closing;
        }
        final to = ((blockTop + _laneHeight / 2) / _laneHeight).floor().clamp(0, others.length);
        final next = [
          ...others.take(to),
          for (final p in lanes) if (_held.contains(p.id)) p,
          ...others.skip(to),
        ];
        if (!listEquals([for (final p in next) p.id], [for (final p in lanes) p.id])) {
          _slideFrom([for (final p in lanes) p.id]);
          _reordered = next;
        }
      }
    }
    final ease = 1 - math.exp(-dt / 0.05); // a lane covers most of its way in about a tenth of a second
    var moving = false;
    for (final (i, part) in parts.indexed) {
      if (lifted != null && _held.contains(part.id)) continue; // placed with its block
      // Let go, a block is one distance from its place in every lane: it settles as one.
      final target = i * _laneHeight;
      final y = _rowY[part.id] ?? target;
      final next = y + (target - y) * ease;
      if ((next - target).abs() < 0.5) {
        _rowY.remove(part.id);
      } else {
        _rowY[part.id] = next;
        moving = true;
      }
    }
    if (!moving && lifted == null) {
      _rowY.clear();
      _motion.stop();
    }
    _frame.ping();
  }

  /// Near the top or bottom of the panel the lanes scroll, for a lane that goes further: the
  /// closer to the edge, the faster.
  void _scrollNearEdge(double dt) {
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !_vScroll.hasClients) return;
    const edge = 32.0, speed = 600.0; // points a second, at the very edge
    final y = box.globalToLocal(_liftPointer).dy;
    final depth = y < edge ? y - edge : y > box.size.height - edge ? y - (box.size.height - edge) : 0.0;
    if (depth == 0) return;
    final position = _vScroll.position;
    final to = (position.pixels + (depth / edge).clamp(-1.0, 1.0) * speed * dt)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (to != position.pixels) _vScroll.jumpTo(to);
  }

  @override
  void dispose() {
    c.removeListener(_orderChanged);
    _motion.dispose();
    HardwareKeyboard.instance.removeHandler(_onKey);
    _vScroll.dispose();
    _band.dispose();
    _zooming.dispose();
    _frame.dispose();
    super.dispose();
  }

  /// Where the stretch [q0]–[q1] of the score is on screen: once in every pass that plays
  /// it (a repeat shows it again). An end is the stretch's own, or where a warp cuts it.
  Iterable<({double x0, double x1, bool ownStart, bool ownEnd})> _xs(double q0, double q1) sync* {
    for (final s in tl.spans(q0, q1)) {
      yield (
        x0: c.viewport.x(s.startSeconds),
        x1: c.viewport.x(s.endSeconds),
        ownStart: (s.start - q0).abs() < 1e-9,
        ownEnd: (s.end - q1).abs() < 1e-9,
      );
    }
  }

  /// The score position under [x]; with [pass], kept inside that pass (a drag stays in the
  /// pass it began in, rather than leaping with a warp).
  double _q(double x, {int? pass}) {
    final seconds = c.viewport.seconds(x);
    final here = tl.passAt(seconds);
    if (pass == null || here == pass) return tl.quarterAtSeconds(seconds);
    return here < pass ? tl.passes[pass].start : tl.passes[pass].end;
  }

  int _passAt(double x) => tl.passAt(c.viewport.seconds(x));
  double get _totalQuarters => tl.measureStarts.last;

  /// Snaps a score position to the time signature's beats, or to barlines when beats are
  /// too close together on screen (as they sound in [pass]).
  double _snap(double q, int pass) {
    q = q.clamp(0.0, _totalQuarters);
    if (isCommandPressed) return q;
    final starts = tl.measureStarts;
    var i = c.beats.measureAt(q);
    if (beatsFit(c, q, pass: pass)) {
      final beat = c.beats.beatAt(q);
      return q - beat.start <= beat.end - q ? beat.start : beat.end;
    }
    if (i + 1 < starts.length && (starts[i + 1] - q) < (q - starts[i])) i++;
    return starts[i];
  }

  int _laneIndex(Offset p) => (p.dy / _laneHeight).floor().clamp(0, parts.length - 1);

  /// The part of the lanes scrolled into view (from their top): what is worth painting.
  ({double top, double bottom}) get _inView {
    if (!_vScroll.hasClients || !_vScroll.position.hasContentDimensions) return (top: 0, bottom: double.infinity);
    final p = _vScroll.position;
    return (top: p.pixels, bottom: p.pixels + p.viewportDimension);
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

  void _onUp(PointerEvent e) {
    final drag = _drag;
    _drag = null;
    _band.value = null;
    if (drag?.kind == _DragKind.scrub) c.playback.endScrub();
    if (drag == null || drag.kind == _DragKind.scrub || drag.kind == _DragKind.marquee) return;
    if (drag.kind == _DragKind.paint && !drag.moved) {
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

  /// The lanes shown (their ids): the panel is as tall as they are.
  List<String> get _laneIds => [for (final p in c.laneParts) p.id];

  @override
  Widget build(BuildContext context) => Select(
        listenable: c,
        select: () => (curation: c.curation, lanes: _laneIds),
        equals: (a, b) => a.curation == b.curation && listEquals(a.lanes, b.lanes),
        builder: (context, _) => _lanes(context),
      );

  /// What a lane's name shows: the lanes, their names and which are selected.
  ({List<String> ids, List<String> names, Set<String> selected}) get _headerState => (
        ids: [for (final p in parts) p.id],
        names: [for (final p in parts) c.laneName(p)],
        selected: c.lanes.selectedPartIds,
      );

  /// The lanes' [names] where they are drawn now (moving, while a lane is held).
  Widget _names(BuildContext context, Map<String, Widget> names) {
    final blocks = _heldBlocks(kLaneHeaderWidth);
    // Keyed, so each name keeps its hover and the held one its gesture as they move.
    Widget name(int i) => Positioned(
          key: ValueKey(parts[i].id),
          top: _rowTop(i),
          left: 0,
          right: 0,
          height: _laneHeight,
          child: names[parts[i].id]!,
        );
    bool held(int i) => _held.contains(parts[i].id);
    return SizedBox(
      key: _headersKey,
      height: parts.length * _laneHeight,
      child: Stack(clipBehavior: Clip.none, children: [
        for (var i = 0; i < parts.length; i++)
          if (!held(i)) name(i),
        // The held names float above the others as one block, on one shadow.
        for (final block in blocks)
          Positioned.fromRect(
            rect: block,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(color: context.colors.surface, boxShadow: _liftShadow(context.colors)),
              ),
            ),
          ),
        for (var i = 0; i < parts.length; i++)
          if (held(i)) name(i),
      ]),
    );
  }

  Widget _lanes(BuildContext context) {
    final curation = c.curation;
    if (c.score == null || curation == null) return const SizedBox.shrink();
    return ValueListenableBuilder(
      valueListenable: _zooming,
      builder: (context, zooming, lanes) => SingleChildScrollView(
        key: _viewportKey,
        controller: _vScroll,
        physics: zooming ? const NeverScrollableScrollPhysics() : null,
        child: lanes,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: kLaneHeaderWidth,
            child: MouseRegion(
              cursor: _lifted != null ? SystemMouseCursors.grabbing : MouseCursor.defer,
              // Not at every move of a drag in the lanes: only when a name, the order or the
              // lanes selected change (or this state does, moving a lane).
              child: Select(
                listenable: Listenable.merge([c, curation]),
                select: () => _headerState,
                equals: (a, b) => listEquals(a.ids, b.ids) && listEquals(a.names, b.names) && setEquals(a.selected, b.selected),
                builder: (context, shown) {
                  final selectedLanes = shown.selected;
                  final hovered = _hoverGroup;
                  // Built once here: a frame of lanes moving only moves them.
                  final names = {
                    for (final part in parts)
                      part.id: _LaneHeader(
                        controller: c,
                        part: part,
                        selected: selectedLanes.contains(part.id),
                        hovered: hovered.contains(part.id),
                        onHover: (inside) => _hover(part.id, inside),
                        lifted: _held.contains(part.id),
                        onLift: (global) => _lift(part.id, global),
                        onDrag: _dragLifted,
                        onDrop: _dropLifted,
                      ),
                  };
                  return ListenableBuilder(listenable: _frame, builder: (context, _) => _names(context, names));
                },
              ),
            ),
          ),
          Expanded(
            child: MouseRegion(
              cursor: _cursor,
              onHover: _onHover,
              child: Listener(
                onPointerDown: _onDown,
                onPointerMove: _onMove,
                onPointerUp: _onUp,
                onPointerCancel: _onUp,
                child: WithPlayhead(
                  controller: c,
                  child: CustomPaint(
                    size: Size(double.infinity, parts.length * _laneHeight),
                    painter: _LanesPainter(this, context.colors, Listenable.merge([curation, c.viewport, c, _band, _vScroll, _frame])),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Instruments tab tools (right of the tab switch). Every button explains itself on hover.
class InstrumentsToolbar extends StatelessWidget {
  const InstrumentsToolbar({super.key, required this.controller});
  final EditorController controller;

  /// Each tool's icon and hover text: its name, then what each key changes.
  static Map<LaneTool, (IconData, String)> get _tools => {
        LaneTool.select: (Icons.near_me_outlined, 'Select (V)\n${shortcut('⇧ add · ⌘ toggle, no snap · ⌥ draw')}'),
        LaneTool.draw: (Icons.edit_outlined, 'Draw (D)\n${shortcut('⌘ no snap · ⌥ erase')}'),
        LaneTool.erase: (Icons.hide_source_outlined, 'Erase (E)\n${shortcut('⌘ no snap · ⌥ draw')}'),
      };

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final curation = c.curation!;
    final score = c.score!;
    return ListenableBuilder(
      listenable: Listenable.merge([curation, c]),
      builder: (context, _) {
        final selected = c.lanes.selected;
        final lanes = c.lanes.selectedPartIds;
        final status = _status(c, score, c.lanes.selection, lanes);
        return Row(
          children: [
            ToolGroup(children: [
              for (final MapEntry(key: tool, value: (icon, tip)) in _tools.entries)
                ToolbarButton(icon: icon, tooltip: tip, selected: c.lanes.tool == tool, onPressed: () => c.lanes.tool = tool),
            ]),
            const SizedBox(width: 10),
            Expanded(child: FadingText(status, style: TextStyle(fontSize: 12, color: context.colors.textMuted))),
            FadeSlideSwitcher(
              alignment: Alignment.centerRight,
              child: selected.isEmpty
                  ? const SizedBox.shrink()
                  : Row(key: const ValueKey('selection'), mainAxisSize: MainAxisSize.min, children: [
                      ToolbarButton(
                        icon: Icons.first_page_rounded,
                        tooltip: 'Start at the playhead ([)',
                        onPressed: () => c.lanes.trimToPlayhead(start: true),
                      ),
                      ToolbarButton(
                        icon: Icons.last_page_rounded,
                        tooltip: 'End at the playhead (])',
                        onPressed: () => c.lanes.trimToPlayhead(start: false),
                      ),
                      ToolbarButton(icon: Icons.delete_outline_rounded, tooltip: 'Remove (Delete)', onPressed: c.deleteSelection),
                      const ToolbarDivider(),
                      _TransitionMenu(controller: c),
                      const ToolbarDivider(),
                    ]),
            ),
            if (score.condensing.partners.values.any((p) => p.isNotEmpty)) ...[
              ToolbarButton(
                icon: Icons.merge_type_rounded,
                tooltip: 'Condensing…',
                onPressed: () => showCondensingDialog(context, c),
              ),
              const ToolbarDivider(),
            ],
            _TidyMenu(controller: c, lanes: lanes.length),
            ToolbarButton(
              icon: Icons.auto_awesome_outlined,
              tooltip: 'Auto-curate',
              onPressed: c.lanes.autoCurate,
            ),
            ToolbarButton(
              icon: Icons.layers_clear_outlined,
              tooltip: 'Clear all lanes',
              onPressed: c.lanes.clear,
            ),
          ],
        );
      },
    );
  }

  /// What is selected; nothing when nothing is (the tools explain themselves on hover).
  static String? _status(EditorController c, LoadedScore score, Map<RegionRef, RegionEdges> selected, Set<String> lanes) {
    if (selected.length == 1) {
      final MapEntry(key: ref, value: edges) = selected.entries.single;
      final part = score.metadata.parts.firstWhere((p) => p.id == ref.partId);
      final (from, to) = (c.beats.format(ref.region.start), c.beats.format(ref.region.end));
      return '${c.laneName(part)} · ${switch (edges) {
        RegionEdges.both => '$from → $to',
        RegionEdges.start => 'start ($from)',
        RegionEdges.end => 'end ($to)',
      }}';
    }
    if (selected.isNotEmpty) {
      final whole = selected.values.where((e) => e == RegionEdges.both).length, edges = selected.length - whole;
      final what = [if (whole > 0) '$whole ${whole == 1 ? 'region' : 'regions'}', if (edges > 0) '$edges ${edges == 1 ? 'edge' : 'edges'}'];
      return '${what.join(', ')} in ${lanes.length} ${lanes.length == 1 ? 'lane' : 'lanes'} · ${shortcut('←/→ a bar (⇧ a beat)')}';
    }
    if (lanes.length == 1) return c.laneName(score.metadata.parts.firstWhere((p) => p.id == lanes.single));
    if (lanes.isNotEmpty) return '${lanes.length} lanes';
    return null;
  }
}

/// Clean-up that acts on the selected lanes (or all of them).
class _TidyMenu extends StatelessWidget {
  const _TidyMenu({required this.controller, required this.lanes});
  final EditorController controller;
  final int lanes;

  @override
  Widget build(BuildContext context) {
    final where = lanes == 0 ? 'all lanes' : '$lanes selected ${lanes == 1 ? 'lane' : 'lanes'}';
    String bars(double n) => n == 1 ? '1 bar' : '${n.toStringAsFixed(0)} bars';
    return PopupMenuButton<void Function()>(
      tooltip: 'Tidy $where',
      iconSize: 18,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 280),
      style: IconButton.styleFrom(
        fixedSize: const Size(32, 32),
        minimumSize: const Size(32, 32),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      icon: const Icon(Icons.cleaning_services_outlined),
      onSelected: (action) => action(),
      itemBuilder: (context) => [
        PopupMenuItem(enabled: false, height: 28, child: Text('Tidy $where', style: const TextStyle(fontSize: 12))),
        for (final n in const [1.0, 2.0, 4.0])
          PopupMenuItem(
            value: () => controller.lanes.fillGaps(n),
            child: Text('Keep shown through rests of up to ${bars(n)}'),
          ),
        const PopupMenuDivider(),
        for (final n in const [1.0, 2.0])
          PopupMenuItem(
            value: () => controller.lanes.removeShort(n),
            child: Text('Remove regions shorter than ${bars(n)}'),
          ),
      ],
    );
  }
}

/// How long the staves glide at the selected edges (both of a whole region): "0.8 s ▾",
/// their own or the project's (dimmed), for all of them at once.
class _TransitionMenu extends StatelessWidget {
  const _TransitionMenu({required this.controller});
  final EditorController controller;

  /// The project's transition in the menu (a menu's null means it was dismissed).
  static const _project = -1.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final project = controller.curation!.transition;
    final values = controller.lanes.selectedTransitions;
    final value = values.length == 1 ? values.single : _project;
    final (label, tip) = switch (values.length) {
      1 when values.single == null => ('$project s', "the project's"),
      1 => ('${values.single} s', 'their own'),
      _ => ('Mixed', 'mixed'),
    };
    return OverlaySemantics(
      child: PopupMenuButton<double>(
        tooltip: 'Transition ($tip)',
        position: PopupMenuPosition.under,
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.only(left: 6, right: 2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onSelected: (s) => controller.lanes.setTransition(s == _project ? null : s),
        itemBuilder: (context) => [
          CheckedPopupMenuItem(
              value: _project, checked: values.length == 1 && value == null, child: Text("Project's ($project s)")),
          const PopupMenuDivider(),
          for (final s in {...AppSettings.transitionChoices, for (final v in values) ?v}.toList()..sort())
            CheckedPopupMenuItem(value: s, checked: values.length == 1 && value == s, child: Text('$s s')),
        ],
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.animation_rounded, size: 16, color: colors.textMuted),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(
                  fontSize: 12.5,
                  color: values.length == 1 && value != null ? colors.text : colors.textMuted,
                  fontFeatures: const [FontFeature.tabularFigures()])),
          Icon(Icons.arrow_drop_down_rounded, size: 18, color: colors.textMuted),
        ]),
      ),
    );
  }
}

/// What a lane's ⋯ menu offers.
enum _LaneAction {
  rename('Rename…'),
  select('Select all in lane'),
  copy('Copy lane to…'),
  showThroughout('Show throughout'),
  autoCurate('Auto-curate this lane'),
  clear('Clear lane'),
  moveToTop('Move to top'),
  moveToBottom('Move to bottom'),
  scoreOrder('Restore score order');

  const _LaneAction(this.label);
  final String label;
}

class _LaneHeader extends StatefulWidget {
  const _LaneHeader({
    required this.controller,
    required this.part,
    required this.selected,
    required this.hovered,
    required this.onHover,
    required this.lifted,
    required this.onLift,
    required this.onDrag,
    required this.onDrop,
  });
  final EditorController controller;
  final ScorePart part;
  final bool selected;

  /// Under the mouse, or selected with the lane that is (the selection lights up as one).
  final bool hovered;
  final ValueChanged<bool> onHover;

  /// Held (click and hold on the name) and being moved to another place.
  final bool lifted;
  final void Function(Offset global) onLift, onDrag;
  final VoidCallback onDrop;

  @override
  State<_LaneHeader> createState() => _LaneHeaderState();
}

class _LaneHeaderState extends State<_LaneHeader> {
  EditorController get controller => widget.controller;
  ScorePart get part => widget.part;
  Offset? _downAt;
  Duration? _lastClick;

  void _down(PointerDownEvent e) => _downAt = e.buttons == kPrimaryButton ? e.position : null;

  /// A click, handled as the button comes up (not after waiting to see whether a second click
  /// follows), so clicking through lanes one after another keeps up. Not after a hold, which
  /// moved the lane, nor after the pointer wandered off.
  void _up(PointerUpEvent e) {
    final down = _downAt;
    _downAt = null;
    if (down == null || widget.lifted || (e.position - down).distance > 6) return;
    final last = _lastClick;
    final doubleClick = last != null && e.timeStamp - last < const Duration(milliseconds: 350);
    _lastClick = doubleClick ? null : e.timeStamp;
    if (doubleClick && controller.condensedGroupOf(part.id) == null) {
      showRenameDialog(context, controller, part);
    } else if (isCommandPressed) {
      controller.lanes.selectLaneRange(part.id);
    } else {
      controller.lanes.selectLane(part.id, add: HardwareKeyboard.instance.isShiftPressed);
    }
  }

  void _run(BuildContext context, _LaneAction action) {
    final lanes = controller.lanes;
    switch (action) {
      case _LaneAction.rename:
        showRenameDialog(context, controller, part);
      case _LaneAction.select:
        lanes.selectLane(part.id);
      case _LaneAction.copy:
        showCopyLaneDialog(context, controller, part);
      case _LaneAction.showThroughout:
        lanes.showThroughout(part.id);
      case _LaneAction.autoCurate:
        lanes.autoCurate([part.id]);
      case _LaneAction.clear:
        lanes.clear([part.id]);
      case _LaneAction.moveToTop:
        controller.moveLane(part.id, 0);
      case _LaneAction.moveToBottom:
        controller.moveLane(part.id, controller.laneParts.length - 1);
      case _LaneAction.scoreOrder:
        controller.restoreScoreOrder();
    }
  }

  @override
  Widget build(BuildContext context) {
    PopupMenuItem<_LaneAction> item(_LaneAction a) => PopupMenuItem(value: a, child: Text(a.label));
    final group = controller.condensedGroupOf(part.id);
    final condensed = group != null;
    final menu = PopupMenuButton<_LaneAction>(
        tooltip: 'Lane options',
        padding: EdgeInsets.zero,
        iconSize: 16,
        icon: Icon(Icons.more_horiz, color: context.colors.textMuted),
        onSelected: (action) => _run(context, action),
        itemBuilder: (context) => [
          if (!condensed) ...[
            item(_LaneAction.rename),
            const PopupMenuDivider(),
          ],
          item(_LaneAction.select),
          item(_LaneAction.copy),
          const PopupMenuDivider(),
          item(_LaneAction.showThroughout),
          item(_LaneAction.autoCurate),
          item(_LaneAction.clear),
          const PopupMenuDivider(),
          item(_LaneAction.moveToTop),
          item(_LaneAction.moveToBottom),
          if (!controller.isScoreOrder) item(_LaneAction.scoreOrder),
        ],
    );
    final colors = context.colors;
    final label = LaneLabel(
      height: _laneHeight,
      color: widget.lifted
          ? colors.accentSoft
          : widget.selected
              ? widget.hovered
                  ? Color.alphaBlend(colors.accent.withValues(alpha: 0.14), colors.accentSoft)
                  : colors.accentSoft
              : widget.hovered
                  ? colors.accentWash
                  : colors.surface.withValues(alpha: 0),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (condensed)
          Tip(
            message: '${group.partIds.map(controller.partNameOf).join(' and ')}: one lane',
            child: Icon(Icons.link_rounded, size: 14, color: context.colors.textMuted),
          ),
        menu,
      ]),
      child: Listener(
        onPointerDown: _down,
        onPointerUp: _up,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPressStart: (d) => widget.onLift(d.globalPosition),
          onLongPressMoveUpdate: (d) => widget.onDrag(d.globalPosition),
          onLongPressEnd: (_) => widget.onDrop(),
          child: Text(controller.laneName(part)),
        ),
      ),
    );
    return MouseRegion(
      onEnter: (_) => widget.onHover(true),
      onExit: (_) => widget.onHover(false),
      child: label,
    );
  }
}

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
