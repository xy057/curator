import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'captions_dialog.dart';
import 'edit_dialogs.dart';
import 'editor_controller.dart';
import 'lanes_common.dart';
import 'ui_kit.dart';

/// The Captions lane (the Captions extension): pinned under the bar ruler in both tabs, never
/// scrolled, moved or unpinned. A caption is a region in it, edited the way an instrument's
/// regions are, with the Instruments tab's tool (the Audio tab selects):
///
/// Select: click a caption to select it (Delete removes it), drag it to move it, drag an edge
/// to trim it, double-click it for its text and bars; a click on empty space moves the
/// playhead. Draw: drag across bars (a click: one beat, or one bar zoomed out) and type its
/// text. Erase: drag across captions to cut them back. ⌥ swaps the tools, as in the lanes;
/// edges snap to beats (bars zoomed out), ⌘ places freely. Double-click the lane's name for
/// the Captions sheet.
class CaptionLane extends StatefulWidget {
  const CaptionLane({super.key, required this.controller});
  final EditorController controller;

  static const height = 26.0;

  @override
  State<CaptionLane> createState() => _CaptionLaneState();
}

enum _Kind { draw, erase, move, start, end, scrub }

class _Drag {
  _Drag(this.kind, {required this.downAt, required this.downQ, required this.pass, this.index, this.from = const []});
  final _Kind kind;
  final Offset downAt;
  final double downQ; // snapped for draw / erase
  final int pass;
  final int? index; // move / trim: the caption grabbed
  final List<Caption> from; // the captions as they were
  bool moved = false;
}

const _edgeGrab = 6.0;
const _minLength = 0.25;

class _CaptionLaneState extends State<CaptionLane> {
  EditorController get c => widget.controller;
  ScoreTimeline get tl => c.timeline;
  List<Caption> get captions => c.captions.captions;

  _Drag? _drag;

  /// The stretch being drawn or erased (score quarters), drawn as a band.
  final _band = ValueNotifier<({double q0, double q1, bool draw})?>(null);
  MouseCursor _cursor = SystemMouseCursors.basic;
  Duration _lastDown = Duration.zero;
  Offset _lastDownAt = Offset.zero;
  Duration? _lastNameClick;

  @override
  void dispose() {
    _band.dispose();
    _clearLabels();
    super.dispose();
  }

  /// Captions' texts as laid out in the lane, kept: playback repaints it every frame.
  final _labels = <(String, double, Color), TextPainter>{};

  TextPainter _label(String text, double maxWidth, Color color) {
    final key = (text, maxWidth, color);
    if (_labels[key] case final label?) return label;
    if (_labels.length >= 64) _clearLabels();
    return _labels[key] = TextPainter(
      text: TextSpan(text: text, style: TextStyle(fontSize: 11, color: color)),
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

  /// Where caption [i] is drawn: once in every pass that plays it, an end its own or a warp's.
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

  /// To the nearest beat, or barline when beats are too close on screen; ⌘: free.
  double _snap(double q, int pass) {
    q = q.clamp(0.0, _total);
    if (isCommandPressed) return q;
    if (beatsFit(c, q, pass: pass)) {
      final beat = c.beats.beatAt(q);
      return q - beat.start <= beat.end - q ? beat.start : beat.end;
    }
    final starts = tl.measureStarts;
    var i = c.beats.measureAt(q);
    if (i + 1 < starts.length && (starts[i + 1] - q) < (q - starts[i])) i++;
    return starts[i];
  }

  /// The caption under [x] and which part of it: an edge or its middle. The one drawn on
  /// top (the later) wins.
  ({int index, _Kind kind})? _hit(double x) {
    for (var i = captions.length - 1; i >= 0; i--) {
      final cap = captions[i];
      for (final (:x0, :x1, :ownStart, :ownEnd) in _xs(cap.start, cap.end)) {
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
    final doubleClick = e.timeStamp - _lastDown < const Duration(milliseconds: 350) && (p - _lastDownAt).distance < 6;
    _lastDown = e.timeStamp;
    _lastDownAt = p;

    final tool = _tool;
    if (tool != LaneTool.select) {
      c.clearSelection();
      final draw = tool == LaneTool.draw;
      if (!draw) c.beginEdit();
      _drag = _Drag(draw ? _Kind.draw : _Kind.erase, downAt: p, downQ: _snap(q, pass), pass: pass, from: captions);
      return;
    }

    final hit = _hit(p.dx);
    if (hit == null) {
      c.clearSelection();
      _drag = _Drag(_Kind.scrub, downAt: p, downQ: q, pass: pass);
      c.playback.seek(c.viewport.seconds(p.dx).clamp(0.0, c.playback.duration));
      return;
    }
    c.clearSelection();
    c.captions.select(hit.index);
    if (doubleClick) {
      showCaptionDialog(context, c, index: hit.index);
      return;
    }
    c.beginEdit();
    _drag = _Drag(hit.kind, downAt: p, downQ: q, pass: pass, index: hit.index, from: captions);
    if (hit.kind == _Kind.move) setState(() => _cursor = SystemMouseCursors.grabbing);
  }

  void _onMove(PointerMoveEvent e) {
    final drag = _drag;
    if (drag == null) return;
    final p = e.localPosition, q = _q(p.dx, pass: drag.pass);
    drag.moved |= (p - drag.downAt).distance >= 3;
    switch (drag.kind) {
      case _Kind.scrub:
        c.playback.seek(c.viewport.seconds(p.dx).clamp(0.0, c.playback.duration));
      case _Kind.draw:
        // Up to the captions either side: one shows at a time.
        final edge = _snap(q, drag.pass), room = _room(drag.from, drag.downQ + (edge < drag.downQ ? -1e-6 : 1e-6));
        _band.value = room == null
            ? null
            : (q0: math.max(math.min(drag.downQ, edge), room.from), q1: math.min(math.max(drag.downQ, edge), room.to), draw: true);
      case _Kind.erase:
        final edge = _snap(q, drag.pass);
        final band = (q0: math.min(drag.downQ, edge), q1: math.max(drag.downQ, edge), draw: false);
        _band.value = band;
        c.captions.replaceAll(_erased(drag.from, band.q0, band.q1));
      case _Kind.move || _Kind.start || _Kind.end:
        if (!drag.moved) return;
        // Never into the captions either side.
        final was = drag.from[drag.index!], room = _room(drag.from, was.start, except: drag.index)!;
        final next = switch (drag.kind) {
          _Kind.start => was.copyWith(
              start: _snap(was.start + q - drag.downQ, drag.pass).clamp(room.from, math.max(room.from, was.end - _minLength)).toDouble()),
          _Kind.end => was.copyWith(
              end: _snap(was.end + q - drag.downQ, drag.pass).clamp(math.min(room.to, was.start + _minLength), room.to).toDouble()),
          _ => () {
              final length = was.end - was.start;
              final start =
                  _snap(was.start + q - drag.downQ, drag.pass).clamp(room.from, math.max(room.from, room.to - length)).toDouble();
              return was.copyWith(start: start, end: start + length);
            }(),
        };
        c.captions.update(drag.index!, next);
    }
  }

  void _onUp(PointerEvent e) {
    final drag = _drag;
    _drag = null;
    final band = _band.value;
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
        if (q1 - q0 > 1e-9) showCaptionDialog(context, c, draft: Caption(q0, q1, ''));
      case _Kind.erase:
        if (band == null || band.q1 - band.q0 <= 1e-9) {
          // A click erases the beat (bar) under it.
          final (q0, q1) = _beatAt(_q(drag.downAt.dx), drag.pass);
          c.captions.replaceAll(_erased(drag.from, q0, q1));
        }
        c.endEdit();
      case _Kind.move || _Kind.start || _Kind.end:
        c.endEdit();
        setState(() => _cursor = SystemMouseCursors.grab);
      case _Kind.scrub:
        break;
    }
  }

  /// The free stretch around [q] (leaving out caption [except]); null inside a caption.
  ({double from, double to})? _room(List<Caption> captions, double q, {int? except}) =>
      captionRoom(captions, q.clamp(0.0, _total), _total, except: except);

  /// The system took the pointer: nothing is drawn (no dialog); what a drag changed so far
  /// stays, as one Undo step.
  void _onCancel(PointerCancelEvent e) {
    final drag = _drag;
    _drag = null;
    _band.value = null;
    switch (drag?.kind) {
      case _Kind.erase || _Kind.move || _Kind.start || _Kind.end:
        c.endEdit();
        if (_cursor == SystemMouseCursors.grabbing) setState(() => _cursor = SystemMouseCursors.grab);
      case _Kind.draw || _Kind.scrub || null:
        break;
    }
  }

  /// The beat at [q] as it sounds in [pass], or its bar when beats are too close on screen.
  (double, double) _beatAt(double q, int pass) {
    q = q.clamp(0.0, _total - 1e-9);
    if (beatsFit(c, q, pass: pass)) {
      final beat = c.beats.beatAt(q);
      return (beat.start, beat.end);
    }
    final starts = tl.measureStarts, m = c.beats.measureAt(q);
    return (starts[m], starts[math.min(m + 1, starts.length - 1)]);
  }

  /// [from] with [q0]–[q1] cut out of every caption: covered ones go, others are trimmed or
  /// split in two (each keeping the text), as erasing does to regions.
  static List<Caption> _erased(List<Caption> from, double q0, double q1) => [
        for (final cap in from)
          if (cap.end <= q0 || cap.start >= q1)
            cap
          else ...[
            if (cap.start < q0 - _minLength / 2) cap.copyWith(end: q0),
            if (cap.end > q1 + _minLength / 2) cap.copyWith(start: q1),
          ],
      ];

  void _onNameUp(PointerUpEvent e) {
    final last = _lastNameClick;
    final second = last != null && e.timeStamp - last < const Duration(milliseconds: 350);
    _lastNameClick = second ? null : e.timeStamp;
    if (second) showCaptionsDialog(context, c);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      height: CaptionLane.height,
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: kLaneHeaderWidth,
          child: Listener(
            onPointerUp: _onNameUp,
            child: LaneLabel(
              height: CaptionLane.height,
              color: colors.accentWash,
              trailing: Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Tip(message: 'Pinned', child: Icon(Icons.push_pin, size: 13, color: colors.textMuted)),
              ),
              child: const Text('Captions', style: TextStyle(fontWeight: FontWeight.w500)),
            ),
          ),
        ),
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
                    painter: _CaptionLanePainter(this, colors, Listenable.merge([c, c.viewport, _band])),
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

/// The captions as regions, the way the instruments' are drawn: rounded where a caption
/// starts or ends, square where a warp cuts it; the selected one filled.
class _CaptionLanePainter extends CustomPainter {
  _CaptionLanePainter(this.s, this.colors, Listenable repaint) : super(repaint: repaint);
  final _CaptionLaneState s;
  final AppColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final c = s.c;
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.accentWash);
    paintBarGrid(canvas, size, c, colors);
    final selected = c.captions.selected;
    for (final (i, cap) in s.captions.indexed) {
      final on = i == selected;
      for (final (:x0, :x1, :ownStart, :ownEnd) in s._xs(cap.start, cap.end)) {
        if (x1 < 0 || x0 > size.width) continue;
        const round = Radius.circular(4);
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
        if (x1 - x0 < 16) continue;
        // Whole points, so a scroll (which moves both ends) finds the same one.
        final text = s._label(cap.text, (x1 - x0 - 12).floorToDouble(), on ? colors.surface : colors.text);
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
  bool shouldRepaint(_CaptionLanePainter old) => true;
}
