import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

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
            // The primary button only, as in the lanes: a right-click leaves the playhead be.
            onPointerDown: (e) {
              if (e.buttons != kPrimaryButton) return;
              c.clearSelection();
              c.playback.scrub(c.viewport.seconds(e.localPosition.dx));
            },
            onPointerMove: (e) {
              if (e.buttons == kPrimaryButton) c.playback.scrub(c.viewport.seconds(e.localPosition.dx));
            },
            onPointerUp: (_) => c.playback.endScrub(),
            onPointerCancel: (_) => c.playback.endScrub(),
            child: WithPlayhead(
              controller: c,
              handle: true,
              child: CustomPaint(
                size: Size.infinite,
                painter: _RulerPainter(c, colors),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _RulerPainter extends CustomPainter {
  _RulerPainter(this.c, this.colors) : super(repaint: Listenable.merge([c.viewport, c]));
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
    final jump = Paint()..color = colors.accentStrong;
    var lastLabel = double.negativeInfinity;
    // Bar by bar through each pass: after a warp the numbers start again where it jumps to.
    for (final (k, bars) in _barsByPass(tl).indexed) {
      for (final (j, i) in bars.indexed) {
        final x = v.x(tl.secondsAtQuarter(starts[i], pass: k));
        if (x < -40 || x > size.width + 40) continue;
        final warped = k > 0 && j == 0 && (starts[i] - tl.passes[k].start).abs() < 1e-9;
        final labelled = (warped || x - lastLabel >= 30) && i < starts.length - 1;
        canvas.drawLine(Offset(x, labelled ? 8 : 17), Offset(x, size.height), warped ? jump : tick);
        if (labelled) {
          lastLabel = x;
          final tp = TextPainter(
            text: TextSpan(
                text: '${i + 1}', style: TextStyle(fontSize: 11, color: warped ? colors.accentStrong : colors.textMuted)),
            textDirection: TextDirection.ltr,
          )..layout();
          tp
            ..paint(canvas, Offset(x + 4, 3))
            ..dispose();
        }
      }
    }
  }

  @override
  bool shouldRepaint(_RulerPainter old) => true;
}

/// [child] (a lane's painting) with the playhead over it, on a layer of its own: playback
/// moves the playhead every frame and repaints only it, never the lanes under it.
class WithPlayhead extends StatelessWidget {
  const WithPlayhead({super.key, required this.controller, required this.child, this.handle = false});
  final EditorController controller;
  final Widget child;

  /// The ruler's: a handle at the bottom instead of a line.
  final bool handle;

  @override
  Widget build(BuildContext context) => Stack(fit: StackFit.passthrough, children: [
        RepaintBoundary(child: child),
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(painter: _PlayheadPainter(controller, context.colors, handle: handle)),
            ),
          ),
        ),
      ]);
}

class _PlayheadPainter extends CustomPainter {
  _PlayheadPainter(this.c, this.colors, {required this.handle}) : super(repaint: Listenable.merge([c.playback.time, c.viewport]));
  final EditorController c;
  final AppColors colors;
  final bool handle;

  @override
  void paint(Canvas canvas, Size size) {
    if (c.score == null) return;
    canvas.clipRect(Offset.zero & size);
    _paintPlayhead(canvas, size, c, colors, handle: handle);
  }

  @override
  bool shouldRepaint(_PlayheadPainter old) => old.c != c || old.colors != colors || old.handle != handle;
}

/// The playhead line (and a handle at the bottom of the ruler).
void _paintPlayhead(Canvas canvas, Size size, EditorController c, AppColors colors, {bool handle = false}) {
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

/// Whether the beat at [quarter] is wide enough on screen to work beat by beat (as it
/// sounds in [pass]).
bool beatsFit(EditorController c, double quarter, {int pass = 0}) {
  final beat = c.beats.beatAt(quarter);
  final tl = c.timeline;
  return (tl.secondsAtQuarter(beat.end, pass: pass) - tl.secondsAtQuarter(beat.start, pass: pass)) * c.viewport.pxPerSec >=
      kMinBeatWidth;
}

/// For each pass (see [ScoreTimeline.passes]), the bars whose barline it plays, in order. A
/// pass's end is the next one's start, so only the last pass has the final barline.
List<List<int>> _barsByPass(ScoreTimeline tl) {
  final starts = tl.measureStarts;
  final passes = tl.passes;
  return [
    for (final (k, p) in passes.indexed)
      [
        for (var i = 0; i < starts.length; i++)
          if (starts[i] >= p.start - 1e-9 && (starts[i] < p.end - 1e-9 || (k == passes.length - 1 && starts[i] <= p.end + 1e-9)))
            i,
      ],
  ];
}

/// Faint bar lines (and the time signature's beats when there is room) at their synced times,
/// once in every pass that plays them.
void paintBarGrid(Canvas canvas, Size size, EditorController c, AppColors colors) {
  final v = c.viewport, tl = c.timeline;
  final starts = tl.measureStarts;
  final grid = Paint()..color = colors.grid;
  final beat = Paint()..color = colors.grid.withValues(alpha: 0.5);
  final passes = tl.passes;
  for (final (k, p) in passes.indexed) {
    double x(double q) => v.x(tl.secondsAtQuarter(q, pass: k));
    final last = k == passes.length - 1;
    // From the bar the pass starts in (a warp may land mid-bar) to the one it ends in.
    for (var m = c.beats.measureAt(p.start); m < starts.length && (starts[m] < p.end - 1e-9 || last); m++) {
      final bx = x(starts[m]);
      if (bx > size.width + 1) break;
      if (starts[m] >= p.start - 1e-9 && bx >= -1) canvas.drawLine(Offset(bx, 0), Offset(bx, size.height), grid);
      if (m + 1 >= starts.length || x(starts[m + 1]) < 0 || !beatsFit(c, starts[m], pass: k)) continue;
      for (final q in c.beats.beatsIn(m).skip(1)) {
        if (q <= p.start + 1e-9 || q >= p.end - 1e-9) continue;
        final qx = x(q);
        if (qx >= 0 && qx <= size.width) canvas.drawLine(Offset(qx, 0), Offset(qx, size.height), beat);
      }
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
    return AnimatedContainer(
        duration: const Duration(milliseconds: 120),
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
