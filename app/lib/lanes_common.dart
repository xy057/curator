import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'editor_controller.dart';

/// Width of the name column on the left of every lane (both tabs, so time lines up).
const kLaneHeaderWidth = 176.0;
const kRulerHeight = 26.0;

/// The platform's command key is held: ⌘ on macOS, Ctrl on Windows and Linux. It toggles
/// selections, places freely instead of snapping, and adds to box selections.
bool get isCommandPressed {
  final keys = HardwareKeyboard.instance;
  return defaultTargetPlatform == TargetPlatform.macOS ? keys.isMetaPressed : keys.isControlPressed;
}

/// Whether scrolling zooms the lanes' time axis instead: ⌘ on macOS, Ctrl elsewhere (either
/// on a Mac, where a Ctrl-scroll is otherwise unused).
bool get isZoomModifierPressed {
  final keys = HardwareKeyboard.instance;
  return keys.isMetaPressed || keys.isControlPressed;
}

/// Trackpad / wheel navigation for the lanes: two-finger swipe or shift-scroll pans,
/// pinch or ⌘-scroll (wheel or two-finger swipe) zooms around the pointer. Zooming is
/// horizontal only: lanes that scroll vertically lock while ⌘ is held.
class ViewportGestures extends StatefulWidget {
  const ViewportGestures({super.key, required this.controller, required this.child});
  final EditorController controller;
  final Widget child;

  @override
  State<ViewportGestures> createState() => _ViewportGesturesState();
}

class _ViewportGesturesState extends State<ViewportGestures> {
  double _lastScale = 1;

  @override
  Widget build(BuildContext context) {
    final v = widget.controller.viewport;
    return Listener(
      onPointerSignal: (e) {
        if (e is! PointerScrollEvent) return;
        final keys = HardwareKeyboard.instance;
        if (isZoomModifierPressed) {
          v.zoom(math.exp(-e.scrollDelta.dy / 300), e.localPosition.dx - kLaneHeaderWidth);
        } else if (keys.isShiftPressed || e.scrollDelta.dx != 0) {
          v.pan(keys.isShiftPressed ? e.scrollDelta.dy : e.scrollDelta.dx);
        }
      },
      onPointerPanZoomStart: (_) => _lastScale = 1,
      onPointerPanZoomUpdate: (e) {
        if (e.scale != _lastScale) {
          v.zoom(e.scale / _lastScale, e.localPosition.dx - kLaneHeaderWidth);
          _lastScale = e.scale;
        }
        if (isZoomModifierPressed) {
          // ⌘ + two-finger swipe zooms like ⌘-scroll (swiping up = scrolling up = zoom in).
          if (e.localPanDelta.dy != 0) v.zoom(math.exp(e.localPanDelta.dy / 300), e.localPosition.dx - kLaneHeaderWidth);
        } else if (e.localPanDelta.dx != 0) {
          v.pan(-e.localPanDelta.dx);
        }
      },
      child: widget.child,
    );
  }
}

/// Bar numbers at the times they sound (so a tempo change is visible as uneven bars), time
/// ticks, and the playhead. Click or drag to move the playhead.
class BarRuler extends StatelessWidget {
  const BarRuler({super.key, required this.controller});
  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final colors = context.colors;
    return SizedBox(
      height: kRulerHeight,
      child: Row(children: [
        Container(
          width: kLaneHeaderWidth,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: colors.line), right: BorderSide(color: colors.line)),
          ),
          child: Text('Bar', style: TextStyle(fontSize: 11, color: colors.textMuted)),
        ),
        Expanded(
          child: Listener(
            onPointerDown: (e) {
              c.clearSelection();
              c.playback.seek(c.viewport.seconds(e.localPosition.dx));
            },
            onPointerMove: (e) => c.playback.seek(c.viewport.seconds(e.localPosition.dx)),
            child: CustomPaint(
              size: Size.infinite,
              painter: _RulerPainter(c, colors),
            ),
          ),
        ),
      ]),
    );
  }
}

class _RulerPainter extends CustomPainter {
  _RulerPainter(this.c, this.colors) : super(repaint: Listenable.merge([c.playback.time, c.viewport, c]));
  final EditorController c;
  final AppColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    if (c.score == null) return;
    final v = c.viewport, tl = c.timeline;
    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.surface);
    canvas.drawLine(Offset(0, size.height - 0.5), Offset(size.width, size.height - 0.5), Paint()..color = colors.line);

    final starts = tl.measureStarts;
    final tick = Paint()..color = colors.activity;
    var lastLabel = double.negativeInfinity;
    for (var i = 0; i < starts.length; i++) {
      final x = v.x(tl.secondsAtQuarter(starts[i]));
      if (x < -40 || x > size.width + 40) continue;
      final labelled = x - lastLabel >= 30 && i < starts.length - 1;
      canvas.drawLine(Offset(x, labelled ? 8 : 17), Offset(x, size.height), tick);
      if (labelled) {
        lastLabel = x;
        final tp = TextPainter(
          text: TextSpan(text: '${i + 1}', style: TextStyle(fontSize: 11, color: colors.textMuted)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp
          ..paint(canvas, Offset(x + 4, 3))
          ..dispose();
      }
    }
    paintPlayhead(canvas, size, c, colors, handle: true);
  }

  @override
  bool shouldRepaint(_RulerPainter old) => true;
}

/// The playhead line (and a handle at the bottom of the ruler).
void paintPlayhead(Canvas canvas, Size size, EditorController c, AppColors colors, {bool handle = false}) {
  final px = c.viewport.x(c.playback.time.value);
  if (handle) {
    final path = Path()
      ..moveTo(px - 6, size.height - 9)
      ..lineTo(px + 6, size.height - 9)
      ..lineTo(px, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = colors.accentStrong);
  } else {
    canvas.drawRect(Rect.fromLTWH(px - 0.75, 0, 1.5, size.height), Paint()..color = colors.accentStrong);
  }
}

/// Beats narrower than this (on screen) are too fine to draw, snap to or click one by one.
const kMinBeatWidth = 14.0;

/// Whether the beat at [quarter] is wide enough on screen to work beat by beat.
bool beatsFit(EditorController c, double quarter) {
  final beat = c.beats.beatAt(quarter);
  final tl = c.timeline;
  return (tl.secondsAtQuarter(beat.end) - tl.secondsAtQuarter(beat.start)) * c.viewport.pxPerSec >= kMinBeatWidth;
}

/// Faint bar lines (and the time signature's beats when there is room) at their synced times.
void paintBarGrid(Canvas canvas, Size size, EditorController c, AppColors colors) {
  final v = c.viewport, tl = c.timeline;
  final starts = tl.measureStarts;
  final grid = Paint()..color = colors.grid;
  final beat = Paint()..color = colors.grid.withValues(alpha: 0.5);
  for (var m = 0; m < starts.length; m++) {
    final x = v.x(tl.secondsAtQuarter(starts[m]));
    if (x >= -1 && x <= size.width + 1) canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    if (m + 1 >= starts.length || x > size.width) continue;
    if (v.x(tl.secondsAtQuarter(starts[m + 1])) < 0 || !beatsFit(c, starts[m])) continue;
    for (final q in c.beats.beatsIn(m).skip(1)) {
      final bx = v.x(tl.secondsAtQuarter(q));
      if (bx >= 0 && bx <= size.width) canvas.drawLine(Offset(bx, 0), Offset(bx, size.height), beat);
    }
  }
}

/// A lane's name cell in the left column.
class LaneLabel extends StatelessWidget {
  const LaneLabel({super.key, required this.height, required this.child, this.trailing, this.color});
  final double height;
  final Widget child;
  final Widget? trailing;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
        height: height,
        padding: const EdgeInsets.only(left: 12),
        decoration: BoxDecoration(
          color: color,
          border: Border(right: BorderSide(color: colors.line), bottom: BorderSide(color: colors.grid)),
        ),
        child: Row(children: [
          Expanded(
            child: DefaultTextStyle(
              style: TextStyle(fontSize: 12.5, color: colors.text),
              overflow: TextOverflow.ellipsis,
              child: child,
            ),
          ),
          ?trailing,
        ]),
      );
  }
}
