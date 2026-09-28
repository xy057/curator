import 'dart:math' as math;

import 'package:flutter/foundation.dart';

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

/// A stretch of the score played straight through, from score quarter [start] to [end].
/// A performance is one pass from the start to the end, or several when a warp jumps (a
/// repeat plays a stretch again, a jump to the coda skips one).
@immutable
class ScorePass {
  const ScorePass(this.start, this.end);
  final double start;
  final double end;

  @override
  bool operator ==(Object other) => other is ScorePass && other.start == start && other.end == end;
  @override
  int get hashCode => Object.hash(start, end);
  @override
  String toString() => 'ScorePass($start → $end)';
}

/// Maps musical time to seconds in the recording and back.
///
/// Musical time is measured in quarter notes from the start of the performed score
/// ("score quarters"). Curation regions are stored in score quarters, so they stay attached
/// to the music when the audio sync changes. A score starts at its own constant tempo
/// ([ConstantTempoTimeline]); syncing to a recording replaces that with a SyncMap.
///
/// A time is always at one place in the score, but a place in the score can sound more than
/// once (a repeat): it sounds once in each of the [passes] that play it.
abstract interface class ScoreTimeline {
  /// Start of each measure, in score quarters (plus the end of the last one).
  List<double> get measureStarts;

  /// The stretches of the score in the order they sound.
  List<ScorePass> get passes;

  /// The pass sounding at [seconds]. A warp's own time belongs to the pass it jumps to.
  int passAt(double seconds);

  /// When [quarter] sounds in pass [pass] (outside that pass: where it would, going on at
  /// the pass's tempo).
  double secondsAtQuarter(double quarter, {int pass = 0});
  double quarterAtSeconds(double seconds);
  double secondsAt(MusicalPosition position, {int pass = 0});
}

/// A stretch of the score as it sounds in one pass: score quarters [start]–[end], heard
/// from [startSeconds] to [endSeconds].
typedef ScoreSpan = ({int pass, double start, double end, double startSeconds, double endSeconds});

extension ScoreTimelinePasses on ScoreTimeline {
  /// Every time the score between quarters [start] and [end] sounds, in order: the part of
  /// it each pass plays.
  Iterable<ScoreSpan> spans(double start, double end) sync* {
    for (final (k, p) in passes.indexed) {
      final lo = math.max(start, p.start), hi = math.min(end, p.end);
      if (hi - lo <= 1e-9) continue;
      yield (
        pass: k,
        start: lo,
        end: hi,
        startSeconds: secondsAtQuarter(lo, pass: k),
        endSeconds: secondsAtQuarter(hi, pass: k)
      );
    }
  }

  /// Every time the point [quarter] sounds (a barline, say): once in each pass that plays
  /// it. A pass's end is the next one's start, so it counts only for the last pass.
  Iterable<({int pass, double seconds})> timesOf(double quarter) sync* {
    final all = passes;
    for (final (k, p) in all.indexed) {
      final last = k == all.length - 1;
      if (quarter >= p.start - 1e-9 && (quarter < p.end - 1e-9 || (last && quarter <= p.end + 1e-9))) {
        yield (pass: k, seconds: secondsAtQuarter(quarter, pass: k));
      }
    }
  }

  /// When the performance reaches the end of its last pass.
  double get endSeconds => secondsAtQuarter(passes.last.end, pass: passes.length - 1);
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
  late final List<ScorePass> passes = [ScorePass(0, measureStarts.last)];

  @override
  int passAt(double seconds) => 0;

  @override
  double secondsAtQuarter(double quarter, {int pass = 0}) => quarter * 60 / quarterNotesPerMinute;

  @override
  double quarterAtSeconds(double seconds) => seconds * quarterNotesPerMinute / 60;

  @override
  double secondsAt(MusicalPosition p, {int pass = 0}) {
    final start = p.measure < measureStarts.length ? measureStarts[p.measure] : 0.0;
    return secondsAtQuarter(start + p.beat);
  }
}

/// Playback time → the score x that sits under the fixed pointer.
///
/// Anchors sit on every beat of the time signature ([beats]; every crotchet without one),
/// taking the beat's x from the engraved onsets, so each beat lands exactly on the pointer.
/// Between beats a monotone cubic (Fritsch–Carlson) keeps the scroll speed continuous and
/// never lets the score move backwards. Each pass of the performance (see
/// [ScoreTimeline.passes]) has a curve of its own: where a warp jumps, so does the score.
class ScrollMap {
  ScrollMap._(this._curves, this._starts);

  factory ScrollMap(EngravingData score, ScoreTimeline timeline, {BeatGrid? beats}) {
    final measures = score.measures;
    final starts = timeline.measureStarts;
    // Each measure's onsets as (quarters into it, x), closed by the next measure's first
    // onset (or the final barline).
    final points = [
      for (var i = 0; i < measures.length; i++)
        () {
          final m = measures[i];
          final next = i + 1 < measures.length ? measures[i + 1] : null;
          return <(double, double)>[
            if (m.onsetTimes.isEmpty || m.onsetTimes.first > 0) (0, m.left),
            for (var j = 0; j < m.onsetTimes.length; j++) (m.onsetTimes[j], m.onsetXs[j]),
            (m.duration, next != null && next.onsetXs.isNotEmpty ? next.onsetXs.first : m.right),
          ];
        }(),
    ];
    double xAtQuarter(double q) {
      final i = segmentAt(measures.length + 1, q, (i) => starts[i]);
      return _interpolate(points[i], q - starts[i]);
    }

    // Every beat in the score, and the final barline.
    final beatQuarters = <double>[
      for (var i = 0; i < measures.length; i++)
        if (beats == null || i >= beats.measureStarts.length - 1)
          for (var q = 0.0; q < measures[i].duration - 1e-9; q += 1) starts[i] + q
        else
          ...beats.beatsIn(i),
      starts[measures.length],
    ];

    final curves = <_Curve>[];
    final passStarts = <double>[];
    for (final (k, pass) in timeline.passes.indexed) {
      final quarters = [
        pass.start,
        for (final q in beatQuarters)
          if (q > pass.start + 1e-9 && q < pass.end - 1e-9) q,
        pass.end,
      ];
      // Strictly increasing times, non-decreasing x.
      final times = <double>[], xs = <double>[];
      for (final q in quarters) {
        final t = timeline.secondsAtQuarter(q, pass: k), x = xAtQuarter(q);
        if (times.isNotEmpty && t <= times.last + 1e-6) continue;
        times.add(t);
        xs.add(xs.isEmpty ? x : math.max(x, xs.last));
      }
      curves.add(_Curve(times, xs));
      passStarts.add(k == 0 ? double.negativeInfinity : timeline.secondsAtQuarter(pass.start, pass: k));
    }
    return ScrollMap._(curves, passStarts);
  }

  final List<_Curve> _curves;
  final List<double> _starts; // when each pass begins (the first: always)

  /// The anchors' times and x, every pass one after another.
  List<double> get times => [for (final c in _curves) ...c.times];
  List<double> get xs => [for (final c in _curves) ...c.xs];

  double get duration => _curves.last.times.lastOrNull ?? 0;

  int _passAt(double t) => segmentAt(_starts.length + 1, t, (i) => i < _starts.length ? _starts[i] : double.infinity);

  /// x in device units at playback time [t]. Outside the anchors the score keeps moving
  /// at the end speeds, so it scrolls in and out smoothly.
  double xAt(double t) => _curves[_passAt(t)].xAt(t);

  /// The leftmost and rightmost x shown between times [t0] and [t1] (a warp between them
  /// shows two stretches of the score).
  ({double min, double max}) xRange(double t0, double t1) {
    var lo = double.infinity, hi = double.negativeInfinity;
    for (final s in xStretches(t0, t1)) {
      lo = math.min(lo, s.min);
      hi = math.max(hi, s.max);
    }
    return (min: lo, max: hi);
  }

  /// The stretches of the score shown between times [t0] and [t1], one per pass (a warp
  /// between them shows two, with the score between them never on screen).
  Iterable<({double min, double max})> xStretches(double t0, double t1) sync* {
    for (var k = _passAt(t0); k <= _passAt(t1); k++) {
      final a = math.max(t0, _starts[k]), b = k + 1 < _starts.length ? math.min(t1, _starts[k + 1]) : t1;
      yield (min: _curves[k].xAt(a), max: _curves[k].xAt(b));
    }
  }

  /// Every time at which the score reaches [x] (one per pass that plays it), in order.
  List<double> timesAt(double x) => [
        for (var k = 0; k < _curves.length; k++)
          ?_curves[k].timeAt(x, from: _starts[k], to: k + 1 < _starts.length ? _starts[k + 1] : double.infinity),
      ];

  /// When each pass after the first begins: the score jumps there (a warp).
  Iterable<double> get warpTimes => _starts.skip(1);

  static double _interpolate(List<(double, double)> points, double time) {
    final upper = points.indexWhere((p) => p.$1 >= time);
    if (upper < 0) return points.last.$2;
    if (upper == 0) return points.first.$2;
    final (t0, x0) = points[upper - 1];
    final (t1, x1) = points[upper];
    return x0 + (x1 - x0) * (time - t0) / (t1 - t0);
  }
}

/// One pass's scroll: a monotone cubic through (time, x) anchors.
class _Curve {
  _Curve(this.times, this.xs) : _tangents = _monotoneTangents(times, xs);

  final List<double> times;
  final List<double> xs;
  final List<double> _tangents;

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

  /// The first time between [from] and [to] at which the scroll reaches [x], or null.
  /// The curve never goes back, so this is a bisection.
  double? timeAt(double x, {required double from, required double to}) {
    if (times.length < 2) return null;
    var lo = math.max(from, times.first - 10), hi = math.min(to, times.last + 10);
    if (lo >= hi || xAt(lo) > x || xAt(hi) < x) return null;
    for (var i = 0; i < 60 && hi - lo > 1e-6; i++) {
      final mid = (lo + hi) / 2;
      if (xAt(mid) < x) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return hi;
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
