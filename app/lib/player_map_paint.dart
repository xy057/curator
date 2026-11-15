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

/// Sections' names laid out, by name, colour, size and direction: every painter's, since one is
/// made each time its widget is built (at each move of a drag in the editor), and laying a
/// map's names out again for each would cost more than drawing it. Emptied when it holds more
/// than a few maps' worth (a window being resized asks a new size each frame).
final _labels = <(String, int, double, TextDirection), TextPainter>{};

TextPainter _label(String name, int color, double size, TextDirection direction) {
  final key = (name, color, size, direction);
  if (_labels[key] case final kept?) return kept;
  if (_labels.length >= 512) {
    for (final label in _labels.values) {
      label.dispose();
    }
    _labels.clear();
  }
  return _labels[key] = TextPainter(
    text: TextSpan(text: name, style: TextStyle(color: Color(color).withValues(alpha: 0.85), fontSize: size, fontWeight: FontWeight.w500)),
    textDirection: direction,
    maxLines: 1,
  )..layout();
}

/// A [PlayerMap] at a time: each player a dot in its section's colour, dim at rest; each note its
/// instrument plays makes it swell and light up, fading as [PlayerPulses] says (a short note
/// quickly, a long one slowly). Repaints as [time] moves, every frame of a performance: what
/// shows it keeps it in a [RepaintBoundary], so nothing round it is painted again with it.
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
    final ring = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final (k, section) in map.sections.indexed) {
      final base = Color(section.color), rest = stage.radius(section.size);
      final dim = base.withValues(alpha: 0.55), lit = _bright(base);
      // A link's level and colour once for the players in a row who share it: mostly all of them.
      PlayerLink? of;
      var asked = false, level = 0.0, fill = dim;
      for (final (i, seat) in section.seats.indexed) {
        final link = section.linkOf(i);
        if (!asked || link != of) {
          (of, asked) = (link, true);
          level = pulses.level(link, t);
          fill = Color.lerp(dim, lit, level)!;
        }
        final center = stage.toView(seat.x, seat.y), r = rest * (1 + _swell * level);
        if (level > 0.02) canvas.drawCircle(center, r * 1.35, glow..color = base.withValues(alpha: 0.16 * level));
        canvas.drawCircle(center, r, dot..color = fill);
        if (k == selected && (selectedSeat == null || selectedSeat == i)) canvas.drawCircle(center, r + 2.5, ring);
      }
      if (section.name.isNotEmpty && labelSize >= 5) {
        final label = _label(section.name, section.color, labelSize, textDirection), at = stage.toView(section.labelX, section.labelY);
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
      !identical(old.map, map) ||
      !identical(old.pulses, pulses) ||
      old.time != time ||
      old.selected != selected ||
      old.selectedSeat != selectedSeat ||
      old.accent != accent ||
      old.textDirection != textDirection;
}
