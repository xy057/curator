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

/// The Chapters lane (the Chapters extension), pinned under the bar ruler in both tabs: each
/// chapter wherever its music sounds ([chapterSpans]), from where it starts to where the next does. Its
/// name's buttons add one where the playhead is, add one at every rehearsal mark, and remove
/// the one selected.
///
/// Edited with the Instruments tab's tool (the Audio tab selects). Select: click a chapter to
/// select it (Delete removes it), drag it to move where it starts, never past the chapters
/// either side, double-click it for its name; a click before the first moves the playhead.
/// Draw: click for a new one from the beat there. Erase: click one to remove it. ⌥ swaps the
/// tools, as in the lanes; a start snaps to beats (bars zoomed out), ⌘ places freely.
class ChapterLane extends StatefulWidget {
  const ChapterLane({super.key, required this.controller});
  final EditorController controller;

  static const height = SpanLane.height;

  @override
  State<ChapterLane> createState() => _ChapterLaneState();
}

class _Drag {
  _Drag({required this.index, required this.downAt, required this.downQ, required this.pass, required this.from});

  /// The chapter held; null: the playhead (a press where no chapter is).
  final int? index;
  final Offset downAt;
  final double downQ;
  final int pass;

  /// Where the chapter started.
  final double from;
  bool moved = false;
}

class _ChapterLaneState extends State<ChapterLane> with LaneCursor<ChapterLane> {
  EditorController get c => widget.controller;
  ScoreTimeline get tl => c.timeline;
  List<Chapter> get chapters => c.chapters.chapters;

  _Drag? _drag;

  /// Where the Draw tool was pressed: a new chapter's start, asked for its name once let go.
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

  /// The chapters in time, the last to the end of what plays.
  List<ChapterSpan> get _spans => chapterSpans(chapters, tl, end: math.max(tl.endSeconds, c.playback.duration));

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

  /// The chapter sounding under [x] (an index into the chapters).
  int? _hit(double x) {
    final seconds = c.viewport.seconds(x);
    for (final s in _spans) {
      if (seconds >= s.start && seconds < s.end) return s.chapter < 0 ? null : s.chapter;
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
        if (hit != null) c.chapters.remove(hit);
      case LaneTool.select:
        if (hit == null) {
          _drag = _Drag(index: null, downAt: p, downQ: q, pass: pass, from: 0);
          c.playback.scrub(c.viewport.seconds(p.dx));
          return;
        }
        c.chapters.select(hit);
        if (doubleClick) {
          showChapterDialog(context, c, index: hit);
          return;
        }
        c.beginEdit();
        _drag = _Drag(index: hit, downAt: p, downQ: q, pass: pass, from: chapters[hit].at);
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
    if (!drag.moved || i >= chapters.length) return;
    // Never past the chapters either side: which is which stays.
    const apart = ChapterEditing.apart;
    final lo = i == 0 ? 0.0 : chapters[i - 1].at + apart;
    final hi = (i + 1 < chapters.length ? chapters[i + 1].at : tl.measureStarts.last) - apart;
    if (hi < lo) return;
    final at = snapInLanes(c, drag.from + _q(p.dx, pass: drag.pass) - drag.downQ, pass: drag.pass).clamp(lo, hi).toDouble();
    c.chapters.update(i, chapters[i].copyWith(at: at));
  }

  void _onUp(PointerEvent e) {
    final drag = _drag, drawAt = _drawAt;
    _drag = null;
    _drawAt = null;
    if (drawAt != null && e is PointerUpEvent) showChapterDialog(context, c, draft: Chapter(drawAt, ''));
    if (drag == null) return;
    if (drag.index == null) return c.playback.endScrub();
    c.endEdit();
    showCursor(e is PointerCancelEvent ? SystemMouseCursors.basic : cursorAt(e.localPosition));
  }

  /// A chapter from the beat the playhead is in.
  void _add() {
    final seconds = c.playback.time.value;
    final q = tl.quarterAtSeconds(seconds).clamp(0.0, tl.measureStarts.last - 1e-6);
    showChapterDialog(context, c, draft: Chapter(beatInLanes(c, q, pass: tl.passAt(seconds)).start, ''));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      height: ChapterLane.height,
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: kLaneHeaderWidth,
          child: ListenableBuilder(
            listenable: c,
            builder: (context, _) => LaneLabel(
              height: ChapterLane.height,
              color: colors.accentWash,
              trailing: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  LaneButton(icon: AppIcon.add, tooltip: 'Add Chapter'.tr, onPressed: _add),
                  LaneButton(
                    icon: AppIcon.score,
                    tooltip: 'Add from Rehearsal Marks'.tr,
                    onPressed: c.chapters.canAddMarks ? c.chapters.addMarks : null,
                  ),
                  LaneButton(
                    icon: AppIcon.delete,
                    tooltip: 'Remove Chapter'.tr,
                    onPressed: c.chapters.selected == null ? null : c.chapters.remove,
                  ),
                ]),
              ),
              child: Text('Chapters'.tr, style: TextStyle(fontWeight: FontWeight.w500)),
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
                    painter: _ChapterLanePainter(this, colors, AppStyle.of(context).rounded, Listenable.merge([c, c.viewport])),
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

/// The chapters as the lanes' regions are drawn, each rounded where it starts and square
/// where the next takes over; the selected one filled.
class _ChapterLanePainter extends CustomPainter {
  _ChapterLanePainter(this.s, this.colors, this.rounded, Listenable repaint) : super(repaint: repaint);
  final _ChapterLaneState s;
  final AppColors colors;
  final bool rounded;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final c = s.c;
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.accentWash);
    paintBarGrid(canvas, size, c, colors);
    final selected = c.chapters.selected, chapters = s.chapters;
    final round = Radius.circular(rounded ? 4 : 0);
    for (final span in s._spans) {
      final x0 = c.viewport.x(span.start), x1 = c.viewport.x(span.end) - 1;
      if (x1 < 0 || x0 > size.width || span.chapter < 0 || span.chapter >= chapters.length) continue;
      final on = span.chapter == selected;
      final rect = RRect.fromLTRBAndCorners(x0, 4, math.max(x0 + 2, x1), size.height - 5, topLeft: round, bottomLeft: round);
      canvas.drawRRect(rect, Paint()..color = on ? colors.accent : colors.surface);
      canvas.drawRRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = on ? 1.5 : 1
          ..color = on ? colors.accentStrong : colors.textMuted.withValues(alpha: 0.5),
      );
      if (x1 - x0 < 16) continue;
      // Kept in view while its chapter is: the name stays readable scrolled past its start.
      // Its width in whole steps then, so a scroll finds the same one laid out.
      final left = math.max(x0, 0.0), room = x1 - left - 12;
      final width = (x0 < 0 ? (room / 16).floorToDouble() * 16 : room.floorToDouble()).clamp(0.0, 400.0).toDouble();
      if (width < 8) continue;
      final text = s._label(chapters[span.chapter].name, width, on ? colors.surface : colors.text);
      text.paint(canvas, Offset(left + 6, rect.center.dy - text.height / 2));
    }
  }

  @override
  bool shouldRepaint(_ChapterLanePainter old) => true;
}
