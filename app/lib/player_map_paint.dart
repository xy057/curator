import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:score_engine/score_engine.dart';

/// The stage a map is drawn on, as big as fits [size] at the map's aspect ratio, centred:
/// a map's places (0–1 across and down) ↔ points.
@immutable
class MapStage {
  MapStage(Size size, double aspect, {double inset = 0}) : rect = _fit(size, aspect, inset);

  static Rect _fit(Size size, double aspect, double inset) {
    final w = math.max(0.0, size.width - 2 * inset), h = math.max(0.0, size.height - 2 * inset);
    final width = math.min(w, h * aspect), height = width / aspect;
    return Rect.fromLTWH((size.width - width) / 2, (size.height - height) / 2, width, height);
  }

  final Rect rect;

  Offset toView(double x, double y) => Offset(rect.left + x * rect.width, rect.top + y * rect.height);
  ({double x, double y}) toMap(Offset p) => (x: (p.dx - rect.left) / rect.width, y: (p.dy - rect.top) / rect.height);

  /// A dot's radius at rest, for a section of dots [size] across.
  double radius(double size) => size * rect.height / 2;

  /// A section's name's height in points.
  double get labelSize => PlayerMap.labelSize * rect.height;
}

/// The stage's colours: a dark floor whatever the theme, as a concert's lights leave it.
const _floor = Color(0xFF0D0D0F), _floorEdge = Color(0xFF26262B);

/// How big a player swells at a note's start, over its size at rest: a nudge, not a jump.
const _swell = 0.35;

/// A [PlayerMap] at a time: each player a dot in its section's colour, dim at rest; each note its
/// instrument plays makes it swell and light up, fading as [PlayerPulses] says (a short note
/// quickly, a long one slowly). Repaints as [time] moves.
class PlayerMapPainter extends CustomPainter {
  PlayerMapPainter({
    required this.map,
    required this.pulses,
    required this.time,
    this.selected,
    this.selectedSeat,
    this.accent = const Color(0xFF4C8DFF),
    this.textDirection = TextDirection.ltr,
  }) : super(repaint: time);

  final PlayerMap map;
  final PlayerPulses pulses;
  final ValueListenable<double> time;

  /// The section selected (its index), and one of its seats, outlined (the editor's).
  final int? selected, selectedSeat;
  final Color accent;
  final TextDirection textDirection;

  final _labels = <(String, int, double), TextPainter>{};

  TextPainter _label(String name, int color, double size) => _labels.putIfAbsent((name, color, size), () {
        return TextPainter(
          text: TextSpan(text: name, style: TextStyle(color: Color(color).withValues(alpha: 0.85), fontSize: size, fontWeight: FontWeight.w500)),
          textDirection: textDirection,
          maxLines: 1,
        )..layout();
      });

  @override
  void paint(Canvas canvas, Size size) {
    final stage = MapStage(size, map.aspect);
    final floor = RRect.fromRectAndRadius(stage.rect, const Radius.circular(6));
    canvas.drawRRect(floor, Paint()..color = _floor);
    canvas.drawRRect(floor, Paint()
      ..color = _floorEdge
      ..style = PaintingStyle.stroke);
    canvas.save();
    canvas.clipRRect(floor);
    final t = time.value, labelSize = stage.labelSize;
    final glow = Paint()..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    final dot = Paint();
    for (final (k, section) in map.sections.indexed) {
      final base = Color(section.color), rest = stage.radius(section.size);
      // Each link's level once a frame: a section's players mostly share one.
      final levels = <PlayerLink?, double>{};
      for (final (i, seat) in section.seats.indexed) {
        final link = section.linkOf(i);
        final level = levels[link] ??= pulses.level(link, t);
        final center = stage.toView(seat.x, seat.y), r = rest * (1 + _swell * level);
        if (level > 0.02) canvas.drawCircle(center, r * 1.35, glow..color = base.withValues(alpha: 0.16 * level));
        canvas.drawCircle(center, r, dot..color = Color.lerp(base.withValues(alpha: 0.55), _bright(base), level)!);
        if (k == selected && (selectedSeat == null || selectedSeat == i)) {
          canvas.drawCircle(center, r + 2.5, Paint()
            ..color = accent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
        }
      }
      if (section.name.isNotEmpty && labelSize >= 5) {
        final label = _label(section.name, section.color, labelSize), at = stage.toView(section.labelX, section.labelY);
        label.paint(canvas, at - Offset(label.width / 2, label.height / 2));
        if (k == selected && selectedSeat == null) {
          canvas.drawRect(Rect.fromCenter(center: at, width: label.width + 8, height: label.height + 4), Paint()
            ..color = accent.withValues(alpha: 0.7)
            ..style = PaintingStyle.stroke);
        }
      }
    }
    canvas.restore();
  }

  /// [c] lit: a little lighter, never washed out.
  static Color _bright(Color c) => Color.lerp(c, const Color(0xFFFFFFFF), 0.12)!;

  @override
  bool shouldRepaint(PlayerMapPainter old) =>
      !identical(old.map, map) || !identical(old.pulses, pulses) || old.time != time || old.selected != selected || old.selectedSeat != selectedSeat;
}
