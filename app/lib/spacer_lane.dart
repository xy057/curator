import 'package:flutter/gestures.dart' show PointerHoverEvent, kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:score_engine/score_engine.dart' show ScoreTimeline;

import 'app_colors.dart';
import 'app_icons.dart';
import 'editor_controller.dart';
import 'lanes_common.dart';
import 'spacer_dialogs.dart';
import 'ui_kit.dart';

/// The Spacers lane (Attach Image): pinned under the bar ruler in both tabs. Its name's buttons
/// add a vertical spacer (below the lowest lane selected, else at the bottom: a lane of its own
/// in the Instruments tab), add a horizontal one at the beat the playhead is in, and remove the
/// spacer selected (or the spacers' lanes selected). Each horizontal spacer is a mark in it:
/// click selects it (Delete removes it), drag moves it to another beat (⌘: anywhere),
/// double-click sets its width; a click on empty space moves the playhead.
class SpacerLane extends StatefulWidget {
  const SpacerLane({super.key, required this.controller});
  final EditorController controller;

  static const height = 26.0;

  @override
  State<SpacerLane> createState() => _SpacerLaneState();
}

/// A press in the lane: on mark [index] (null: on empty space, scrubbing), in [pass].
class _Drag {
  _Drag(this.index, this.downAt, this.pass);
  final int? index;
  final Offset downAt;
  final int pass;
  bool moved = false;
}

class _SpacerLaneState extends State<SpacerLane> {
  EditorController get c => widget.controller;
  ScoreTimeline get tl => c.timeline;

  _Drag? _drag;

  /// Where the mark being dragged would go (score quarters).
  final _ghost = ValueNotifier<double?>(null);
  MouseCursor _cursor = SystemMouseCursors.basic;
  final _clicks = DoubleClicks();

  static const _markWidth = 10.0;

  @override
  void dispose() {
    _ghost.dispose();
    super.dispose();
  }

  /// Where score quarter [q] is drawn: once in every pass that plays it.
  Iterable<double> _xs(double q) sync* {
    for (final (i, p) in tl.passes.indexed) {
      if (q >= p.start - 1e-9 && q < p.end - 1e-9) yield c.viewport.x(tl.secondsAtQuarter(q, pass: i));
    }
  }

  /// The mark under [x] (an index into [SpacerEditing.horizontal]).
  int? _hit(double x) {
    for (final (i, _) in c.spacers.horizontal.indexed) {
      for (final mx in _xs(c.spacers.quarterOf(i))) {
        if ((x - mx).abs() <= _markWidth / 2 + 2) return i;
      }
    }
    return null;
  }

  double _q(double x, {int? pass}) {
    final seconds = c.viewport.seconds(x);
    final here = tl.passAt(seconds);
    if (pass == null || here == pass) return tl.quarterAtSeconds(seconds);
    return here < pass ? tl.passes[pass].start : tl.passes[pass].end;
  }

  void _onHover(PointerHoverEvent e) {
    final cursor = _hit(e.localPosition.dx) != null ? SystemMouseCursors.grab : SystemMouseCursors.basic;
    if (cursor != _cursor) setState(() => _cursor = cursor);
  }

  void _onDown(PointerDownEvent e) {
    if (e.buttons != kPrimaryButton) return;
    final p = e.localPosition, pass = tl.passAt(c.viewport.seconds(p.dx));
    final doubleClick = _clicks.press(e.timeStamp, p);
    final hit = _hit(p.dx);
    if (hit == null) {
      c.clearSelection();
      _drag = _Drag(null, p, pass);
      c.playback.scrub(c.viewport.seconds(p.dx));
      return;
    }
    c.spacers.selectHorizontal(hit);
    if (doubleClick) {
      showHorizontalSpacerDialog(context, c, hit);
      return;
    }
    _drag = _Drag(hit, p, pass);
    setState(() => _cursor = SystemMouseCursors.grabbing);
  }

  void _onMove(PointerMoveEvent e) {
    final drag = _drag;
    if (drag == null) return;
    final p = e.localPosition;
    if (drag.index == null) return c.playback.scrub(c.viewport.seconds(p.dx));
    drag.moved |= (p - drag.downAt).distance >= 3;
    if (!drag.moved) return;
    final from = c.spacers.quarterOf(drag.index!);
    final q = from + _q(p.dx, pass: drag.pass) - _q(drag.downAt.dx, pass: drag.pass);
    _ghost.value = snapInLanes(c, q, pass: drag.pass).clamp(0.0, tl.measureStarts.last - 1e-6);
  }

  void _onUp(PointerEvent e, {bool cancelled = false}) {
    final drag = _drag, ghost = _ghost.value;
    _drag = null;
    _ghost.value = null;
    if (drag == null) return;
    if (drag.index == null) return c.playback.endScrub();
    setState(() => _cursor = SystemMouseCursors.grab);
    if (!cancelled && drag.moved && ghost != null) c.spacers.moveHorizontal(drag.index!, ghost);
  }

  /// A vertical spacer below the lowest lane selected, else at the bottom.
  void _addVertical() {
    final selected = c.lanes.selectedPartIds;
    final below = c.laneParts.lastWhere((p) => selected.contains(p.id), orElse: () => c.laneParts.last);
    c.spacers.addVertical(below: selected.isEmpty ? null : below.id);
  }

  /// A horizontal spacer at the beat the playhead is in.
  void _addHorizontal() {
    final seconds = c.playback.time.value;
    final q = tl.quarterAtSeconds(seconds).clamp(0.0, tl.measureStarts.last - 1e-6);
    c.spacers.addHorizontal(beatInLanes(c, q, pass: tl.passAt(seconds)).start);
  }

  /// The spacers' lanes selected, when no spacer is.
  List<String> get _selectedLanes => [for (final id in c.lanes.selectedPartIds) if (c.spacers.verticalOf(id) != null) id];

  void _remove() {
    if (c.spacers.hasSelection) {
      c.spacers.removeSelected();
    } else {
      c.spacers.removeVerticals(_selectedLanes);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      height: SpacerLane.height,
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: kLaneHeaderWidth,
          child: ListenableBuilder(
            listenable: c,
            builder: (context, _) => LaneLabel(
              height: SpacerLane.height,
              color: colors.accentWash,
              trailing: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  _LaneButton(icon: AppIcon.verticalSpacer, tooltip: 'Add Vertical Spacer', onPressed: _addVertical),
                  _LaneButton(icon: AppIcon.horizontalSpacer, tooltip: 'Add Horizontal Spacer', onPressed: _addHorizontal),
                  _LaneButton(
                    icon: AppIcon.delete,
                    tooltip: 'Remove Spacer',
                    onPressed: c.spacers.hasSelection || _selectedLanes.isNotEmpty ? _remove : null,
                  ),
                ]),
              ),
              child: const Text('Spacers', style: TextStyle(fontWeight: FontWeight.w500)),
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
              onPointerCancel: (e) => _onUp(e, cancelled: true),
              child: DecoratedBox(
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: colors.line))),
                child: WithPlayhead(
                  controller: c,
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: _SpacerLanePainter(this, colors, Listenable.merge([c, c.viewport, _ghost])),
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

/// A small button in a lane's name.
class _LaneButton extends StatelessWidget {
  const _LaneButton({required this.icon, required this.tooltip, required this.onPressed});
  final AppIcon icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => OverlaySemantics(
        child: IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          iconSize: 14,
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 22, height: 22),
          color: context.colors.textMuted,
          style: IconButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: AppStyle.of(context).radius(5))),
          icon: Icon(icon.of(context)),
        ),
      );
}

/// Each horizontal spacer as a mark at its beat, the selected one filled; a dragged one's new
/// place outlined.
class _SpacerLanePainter extends CustomPainter {
  _SpacerLanePainter(this.s, this.colors, Listenable repaint) : super(repaint: repaint);
  final _SpacerLaneState s;
  final AppColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final c = s.c;
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.accentWash);
    paintBarGrid(canvas, size, c, colors);
    final selected = c.spacers.selectedHorizontal;
    const w = _SpacerLaneState._markWidth;
    RRect mark(double x) => RRect.fromLTRBR(x - w / 2, 4, x + w / 2, size.height - 5, const Radius.circular(3));
    for (final (i, _) in c.spacers.horizontal.indexed) {
      final on = i == selected;
      for (final x in s._xs(c.spacers.quarterOf(i))) {
        if (x < -w || x > size.width + w) continue;
        canvas
          ..drawRRect(mark(x), Paint()..color = on ? colors.accent : colors.surface)
          ..drawRRect(
              mark(x),
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = on ? 1.5 : 1
                ..color = on ? colors.accentStrong : colors.textMuted.withValues(alpha: 0.6));
      }
    }
    if (s._ghost.value case final q?) {
      for (final x in s._xs(q)) {
        canvas.drawRRect(
            mark(x),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5
              ..color = colors.accentStrong);
      }
    }
  }

  @override
  bool shouldRepaint(_SpacerLanePainter old) => true;
}
