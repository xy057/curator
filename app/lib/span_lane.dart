import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'editor_controller.dart';
import 'lanes_common.dart';

/// One stretch of the score in a [SpanLane], in score quarters.
typedef Span = ({double start, double end});

/// What a [SpanLane] edits: stretches of the score that never overlap (captions, horizontal
/// spacers), each its own Undo step or part of a gesture's.
abstract interface class SpanLaneModel {
  /// The stretches, in the order the lane keeps them.
  List<Span> get spans;

  /// The one selected (an index into [spans]); null: none.
  int? get selected;
  void select(int? index);

  /// Whether a drag changes it as it goes (one Undo step for the gesture); else it changes once,
  /// when the drag ends, drawn in the lane meanwhile.
  bool get live;

  /// Stretch [index] moved or trimmed to [start]–[end].
  void update(int index, double start, double end);

  /// Every stretch at once, after erasing: each a piece of stretch [from] (an index into [spans]).
  void replaceAll(List<({int from, double start, double end})> pieces);

  /// A new one drawn over [start]–[end].
  void drawn(double start, double end);

  /// Stretch [index] double-clicked.
  void open(int index);

  /// What stretch [index] shows in the lane; null: nothing.
  String? label(int index);

  /// [label] as drawn (its markup's faces, say).
  InlineSpan labelSpan(String label, TextStyle style);
}

/// A lane pinned under the bar ruler in both tabs, never scrolled, moved or unpinned, whose
/// stretches are edited the way an instrument's regions are, with the Instruments tab's tool
/// (the Audio tab selects):
///
/// Select: click a stretch to select it (Delete removes it), drag it to move it, drag an edge
/// to trim it, double-click it to open it; a click on empty space moves the playhead. Draw:
/// drag across bars (a click: one beat, or one bar zoomed out) for a new one. Erase: drag
/// across stretches to cut them back. ⌥ swaps the tools, as in the lanes; edges snap to beats
/// (bars zoomed out), ⌘ places freely. [header] is its name.
class SpanLane extends StatefulWidget {
  const SpanLane({super.key, required this.controller, required this.model, required this.header});
  final EditorController controller;
  final SpanLaneModel model;
  final Widget header;

  static const height = 26.0;

  @override
  State<SpanLane> createState() => _SpanLaneState();
}

enum _Kind { draw, erase, move, start, end, scrub }

class _Drag {
  _Drag(this.kind, {required this.downAt, required this.downQ, required this.pass, this.index, this.from = const []});
  final _Kind kind;
  final Offset downAt;
  final double downQ; // snapped for draw / erase
  final int pass;
  final int? index; // move / trim: the stretch grabbed
  final List<Span> from; // the stretches as they were
  bool moved = false;
}

const _edgeGrab = 6.0;
const _minLength = 0.25;

class _SpanLaneState extends State<SpanLane> {
  EditorController get c => widget.controller;
  SpanLaneModel get model => widget.model;
  ScoreTimeline get tl => c.timeline;

  /// The stretches as drawn: a drag's, while one that isn't [SpanLaneModel.live] lasts.
  List<Span> get spans => _working ?? model.spans;
  List<Span>? _working;

  /// Erasing what isn't live: which stretch each piece is of.
  List<({int from, double start, double end})>? _pieces;

  _Drag? _drag;

  /// The stretch being drawn or erased (score quarters), drawn as a band.
  final _band = ValueNotifier<({double q0, double q1, bool draw})?>(null);
  MouseCursor _cursor = SystemMouseCursors.basic;
  final _clicks = DoubleClicks();

  @override
  void dispose() {
    _band.dispose();
    _clearLabels();
    super.dispose();
  }

  /// Labels as laid out in the lane, kept: playback repaints it every frame.
  final _labels = <(String, double, Color), TextPainter>{};

  TextPainter _label(String text, double maxWidth, Color color) {
    final key = (text, maxWidth, color);
    if (_labels[key] case final label?) return label;
    if (_labels.length >= 64) _clearLabels();
    return _labels[key] = TextPainter(
      text: model.labelSpan(text, TextStyle(fontSize: 11, color: color)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
  }

  void _clearLabels() {
    for (final label in _labels.values) {
      label.dispose();
    }
    _labels.clear();
  }

  /// The tool a drag uses: the Instruments tab's, ⌥ swapping as in the lanes; the Audio tab
  /// has no tools, so it selects.
  LaneTool get _tool {
    final alt = HardwareKeyboard.instance.isAltPressed;
    final tool = c.tab == BottomTab.instruments ? c.lanes.tool : LaneTool.select;
    return switch (tool) {
      LaneTool.select => alt ? LaneTool.draw : LaneTool.select,
      LaneTool.draw => alt ? LaneTool.erase : LaneTool.draw,
      LaneTool.erase => alt ? LaneTool.draw : LaneTool.erase,
    };
  }

  /// Where [q0]–[q1] is drawn: once in every pass that plays it, an end its own or a warp's.
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

  double _q(double x, {int? pass}) {
    final seconds = c.viewport.seconds(x);
    final here = tl.passAt(seconds);
    if (pass == null || here == pass) return tl.quarterAtSeconds(seconds);
    return here < pass ? tl.passes[pass].start : tl.passes[pass].end;
  }

  int _passAt(double x) => tl.passAt(c.viewport.seconds(x));
  double get _total => tl.measureStarts.last;

  double _snap(double q, int pass) => snapInLanes(c, q, pass: pass);

  /// The stretch under [x] and which part of it: an edge or its middle. The one drawn on top
  /// (the later) wins.
  ({int index, _Kind kind})? _hit(double x) {
    for (var i = spans.length - 1; i >= 0; i--) {
      final s = spans[i];
      for (final (:x0, :x1, :ownStart, :ownEnd) in _xs(s.start, s.end)) {
        if (x < x0 - _edgeGrab || x > x1 + _edgeGrab) continue;
        if (ownStart && (x - x0).abs() <= _edgeGrab) return (index: i, kind: _Kind.start);
        if (ownEnd && (x - x1).abs() <= _edgeGrab) return (index: i, kind: _Kind.end);
        if (x > x0 && x < x1) return (index: i, kind: _Kind.move);
      }
    }
    return null;
  }

  void _onHover(PointerHoverEvent e) {
    final tool = _tool;
    final hit = tool == LaneTool.select ? _hit(e.localPosition.dx) : null;
    final cursor = switch (hit?.kind) {
      _Kind.start || _Kind.end => SystemMouseCursors.resizeLeftRight,
      _Kind.move => SystemMouseCursors.grab,
      _ => tool == LaneTool.select ? SystemMouseCursors.basic : SystemMouseCursors.precise,
    };
    if (cursor != _cursor) setState(() => _cursor = cursor);
  }

  void _onDown(PointerDownEvent e) {
    if (e.buttons != kPrimaryButton) return;
    final p = e.localPosition, q = _q(p.dx), pass = _passAt(p.dx);
    final doubleClick = _clicks.press(e.timeStamp, p);

    final tool = _tool;
    if (tool != LaneTool.select) {
      c.clearSelection();
      final draw = tool == LaneTool.draw;
      if (!draw && model.live) c.beginEdit();
      _drag = _Drag(draw ? _Kind.draw : _Kind.erase, downAt: p, downQ: _snap(q, pass), pass: pass, from: model.spans);
      return;
    }

    final hit = _hit(p.dx);
    if (hit == null) {
      c.clearSelection();
      _drag = _Drag(_Kind.scrub, downAt: p, downQ: q, pass: pass);
      c.playback.scrub(c.viewport.seconds(p.dx));
      return;
    }
    c.clearSelection();
    model.select(hit.index);
    if (doubleClick) {
      model.open(hit.index);
      return;
    }
    if (model.live) c.beginEdit();
    _drag = _Drag(hit.kind, downAt: p, downQ: q, pass: pass, index: hit.index, from: model.spans);
    if (hit.kind == _Kind.move) setState(() => _cursor = SystemMouseCursors.grabbing);
  }

  void _onMove(PointerMoveEvent e) {
    final drag = _drag;
    if (drag == null) return;
    final p = e.localPosition, q = _q(p.dx, pass: drag.pass);
    drag.moved |= (p - drag.downAt).distance >= 3;
    switch (drag.kind) {
      case _Kind.scrub:
        c.playback.scrub(c.viewport.seconds(p.dx));
      case _Kind.draw:
        // Up to the stretches either side: they never overlap.
        final edge = _snap(q, drag.pass), room = _room(drag.from, drag.downQ + (edge < drag.downQ ? -1e-6 : 1e-6));
        _band.value = room == null
            ? null
            : (q0: math.max(math.min(drag.downQ, edge), room.from), q1: math.min(math.max(drag.downQ, edge), room.to), draw: true);
      case _Kind.erase:
        final edge = _snap(q, drag.pass);
        final band = (q0: math.min(drag.downQ, edge), q1: math.max(drag.downQ, edge), draw: false);
        _band.value = band;
        _erase(drag.from, band.q0, band.q1);
      case _Kind.move || _Kind.start || _Kind.end:
        if (!drag.moved) return;
        // Never into the stretches either side.
        final was = drag.from[drag.index!], room = _room(drag.from, was.start, except: drag.index)!;
        final Span next = switch (drag.kind) {
          _Kind.start => (
              start: _snap(was.start + q - drag.downQ, drag.pass).clamp(room.from, math.max(room.from, was.end - _minLength)).toDouble(),
              end: was.end,
            ),
          _Kind.end => (
              start: was.start,
              end: _snap(was.end + q - drag.downQ, drag.pass).clamp(math.min(room.to, was.start + _minLength), room.to).toDouble(),
            ),
          _ => () {
              final length = was.end - was.start;
              final start =
                  _snap(was.start + q - drag.downQ, drag.pass).clamp(room.from, math.max(room.from, room.to - length)).toDouble();
              return (start: start, end: start + length);
            }(),
        };
        if (model.live) {
          model.update(drag.index!, next.start, next.end);
        } else {
          setState(() => _working = [...drag.from]..[drag.index!] = next);
        }
    }
  }

  void _onUp(PointerEvent e) {
    final drag = _drag;
    _drag = null;
    final band = _band.value, working = _working;
    _band.value = null;
    if (drag == null) return;
    switch (drag.kind) {
      case _Kind.draw:
        // A click draws one beat (one bar zoomed out), from the beat clicked, as far as there's room.
        var (q0, q1) = band != null && band.q1 - band.q0 > 1e-9 ? (band.q0, band.q1) : _beatAt(drag.downQ, drag.pass);
        if (band == null || band.q1 - band.q0 <= 1e-9) {
          final room = _room(drag.from, _q(drag.downAt.dx, pass: drag.pass));
          if (room == null) return;
          (q0, q1) = (math.max(q0, room.from), math.min(q1, room.to));
        }
        if (q1 - q0 > 1e-9) model.drawn(q0, q1);
      case _Kind.erase:
        if (band == null || band.q1 - band.q0 <= 1e-9) {
          // A click erases the beat (bar) under it.
          final (q0, q1) = _beatAt(_q(drag.downAt.dx), drag.pass);
          _erase(drag.from, q0, q1);
        }
        _end(pieces: _pieces);
      case _Kind.move || _Kind.start || _Kind.end:
        final i = drag.index!;
        _end(moved: working == null ? null : (i, working[i]));
        setState(() => _cursor = SystemMouseCursors.grab);
      case _Kind.scrub:
        c.playback.endScrub();
    }
  }

  /// A gesture that changed stretches is over: one Undo step, live or not.
  void _end({(int, Span)? moved, List<({int from, double start, double end})>? pieces}) {
    _working = null;
    _pieces = null;
    if (model.live) return c.endEdit();
    if (moved case (final i, final s)) model.update(i, s.start, s.end);
    if (pieces != null) model.replaceAll(pieces);
    setState(() {});
  }

  /// [from] with [q0]–[q1] cut out of every stretch: covered ones go, others are trimmed or
  /// split in two, as erasing does to regions.
  void _erase(List<Span> from, double q0, double q1) {
    final pieces = [
      for (final (i, s) in from.indexed)
        if (s.end <= q0 || s.start >= q1)
          (from: i, start: s.start, end: s.end)
        else ...[
          if (s.start < q0 - _minLength / 2) (from: i, start: s.start, end: q0),
          if (s.end > q1 + _minLength / 2) (from: i, start: q1, end: s.end),
        ],
    ];
    if (model.live) return model.replaceAll(pieces);
    setState(() {
      _pieces = pieces;
      _working = [for (final p in pieces) (start: p.start, end: p.end)];
    });
  }

  /// The free stretch around [q] (leaving out stretch [except]); null inside one.
  ({double from, double to})? _room(List<Span> spans, double q, {int? except}) {
    final at = q.clamp(0.0, _total);
    var from = 0.0, to = _total;
    for (final (i, s) in spans.indexed) {
      if (i == except) continue;
      if (at >= s.start - 1e-9 && at < s.end - 1e-9) return null;
      if (s.end <= at + 1e-9) {
        from = math.max(from, s.end);
      } else {
        to = math.min(to, s.start);
      }
    }
    return (from: from, to: to);
  }

  /// The system took the pointer: nothing is drawn; what a drag changed so far stays, as one
  /// Undo step.
  void _onCancel(PointerCancelEvent e) {
    final drag = _drag;
    _drag = null;
    _band.value = null;
    switch (drag?.kind) {
      case _Kind.erase:
        _end(pieces: _pieces);
      case _Kind.move || _Kind.start || _Kind.end:
        final working = _working;
        _end(moved: working == null ? null : (drag!.index!, working[drag.index!]));
        if (_cursor == SystemMouseCursors.grabbing) setState(() => _cursor = SystemMouseCursors.grab);
      case _Kind.scrub:
        c.playback.endScrub();
      case _Kind.draw || null:
        break;
    }
  }

  (double, double) _beatAt(double q, int pass) {
    final beat = beatInLanes(c, q, pass: pass);
    return (beat.start, beat.end);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      height: SpanLane.height,
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(width: kLaneHeaderWidth, child: widget.header),
        Expanded(
          child: MouseRegion(
            cursor: _cursor,
            onHover: _onHover,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _onDown,
              onPointerMove: _onMove,
              onPointerUp: _onUp,
              onPointerCancel: _onCancel,
              child: DecoratedBox(
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: colors.line))),
                child: WithPlayhead(
                  controller: c,
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: _SpanLanePainter(this, colors, AppStyle.of(context).rounded, Listenable.merge([c, c.viewport, _band])),
                  ),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// The stretches as regions, the way the instruments' are drawn: rounded where one starts or
/// ends, square where a warp cuts it; the selected one filled.
class _SpanLanePainter extends CustomPainter {
  _SpanLanePainter(this.s, this.colors, this.rounded, Listenable repaint) : super(repaint: repaint);
  final _SpanLaneState s;
  final AppColors colors;
  final bool rounded;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final c = s.c;
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.accentWash);
    paintBarGrid(canvas, size, c, colors);
    final selected = s.model.selected;
    final working = s._working != null;
    for (final (i, span) in s.spans.indexed) {
      final on = i == selected;
      for (final (:x0, :x1, :ownStart, :ownEnd) in s._xs(span.start, span.end)) {
        if (x1 < 0 || x0 > size.width) continue;
        final round = Radius.circular(rounded ? 4 : 0);
        final rect = RRect.fromLTRBAndCorners(x0, 4, x1, size.height - 5,
            topLeft: ownStart ? round : Radius.zero,
            bottomLeft: ownStart ? round : Radius.zero,
            topRight: ownEnd ? round : Radius.zero,
            bottomRight: ownEnd ? round : Radius.zero);
        canvas.drawRRect(rect, Paint()..color = on ? colors.accent : colors.surface);
        canvas.drawRRect(
          rect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = on ? 1.5 : 1
            ..color = on ? colors.accentStrong : colors.textMuted.withValues(alpha: 0.5),
        );
        // A drag not yet put in shows the stretches only: which is which is the model's.
        final label = working ? null : s.model.label(i);
        if (label == null || x1 - x0 < 16) continue;
        // Whole points, so a scroll (which moves both ends) finds the same one.
        final text = s._label(label, (x1 - x0 - 12).floorToDouble(), on ? colors.surface : colors.text);
        text.paint(canvas, Offset(x0 + 6, rect.center.dy - text.height / 2));
      }
    }
    final band = s._band.value;
    if (band != null) {
      final color = band.draw ? colors.accentStrong : colors.erase;
      for (final (:x0, :x1, ownStart: _, ownEnd: _) in s._xs(band.q0, band.q1)) {
        final rect = Rect.fromLTRB(x0, 1, x1, size.height - 2);
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

  @override
  bool shouldRepaint(_SpanLanePainter old) => true;
}
