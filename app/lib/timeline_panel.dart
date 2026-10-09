import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'editor_controller.dart';
import 'edit_dialogs.dart';
import 'lanes_common.dart';
import 'ui_kit.dart';

part 'instrument_lanes/lane_header.dart';
part 'instrument_lanes/lane_moving.dart';
part 'instrument_lanes/lanes_painter.dart';
part 'instrument_lanes/region_drags.dart';

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

/// The lanes' state, in parts: where things are ([_LaneGeometry]), lanes moved by their
/// names ([_LaneMoving]), and the pointer in the lanes ([_RegionDrags]).
class _InstrumentLanesState extends State<InstrumentLanes>
    with SingleTickerProviderStateMixin, _LaneGeometry, _LaneMoving, _RegionDrags {
  @override
  List<ScorePart> get parts => _reordered ?? c.laneParts;

  /// ⌘ (Ctrl) held: scrolling zooms the time axis (see [ViewportGestures]), so the lanes
  /// must not scroll vertically at the same time.
  final _zooming = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  bool _onKey(KeyEvent _) {
    if (mounted) _zooming.value = isZoomModifierPressed;
    return false; // only watching: the key still goes to the shortcuts
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

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _zooming.dispose();
    super.dispose();
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
                onPointerCancel: (e) => _onUp(e, cancelled: true),
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

/// Where things are in the lanes: score positions and screen x, lanes and y.
mixin _LaneGeometry on State<InstrumentLanes> {
  EditorController get c => widget.controller;
  LoadedScore get score => c.score!;
  ScoreTimeline get tl => c.timeline;

  /// The lanes top to bottom, as drawn now (in their new order while one is held).
  List<ScorePart> get parts;

  final _vScroll = ScrollController();

  @override
  void dispose() {
    _vScroll.dispose();
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
}
