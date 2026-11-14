import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart';

import '../app_colors.dart';
import '../app_icons.dart';
import '../editor_controller.dart';
import '../lanes_common.dart';
import '../span_lane.dart';

/// A lane of an extension's (a `lane` node of its connector), pinned under the bar ruler in
/// both tabs. The app draws it and takes the mouse, as it does for its own lanes; the
/// extension says what is in it (`items`) and what a gesture does (`add`, `move`, `erase`,
/// `open`, `remove`). Its name carries the extension's commands for it as buttons.
///
/// Markers: each item wherever its music sounds ([markerSpans]), from where it starts to
/// where the next does. Edited with the Instruments tab's tool (the Audio tab selects).
/// Select: click one to select it (Delete removes it), drag it to move where it starts, never
/// past those either side, double-click it to open it; a click before the first moves the
/// playhead. Draw: click for a new one from the beat there. Erase: click one. ⌥ swaps the
/// tools, as in the lanes; a start snaps to beats (bars zoomed out), ⌘ places freely.
class ExtensionLane extends StatefulWidget {
  ExtensionLane({required this.controller, required this.runtime, required this.node}) : super(key: ValueKey('lane ${runtime.id} ${node.id}'));
  final EditorController controller;
  final ExtensionRuntime runtime;
  final GraphNode node;

  static const height = SpanLane.height;

  @override
  State<ExtensionLane> createState() => _ExtensionLaneState();
}

class _Drag {
  _Drag({required this.index, required this.downAt, required this.downQ, required this.pass, required this.from});

  /// The item held; null: the playhead (a press where no item is).
  final int? index;
  final Offset downAt;
  final double downQ;
  final int pass;

  /// Where the item started.
  final double from;
  bool moved = false;
}

class _ExtensionLaneState extends State<ExtensionLane> with LaneCursor<ExtensionLane> {
  EditorController get c => widget.controller;
  ExtensionRuntime get runtime => widget.runtime;
  String get lane => widget.node.id;
  ScoreTimeline get tl => c.timeline;
  List<LaneItem> get items => c.extensions.items(runtime, widget.node);

  /// The least two items are apart, in score quarters.
  double get _gap => switch (widget.node.props['gap']) { final num n when n > 0 => n.toDouble(), _ => 0.25 };

  _Drag? _drag;

  /// Where the Draw tool was pressed: a new item's start, the extension's once let go.
  double? _drawAt;
  final _clicks = DoubleClicks();

  /// Labels as laid out in the lane, kept: playback repaints it every frame.
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

  /// The items in time, the last to the end of what plays.
  List<MarkerSpan> get _spans => c.extensions.spans(runtime, widget.node, end: math.max(tl.endSeconds, c.playback.duration));

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

  /// The item sounding under [x] (an index into the items).
  int? _hit(double x) {
    final seconds = c.viewport.seconds(x);
    for (final s in _spans) {
      if (seconds >= s.start && seconds < s.end) return s.marker < 0 ? null : s.marker;
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
        if (hit != null) runtime.fire(lane, 'erase', args: [hit + 1]);
      case LaneTool.select:
        if (hit == null) {
          _drag = _Drag(index: null, downAt: p, downQ: q, pass: pass, from: 0);
          c.playback.scrub(c.viewport.seconds(p.dx));
          return;
        }
        c.extensions.select(runtime.id, lane, hit);
        if (doubleClick) {
          runtime.fire(lane, 'open', args: [hit + 1]);
          return;
        }
        c.beginEdit();
        _drag = _Drag(index: hit, downAt: p, downQ: q, pass: pass, from: items[hit].at);
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
    final items = this.items;
    if (!drag.moved || i >= items.length) return;
    // Never past the items either side: which is which stays.
    final apart = _gap;
    final lo = i == 0 ? 0.0 : items[i - 1].at + apart;
    final hi = (i + 1 < items.length ? items[i + 1].at : tl.measureStarts.last) - apart;
    if (hi < lo) return;
    final at = snapInLanes(c, drag.from + _q(p.dx, pass: drag.pass) - drag.downQ, pass: drag.pass).clamp(lo, hi).toDouble();
    if (at != items[i].at) runtime.fire(lane, 'move', args: [i + 1, at]);
  }

  void _onUp(PointerEvent e) {
    final drag = _drag, drawAt = _drawAt;
    _drag = null;
    _drawAt = null;
    if (drawAt != null && e is PointerUpEvent) runtime.fire(lane, 'add', args: [drawAt]);
    if (drag == null) return;
    if (drag.index == null) return c.playback.endScrub();
    c.endEdit();
    showCursor(e is PointerCancelEvent ? SystemMouseCursors.basic : cursorAt(e.localPosition));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      height: ExtensionLane.height,
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: kLaneHeaderWidth,
          child: ListenableBuilder(
            listenable: c,
            builder: (context, _) => LaneLabel(
              height: ExtensionLane.height,
              color: colors.accentWash,
              trailing: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  for (final command in c.extensions.commands(runtime, lane: lane))
                    LaneButton(
                      icon: extensionIcon(command.props['icon']),
                      tooltip: runtime.translate(_text(command.props['title'])),
                      onPressed: c.extensions.canRun(runtime, command) ? () => runtime.fire(command.id, 'run') : null,
                    ),
                ]),
              ),
              child: Text(runtime.translate(_text(widget.node.props['title'])), style: TextStyle(fontWeight: FontWeight.w500)),
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
                    painter: _MarkersPainter(this, colors, AppStyle.of(context).rounded, Listenable.merge([c, c.viewport])),
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

String _text(Object? value) => value is String ? value : '';

/// The icon a connector names ([ExtensionApi.icons]); one it doesn't know is the extensions'.
AppIcon extensionIcon(Object? name) => _icons[name] ?? AppIcon.extensions;
final _icons = AppIcon.values.asNameMap();

/// The items as the lanes' regions are drawn, each rounded where it starts and square where
/// the next takes over; the selected one filled.
class _MarkersPainter extends CustomPainter {
  _MarkersPainter(this.s, this.colors, this.rounded, Listenable repaint) : super(repaint: repaint);
  final _ExtensionLaneState s;
  final AppColors colors;
  final bool rounded;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final c = s.c;
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.accentWash);
    paintBarGrid(canvas, size, c, colors);
    final selected = c.extensions.selectedIn(s.runtime.id, s.lane), items = s.items;
    final round = Radius.circular(rounded ? 4 : 0);
    for (final span in s._spans) {
      final x0 = c.viewport.x(span.start), x1 = c.viewport.x(span.end) - 1;
      if (x1 < 0 || x0 > size.width || span.marker < 0 || span.marker >= items.length) continue;
      final on = span.marker == selected;
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
      // Kept in view while its item is: the name stays readable scrolled past its start.
      // Its width in whole steps then, so a scroll finds the same one laid out.
      final left = math.max(x0, 0.0), room = x1 - left - 12;
      final width = (x0 < 0 ? (room / 16).floorToDouble() * 16 : room.floorToDouble()).clamp(0.0, 400.0).toDouble();
      if (width < 8) continue;
      final text = s._label(items[span.marker].label, width, on ? colors.surface : colors.text);
      text.paint(canvas, Offset(left + 6, rect.center.dy - text.height / 2));
    }
  }

  @override
  bool shouldRepaint(_MarkersPainter old) => true;
}
