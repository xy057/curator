import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'edit_dialogs.dart';
import 'editor_controller.dart';
import 'lanes_common.dart';
import 'span_lane.dart';
import 'l10n/l10n.dart';

/// The Tonality lane (the Tonality extension), pinned under the bar ruler in both tabs: each
/// key area wherever its music sounds ([placeSpans]), from where it starts to where the next
/// does, in its key's colour and named as the band names it. Its name's buttons add one where
/// the playhead is, find the keys in the score (Find Keys, in place of those there are), and
/// remove the one selected.
///
/// Edited with the Instruments tab's tool (the Audio tab selects). Select: click a key area to
/// select it (Delete removes it), drag it to move where it starts, never past the areas either
/// side, double-click it for its key and marking; a click before the first moves the playhead.
/// Draw: click for a new one from the beat there. Erase: click one to remove it. ⌥ swaps the
/// tools, as in the lanes; a start snaps to beats (bars zoomed out), ⌘ places freely.
class TonalityLane extends StatefulWidget {
  const TonalityLane({super.key, required this.controller});
  final EditorController controller;

  static const height = SpanLane.height;

  @override
  State<TonalityLane> createState() => _TonalityLaneState();
}

class _Drag {
  _Drag({required this.index, required this.downAt, required this.downQ, required this.pass, required this.from});

  /// The key area held; null: the playhead (a press where none is).
  final int? index;
  final Offset downAt;
  final double downQ;
  final int pass;

  /// Where the key area started.
  final double from;
  bool moved = false;
}

class _TonalityLaneState extends State<TonalityLane> with LaneCursor<TonalityLane> {
  EditorController get c => widget.controller;
  ScoreTimeline get tl => c.timeline;
  List<KeyArea> get areas => c.tonality.areas;

  _Drag? _drag;

  /// Where the Draw tool was pressed: a new key area's start, asked for its key once let go.
  double? _drawAt;
  final _clicks = DoubleClicks();

  /// Names as laid out in the lane, kept: playback repaints it every frame.
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

  @override
  void dispose() {
    _clearLabels();
    super.dispose();
  }

  /// The key areas in time, the last to the end of what plays.
  List<({int index, double start, double end})> get _spans =>
      placeSpans([for (final a in areas) a.at], tl, end: math.max(tl.endSeconds, c.playback.duration));

  /// The tool a press uses: the Instruments tab's, ⌥ swapping as in the lanes; the Audio tab selects.
  LaneTool get _tool {
    final alt = HardwareKeyboard.instance.isAltPressed;
    final tool = c.tab == BottomTab.instruments ? c.lanes.tool : LaneTool.select;
    return switch (tool) {
      LaneTool.select => alt ? LaneTool.draw : LaneTool.select,
      LaneTool.draw => alt ? LaneTool.erase : LaneTool.draw,
      LaneTool.erase => alt ? LaneTool.draw : LaneTool.erase,
    };
  }

  double _q(double x, {int? pass}) {
    final seconds = c.viewport.seconds(x);
    final here = tl.passAt(seconds);
    if (pass == null || here == pass) return tl.quarterAtSeconds(seconds);
    return here < pass ? tl.passes[pass].start : tl.passes[pass].end;
  }

  /// The key area sounding under [x] (an index into the areas).
  int? _hit(double x) {
    final seconds = c.viewport.seconds(x);
    for (final s in _spans) {
      if (seconds >= s.start && seconds < s.end) return s.index < 0 ? null : s.index;
    }
    return null;
  }

  @override
  bool get cursorHeld => _drag?.index != null;

  @override
  MouseCursor cursorAt(Offset local) => switch (_tool) {
        LaneTool.select => _hit(local.dx) == null ? SystemMouseCursors.basic : SystemMouseCursors.grab,
        _ => SystemMouseCursors.precise,
      };

  void _onDown(PointerDownEvent e) {
    if (e.buttons != kPrimaryButton) return;
    final p = e.localPosition, pass = tl.passAt(c.viewport.seconds(p.dx)), q = _q(p.dx);
    final doubleClick = _clicks.press(e.timeStamp, p);
    final hit = _hit(p.dx);
    c.clearSelection();
    switch (_tool) {
      case LaneTool.draw:
        // From the beat pressed in: the one it is under way in.
        _drawAt = isCommandPressed ? q : beatInLanes(c, q, pass: pass).start;
      case LaneTool.erase:
        if (hit != null) c.tonality.remove(hit);
      case LaneTool.select:
        if (hit == null) {
          _drag = _Drag(index: null, downAt: p, downQ: q, pass: pass, from: 0);
          c.playback.scrub(c.viewport.seconds(p.dx));
          return;
        }
        c.tonality.select(hit);
        if (doubleClick) {
          showKeyDialog(context, c, index: hit);
          return;
        }
        c.beginEdit();
        _drag = _Drag(index: hit, downAt: p, downQ: q, pass: pass, from: areas[hit].at);
        showCursor(SystemMouseCursors.grabbing);
    }
  }

  void _onMove(PointerMoveEvent e) {
    final drag = _drag;
    if (drag == null) return;
    final p = e.localPosition;
    final i = drag.index;
    if (i == null) return c.playback.scrub(c.viewport.seconds(p.dx));
    drag.moved |= (p - drag.downAt).distance >= 3;
    if (!drag.moved || i >= areas.length) return;
    // Never past the areas either side: which is which stays.
    const apart = TonalityEditing.apart;
    final lo = i == 0 ? 0.0 : areas[i - 1].at + apart;
    final hi = (i + 1 < areas.length ? areas[i + 1].at : tl.measureStarts.last) - apart;
    if (hi < lo) return;
    final at = snapInLanes(c, drag.from + _q(p.dx, pass: drag.pass) - drag.downQ, pass: drag.pass).clamp(lo, hi).toDouble();
    c.tonality.update(i, areas[i].copyWith(at: at));
  }

  void _onUp(PointerEvent e) {
    final drag = _drag, drawAt = _drawAt;
    _drag = null;
    _drawAt = null;
    if (drawAt != null && e is PointerUpEvent) showKeyDialog(context, c, draft: KeyArea(drawAt, c.tonality.keyAt(drawAt)));
    if (drag == null) return;
    if (drag.index == null) return c.playback.endScrub();
    c.endEdit();
    showCursor(e is PointerCancelEvent ? SystemMouseCursors.basic : cursorAt(e.localPosition));
  }

  /// A key area from the beat the playhead is in, in the key there.
  void _add() {
    final seconds = c.playback.time.value;
    final q = tl.quarterAtSeconds(seconds).clamp(0.0, tl.measureStarts.last - 1e-6);
    final at = beatInLanes(c, q, pass: tl.passAt(seconds)).start;
    showKeyDialog(context, c, draft: KeyArea(at, c.tonality.keyAt(at)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      height: TonalityLane.height,
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: kLaneHeaderWidth,
          child: ListenableBuilder(
            listenable: c,
            builder: (context, _) => LaneLabel(
              height: TonalityLane.height,
              color: colors.accentWash,
              trailing: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  LaneButton(icon: AppIcon.add, tooltip: 'Add Key'.tr, onPressed: _add),
                  LaneButton(icon: AppIcon.search, tooltip: 'Find Keys'.tr, onPressed: c.tonality.canFind ? c.tonality.find : null),
                  LaneButton(
                    icon: AppIcon.delete,
                    tooltip: 'Remove Key'.tr,
                    onPressed: c.tonality.selected == null ? null : c.tonality.remove,
                  ),
                ]),
              ),
              child: Text('Tonality'.tr, style: TextStyle(fontWeight: FontWeight.w500)),
            ),
          ),
        ),
        Expanded(
          child: MouseRegion(
            cursor: laneCursor,
            onHover: cursorHover,
            onExit: cursorExit,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _onDown,
              onPointerMove: _onMove,
              onPointerUp: _onUp,
              onPointerCancel: _onUp,
              child: DecoratedBox(
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: colors.line))),
                child: WithPlayhead(
                  controller: c,
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: _TonalityLanePainter(this, colors, AppStyle.of(context).rounded, Listenable.merge([c, c.viewport])),
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

/// The key areas as the lanes' regions are drawn, each in its key's colour, rounded where it
/// starts and square where the next takes over; the selected one outlined.
class _TonalityLanePainter extends CustomPainter {
  _TonalityLanePainter(this.s, this.colors, this.rounded, Listenable repaint) : super(repaint: repaint);
  final _TonalityLaneState s;
  final AppColors colors;
  final bool rounded;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final c = s.c;
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.accentWash);
    paintBarGrid(canvas, size, c, colors);
    final selected = c.tonality.selected, areas = s.areas;
    final round = Radius.circular(rounded ? 4 : 0);
    for (final span in s._spans) {
      final x0 = c.viewport.x(span.start), x1 = c.viewport.x(span.end) - 1;
      if (x1 < 0 || x0 > size.width || span.index < 0 || span.index >= areas.length) continue;
      final on = span.index == selected, area = areas[span.index];
      final rect = RRect.fromLTRBAndCorners(x0, 4, math.max(x0 + 2, x1), size.height - 5, topLeft: round, bottomLeft: round);
      canvas.drawRRect(rect, Paint()..color = area.key.color);
      if (on) {
        canvas.drawRRect(
          rect.deflate(0.75),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = colors.accentStrong,
        );
      }
      if (x1 - x0 < 16) continue;
      // Kept in view while its area is: the name stays readable scrolled past its start.
      // Its width in whole steps then, so a scroll finds the same one laid out.
      final left = math.max(x0, 0.0), room = x1 - left - 12;
      final width = (x0 < 0 ? (room / 16).floorToDouble() * 16 : room.floorToDouble()).clamp(0.0, 400.0).toDouble();
      if (width < 8) continue;
      final text = s._label(TonalityEditing.labelOf(area), width, const Color(0xFFFFFFFF));
      text.paint(canvas, Offset(left + 6, rect.center.dy - text.height / 2));
    }
  }

  @override
  bool shouldRepaint(_TonalityLanePainter old) => true;
}
