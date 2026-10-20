import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'ui_kit.dart';
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
/// ticks, and the playhead. Click or drag to move the playhead. Where the staves shown don't
/// fit the video's frame it is red, and a warning by its name says at which bars.
class BarRuler extends StatelessWidget {
  const BarRuler({super.key, required this.controller});
  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final colors = context.colors;
    final warn = Theme.of(context).colorScheme.error;
    return SizedBox(
      height: kRulerHeight,
      child: Row(children: [
        Container(
          width: kLaneHeaderWidth,
          padding: const EdgeInsets.only(left: 12, right: 8),
          decoration: BoxDecoration(
            color: colors.chrome,
            border: Border(bottom: BorderSide(color: colors.line), right: BorderSide(color: colors.line)),
          ),
          child: Row(children: [
            Text('Bar', style: TextStyle(fontSize: 11, color: colors.textMuted)),
            const Spacer(),
            Select(
              listenable: Listenable.merge([c, c.curation]),
              select: () => overflowBars(c),
              equals: listEquals,
              builder: (context, bars) => bars == null
                  ? const SizedBox.shrink()
                  : Tip(
                      message: 'Staves overflow the video frame: ${bars.join(', ')}',
                      child: Icon(AppIcon.warning.of(context), size: 14, color: warn),
                    ),
            ),
          ]),
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
                painter: _RulerPainter(c, colors, warn),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _RulerPainter extends CustomPainter {
  _RulerPainter(this.c, this.colors, this.warn) : super(repaint: Listenable.merge([c.viewport, c, c.curation]));
  final EditorController c;
  final AppColors colors;

  /// Where the staves overflow the video's frame.
  final Color warn;

  @override
  void paint(Canvas canvas, Size size) {
    if (c.score == null) return;
    final v = c.viewport, tl = c.timeline;
    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.chrome);
    canvas.drawLine(Offset(0, size.height - 0.5), Offset(size.width, size.height - 0.5), Paint()..color = colors.line);
    for (final o in c.overflowing) {
      final x0 = math.max(v.x(o.start), -1.0), x1 = math.min(v.x(o.end), size.width + 1);
      if (x1 <= x0) continue;
      canvas
        ..drawRect(Rect.fromLTRB(x0, 0, x1, size.height), Paint()..color = warn.withValues(alpha: 0.18))
        ..drawRect(Rect.fromLTRB(x0, size.height - 2, x1, size.height), Paint()..color = warn);
    }

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

/// The bars where the staves shown overflow the video's frame ([EditorController.overflowing]),
/// as runs ("12–18", or "30" alone), each pass its own; null where they all fit.
List<String>? overflowBars(EditorController c) {
  final stretches = c.overflowing;
  if (stretches.isEmpty || c.score == null) return null;
  final tl = c.timeline, end = tl.endSeconds, lastBar = tl.measureStarts.length - 2;
  int bar(double seconds) => c.beats.measureAt(tl.quarterAtSeconds(seconds)).clamp(0, lastBar) + 1;
  final runs = <String>[];
  for (final o in stretches) {
    final from = math.max(o.start, 0.0), to = math.min(o.end, end);
    if (to - from <= 1e-6) continue;
    // A warp jumps elsewhere in the score: the bars of each pass are a run of their own.
    for (var k = tl.passAt(from); k <= tl.passAt(to - 1e-6); k++) {
      final p = tl.passes[k];
      final lo = math.max(from, tl.secondsAtQuarter(p.start, pass: k));
      final hi = math.min(to, tl.secondsAtQuarter(p.end, pass: k));
      if (hi - lo <= 1e-6) continue;
      final (a, b) = (bar(lo), bar(hi - 1e-6));
      runs.add(a == b ? '$a' : '$a–$b');
    }
  }
  return runs.isEmpty ? null : runs;
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

/// [quarter] snapped as the lanes snap: to the time signature's nearest beat, or the nearest
/// barline when beats are too close together on screen (as they sound in [pass]); ⌘: free.
/// Inside the score.
double snapInLanes(EditorController c, double quarter, {required int pass}) {
  final starts = c.timeline.measureStarts;
  final q = quarter.clamp(0.0, starts.last).toDouble();
  if (isCommandPressed) return q;
  if (beatsFit(c, q, pass: pass)) {
    final beat = c.beats.beatAt(q);
    return q - beat.start <= beat.end - q ? beat.start : beat.end;
  }
  var i = c.beats.measureAt(q);
  if (i + 1 < starts.length && (starts[i + 1] - q) < (q - starts[i])) i++;
  return starts[i];
}

/// What a click in the lanes takes: the beat at [quarter] as it sounds in [pass], or its bar
/// when beats are too close together on screen (a dotted crotchet in 6/8).
({double start, double end}) beatInLanes(EditorController c, double quarter, {required int pass}) {
  final starts = c.timeline.measureStarts;
  final q = quarter.clamp(0.0, starts.last - 1e-9).toDouble();
  if (beatsFit(c, q, pass: pass)) return c.beats.beatAt(q);
  final m = c.beats.measureAt(q);
  return (start: starts[m], end: starts[math.min(m + 1, starts.length - 1)]);
}

/// Tells a double-click from two clicks: a second press within [interval] of the first and
/// [slop] pixels of where it was. A double-click starts the count again, so a third press is a
/// first one.
class DoubleClicks {
  static const interval = Duration(milliseconds: 350), slop = 6.0;

  Duration? _last;
  Offset _at = Offset.zero;

  /// Counts a press at [time] (the pointer event's `timeStamp`) and [position]: whether it is a
  /// double-click's second.
  bool press(Duration time, Offset position) {
    final last = _last;
    final second = last != null && time - last < interval && (position - _at).distance < slop;
    _last = second ? null : time;
    _at = position;
    return second;
  }
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

/// A lane's name cell in the left column: on the [AppColors.chrome] (in the refined style a
/// column apart from the lanes, as a desktop editor's track headers are), [color] over it.
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
        duration: stateDuration(motion(context, 120)),
        height: height,
        padding: const EdgeInsets.only(left: 12),
        decoration: BoxDecoration(
          color: Color.alphaBlend(color ?? Colors.transparent, colors.chrome),
          border: Border(right: BorderSide(color: colors.line), bottom: BorderSide(color: colors.line)),
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
