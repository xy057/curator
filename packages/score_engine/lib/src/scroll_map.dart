import 'dart:math' as math;

import 'beat_grid.dart';
import 'engraving.dart';
import 'search.dart';

/// A position in the performed score: measure index plus quarter notes into it.
class MusicalPosition implements Comparable<MusicalPosition> {
  const MusicalPosition(this.measure, this.beat);
  final int measure;
  final double beat;

  @override
  int compareTo(MusicalPosition other) =>
      measure != other.measure ? measure.compareTo(other.measure) : beat.compareTo(other.beat);
}

/// Maps musical time to seconds in the recording and back.
///
/// Musical time is measured in quarter notes from the start of the performed score
/// ("score quarters"). Curation regions are stored in score quarters, so they stay attached
/// to the music when the audio sync changes. A score starts at its own constant tempo
/// ([ConstantTempoTimeline]); syncing to a recording replaces that with a SyncMap.
abstract interface class ScoreTimeline {
  /// Start of each measure, in score quarters (plus the end of the last one).
  List<double> get measureStarts;
  double secondsAtQuarter(double quarter);
  double quarterAtSeconds(double seconds);
  double secondsAt(MusicalPosition position);
}

class ConstantTempoTimeline implements ScoreTimeline {
  ConstantTempoTimeline(List<MeasureLayout> measures, {required this.quarterNotesPerMinute}) {
    var start = 0.0;
    for (final m in measures) {
      measureStarts.add(start);
      start += m.duration;
    }
    measureStarts.add(start);
  }

  final double quarterNotesPerMinute;

  @override
  final List<double> measureStarts = [];

  @override
  double secondsAtQuarter(double quarter) => quarter * 60 / quarterNotesPerMinute;

  @override
  double quarterAtSeconds(double seconds) => seconds * quarterNotesPerMinute / 60;

  @override
  double secondsAt(MusicalPosition p) {
    final start = p.measure < measureStarts.length ? measureStarts[p.measure] : 0.0;
    return secondsAtQuarter(start + p.beat);
  }
}

/// Playback time → the score x that sits under the fixed pointer.
///
/// Anchors sit on every beat of the time signature ([beats]; every crotchet without one),
/// taking the beat's x from the engraved onsets, so each beat lands exactly on the pointer.
/// Between beats a monotone cubic (Fritsch–Carlson) keeps the scroll speed continuous and
/// never lets the score move backwards.
class ScrollMap {
  ScrollMap._(this.times, this.xs, this._tangents);

  factory ScrollMap(EngravingData score, ScoreTimeline timeline, {BeatGrid? beats}) {
    final anchors = <(double, double)>[];
    final measures = score.measures;
    for (var i = 0; i < measures.length; i++) {
      final m = measures[i];
      final next = i + 1 < measures.length ? measures[i + 1] : null;
      // This measure's onsets, closed by the next measure's first onset (or the final barline).
      final points = <(double, double)>[
        if (m.onsetTimes.isEmpty || m.onsetTimes.first > 0) (0, m.left),
        for (var j = 0; j < m.onsetTimes.length; j++) (m.onsetTimes[j], m.onsetXs[j]),
        (m.duration, next != null && next.onsetXs.isNotEmpty ? next.onsetXs.first : m.right),
      ];
      final offsets = beats == null || i >= beats.measureStarts.length - 1
          ? [for (var q = 0.0; q < m.duration - 1e-9; q += 1) q]
          : [for (final q in beats.beatsIn(i)) q - beats.measureStarts[i]];
      for (final beat in offsets) {
        anchors.add((timeline.secondsAt(MusicalPosition(i, beat)), _interpolate(points, beat)));
      }
      if (next == null) anchors.add((timeline.secondsAt(MusicalPosition(i, m.duration)), points.last.$2));
    }

    // Strictly increasing times, non-decreasing x.
    final times = <double>[], xs = <double>[];
    for (final (t, x) in anchors) {
      if (times.isNotEmpty && t <= times.last + 1e-6) continue;
      times.add(t);
      xs.add(xs.isEmpty ? x : math.max(x, xs.last));
    }
    return ScrollMap._(times, xs, _monotoneTangents(times, xs));
  }

  final List<double> times;
  final List<double> xs;
  final List<double> _tangents;

  double get duration => times.isEmpty ? 0 : times.last;

  /// x in device units at playback time [t]. Outside the anchors the score keeps moving
  /// at the end speeds, so it scrolls in and out smoothly.
  double xAt(double t) {
    if (times.length < 2) return xs.firstOrNull ?? 0;
    if (t <= times.first) return xs.first + _tangents.first * (t - times.first);
    if (t >= times.last) return xs.last + _tangents.last * (t - times.last);

    final lo = segmentAt(times.length, t, (i) => times[i]), hi = lo + 1;
    final h = times[hi] - times[lo];
    final s = (t - times[lo]) / h;
    final h00 = (1 + 2 * s) * (1 - s) * (1 - s);
    final h10 = s * (1 - s) * (1 - s);
    final h01 = s * s * (3 - 2 * s);
    final h11 = s * s * (s - 1);
    return h00 * xs[lo] + h10 * h * _tangents[lo] + h01 * xs[hi] + h11 * h * _tangents[hi];
  }

  static double _interpolate(List<(double, double)> points, double time) {
    final upper = points.indexWhere((p) => p.$1 >= time);
    if (upper < 0) return points.last.$2;
    if (upper == 0) return points.first.$2;
    final (t0, x0) = points[upper - 1];
    final (t1, x1) = points[upper];
    return x0 + (x1 - x0) * (time - t0) / (t1 - t0);
  }

  static List<double> _monotoneTangents(List<double> t, List<double> x) {
    final n = t.length;
    if (n < 2) return List.filled(n, 0);
    final secants = [for (var k = 0; k < n - 1; k++) (x[k + 1] - x[k]) / (t[k + 1] - t[k])];
    final m = List<double>.filled(n, 0);
    m[0] = secants.first;
    m[n - 1] = secants.last;
    for (var k = 1; k < n - 1; k++) {
      m[k] = secants[k - 1] * secants[k] <= 0 ? 0 : (secants[k - 1] + secants[k]) / 2;
    }
    for (var k = 0; k < n - 1; k++) {
      if (secants[k] == 0) {
        m[k] = 0;
        m[k + 1] = 0;
        continue;
      }
      final a = m[k] / secants[k], b = m[k + 1] / secants[k];
      final r = a * a + b * b;
      if (r > 9) {
        final tau = 3 / math.sqrt(r);
        m[k] = tau * a * secants[k];
        m[k + 1] = tau * b * secants[k];
      }
    }
    return m;
  }
}
