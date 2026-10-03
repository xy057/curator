import 'dart:ui' as ui;

import 'engraving.dart';

/// Something drawable that a [ScenePatch] shows: a picture of [size] (its own units, pixels
/// for a raster image), of which [paint] draws the part [source] into [destination].
abstract class PatchArt {
  ui.Size get size;
  void paint(ui.Canvas canvas, ui.Rect source, ui.Rect destination, {double opacity = 1});
}

/// An image placed on the score that scrolls with it: its left edge is pinned to score
/// quarter [quarter], its top [top] staff spaces below the frame's top, and it is
/// [width] × [height] staff spaces (so it grows with the score size). It shows the part
/// [crop] of its [art], in fractions of the art (0–1).
class ScenePatch {
  const ScenePatch({
    required this.quarter,
    required this.top,
    required this.width,
    required this.height,
    this.crop = const ui.Rect.fromLTRB(0, 0, 1, 1),
    required this.art,
  });

  final double quarter, top, width, height;
  final ui.Rect crop;
  final PatchArt art;

  void paint(ui.Canvas canvas, ui.Rect destination, {double opacity = 1}) {
    final s = art.size;
    art.paint(canvas, ui.Rect.fromLTRB(crop.left * s.width, crop.top * s.height, crop.right * s.width, crop.bottom * s.height),
        destination,
        opacity: opacity);
  }
}

/// Score quarters ↔ x in the engraving (device units), through every onset: straight
/// between them, so it is one-to-one and runs both ways.
class ScoreAxis {
  factory ScoreAxis(EngravingData score, List<double> measureStarts) {
    final qs = <double>[], xs = <double>[];
    void add(double q, double x) {
      if (qs.isNotEmpty && (q <= qs.last + 1e-9 || x <= xs.last + 1e-6)) return;
      qs.add(q);
      xs.add(x);
    }

    final measures = score.measures;
    for (var i = 0; i < measures.length && i < measureStarts.length; i++) {
      final m = measures[i], start = measureStarts[i];
      add(start, m.onsetTimes.isNotEmpty && m.onsetTimes.first <= 0 ? m.onsetXs.first : m.left);
      for (var j = 0; j < m.onsetTimes.length; j++) {
        add(start + m.onsetTimes[j], m.onsetXs[j]);
      }
    }
    if (measures.isNotEmpty && measureStarts.length > measures.length) add(measureStarts[measures.length], measures.last.right);
    if (qs.length < 2) return ScoreAxis._([0, 1], [0, 1]);
    return ScoreAxis._(qs, xs);
  }

  ScoreAxis._(this._qs, this._xs);
  final List<double> _qs, _xs;

  /// x at score quarter [q]; beyond the ends, at the speed of the end stretch.
  double xAt(double q) => _map(q, _qs, _xs);

  /// The score quarter at x [x]; the inverse of [xAt].
  double quarterAt(double x) => _map(x, _xs, _qs);

  static double _map(double v, List<double> from, List<double> to) {
    var i = 0, j = from.length - 1;
    if (v <= from.first) {
      j = 1;
    } else if (v >= from.last) {
      i = from.length - 2;
    } else {
      while (j - i > 1) {
        final m = (i + j) >> 1;
        if (from[m] <= v) {
          i = m;
        } else {
          j = m;
        }
      }
    }
    return to[i] + (to[j] - to[i]) * (v - from[i]) / (from[j] - from[i]);
  }
}
