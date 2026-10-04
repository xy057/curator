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
/// Two ways to scroll, and any blend of them ([follow], 0–1):
///
/// * **Beats** (0, as before 0.2): every beat of the time signature ([beats]; every crotchet
///   without one) is an anchor, its x taken from the engraved onsets, and a monotone cubic
///   (Fritsch–Carlson) runs between them. The speed changes only with the tempo and the bar's
///   spacing, so the scroll glides; a note off the beat may pass the pointer a little early
///   or late.
/// * **Notes** (1): every onset in the score (a note or rest starting in any staff) is an
///   anchor: it is under the pointer exactly when it sounds. Engraved spacing grows much
///   more slowly than duration (a minim takes far less than two crotchets' room), so the
///   speed follows the notes: slow through long notes, quicker through runs, and quick
///   across room no note owns (a barline, a key change). Between onsets only the speed is
///   free: it changes as gently as it can (see [_Curve._tangentsOf]).
///
/// In between, x is the weighted mean of the two: both reach every beat on time and neither
/// ever runs back, so neither does the blend, and its speed is the same mean of theirs.
/// Each pass of the performance (see [ScoreTimeline.passes]) has a curve of its own: where a
/// warp jumps, so does the score.
class ScrollMap {
  ScrollMap._(this._beatCurves, this._onsetCurves, this._starts, this.follow)
      : _curves = [
          for (var k = 0; k < _starts.length; k++)
            follow <= 0
                ? _beatCurves[k]
                : follow >= 1
                    ? _onsetCurves[k]
                    : _Blend(_beatCurves[k], _onsetCurves[k], follow),
        ];

  factory ScrollMap(EngravingData score, ScoreTimeline timeline, {BeatGrid? beats, double follow = 1}) {
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
    // Every onset in the score, and the final barline.
    final onsetQuarters = <double>[
      for (var i = 0; i < measures.length; i++)
        for (final (q, _) in points[i].take(points[i].length - 1)) starts[i] + q,
      starts[measures.length],
    ];

    // One pass's anchors: strictly increasing times and x (an anchor no further on than the
    // one before can't be reached any later; the pass's end is always kept, as a warp jumps
    // from there).
    (List<double>, List<double>) anchors(List<double> all, ScorePass pass, int k) {
      final quarters = [
        pass.start,
        for (final q in all)
          if (q > pass.start + 1e-9 && q < pass.end - 1e-9) q,
        pass.end,
      ];
      final times = <double>[], xs = <double>[];
      for (final (j, q) in quarters.indexed) {
        final t = timeline.secondsAtQuarter(q, pass: k), x = xAtQuarter(q);
        if (times.isNotEmpty && (t <= times.last + 1e-6 || x <= xs.last + 1e-3)) {
          if (j < quarters.length - 1 || times.length < 2) continue;
          times.removeLast();
          xs.removeLast();
        }
        times.add(t);
        xs.add(xs.isEmpty ? x : math.max(x, xs.last + 1e-3));
      }
      return (times, xs);
    }

    // The anchors are read from the timeline now (a SyncMap changes later); the curves
    // through them are solved when first used, so a map that never follows the notes never
    // solves for them.
    final beatCurves = <_Curve>[], onsetCurves = <_Curve>[];
    final passStarts = <double>[];
    for (final (k, pass) in timeline.passes.indexed) {
      final (bt, bx) = anchors(beatQuarters, pass, k);
      final (ot, ox) = anchors(onsetQuarters, pass, k);
      beatCurves.add(_Curve(bt, bx, followsNotes: false));
      onsetCurves.add(_Curve(ot, ox, followsNotes: true));
      passStarts.add(k == 0 ? double.negativeInfinity : timeline.secondsAtQuarter(pass.start, pass: k));
    }
    return ScrollMap._(beatCurves, onsetCurves, passStarts, follow.isFinite ? follow.clamp(0, 1) : 1);
  }

  /// How closely the scroll follows the notes: 0 glides from beat to beat, 1 puts every
  /// onset on time; in between, a blend.
  final double follow;

  /// The same scroll, following the notes by [follow] (0–1) instead. Cheap: the anchors
  /// are shared, and each curve is solved once.
  ScrollMap withFollow(double follow) {
    final f = follow.isFinite ? follow.clamp(0.0, 1.0) : 1.0;
    return f == this.follow ? this : ScrollMap._(_beatCurves, _onsetCurves, _starts, f);
  }

  final List<_Curve> _beatCurves;
  final List<_Curve> _onsetCurves;
  final List<_Scroll> _curves;
  final List<double> _starts; // when each pass begins (the first: always)

  /// The anchors' times and x, every pass one after another.
  List<double> get times => [for (final c in _curves) ...c.times];
  List<double> get xs => [for (final c in _curves) ...c.xs];

  double get duration => _curves.last.end;

  int _passAt(double t) => segmentAt(_starts.length + 1, t, (i) => i < _starts.length ? _starts[i] : double.infinity);

  /// How long the score takes to come to rest after the final barline reaches the pointer.
  static const settle = 2.5;

  /// x in device units at playback time [t]. Before the first anchor the score keeps moving
  /// at its opening speed, so it scrolls in smoothly; after the last it slows to rest over
  /// [settle] seconds, travelling a third of what it would at that speed, so the last bars
  /// stay on screen.
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

/// One pass's scroll: x at every time, never going back.
abstract class _Scroll {
  /// The anchors the curve passes through.
  List<double> get times;
  List<double> get xs;

  /// When the last anchor is reached (0 without one).
  double get end => times.lastOrNull ?? 0;

  double xAt(double t);

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
}

/// A pass scrolled by [follow] of the way from the beats' curve to the notes'.
class _Blend extends _Scroll {
  _Blend(this.beats, this.notes, this.follow);
  final _Curve beats;
  final _Curve notes;
  final double follow;

  /// Every anchor of either curve (each lands where the blend puts it).
  @override
  late final List<double> times = ({...beats.times, ...notes.times}.toList()..sort());
  @override
  late final List<double> xs = [for (final t in times) xAt(t)];

  @override
  double get end => math.max(beats.end, notes.end);

  @override
  double xAt(double t) => (1 - follow) * beats.xAt(t) + follow * notes.xAt(t);
}

/// One pass's scroll: a cubic through the (time, x) anchors.
///
/// Through the beats ([followsNotes] false) it is a monotone cubic (Fritsch–Carlson).
/// Through the onsets its speed changes as little as it can, relative to how fast the score
/// is moving: of all the curves through the anchors, the natural cubic spline has the least
/// acceleration overall; weighing each stretch by 1 / (its mean speed)², a speed change
/// costs the same fast or slow, so a burst across a key change stays where it is instead of
/// making the notes around it lurch. Where that curve would slow below [floor] of a
/// stretch's mean speed (or stop, or run back), its tangents are held back, so the score
/// always moves on.
class _Curve extends _Scroll {
  _Curve(this.times, this.xs, {required this.followsNotes});

  @override
  final List<double> times;
  @override
  final List<double> xs;
  final bool followsNotes;
  late final List<double> _tangents = followsNotes ? _tangentsOf(times, xs) : _monotoneTangents(times, xs);

  /// The slowest the score may move between two onsets, relative to its mean speed there.
  static const floor = 0.25;

  @override
  double xAt(double t) {
    if (times.length < 2) return xs.firstOrNull ?? 0;
    if (t <= times.first) return xs.first + _tangents.first * (t - times.first);
    if (t >= times.last) {
      // Speed v·(1 − u)², u from 0 to 1 over the settle: it eases to rest, no jolt.
      final u = math.min((t - times.last) / ScrollMap.settle, 1.0), rest = 1 - u;
      return xs.last + _tangents.last * ScrollMap.settle * (1 - rest * rest * rest) / 3;
    }

    final lo = segmentAt(times.length, t, (i) => times[i]), hi = lo + 1;
    final h = times[hi] - times[lo];
    final s = (t - times[lo]) / h;
    final h00 = (1 + 2 * s) * (1 - s) * (1 - s);
    final h10 = s * (1 - s) * (1 - s);
    final h01 = s * s * (3 - 2 * s);
    final h11 = s * s * (s - 1);
    return h00 * xs[lo] + h10 * h * _tangents[lo] + h01 * xs[hi] + h11 * h * _tangents[hi];
  }

  /// Fritsch–Carlson: the mean of the secants either side, cut back so no stretch
  /// overshoots its anchors (the curve never runs back).
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

  /// The tangents (speeds at the anchors): the least relative acceleration, subject to the
  /// floor, by Gauss–Seidel sweeps each clamped to the bounds the neighbours leave.
  static List<double> _tangentsOf(List<double> t, List<double> x) {
    final n = t.length;
    if (n < 2) return List.filled(n, 0);
    final secants = [for (var k = 0; k < n - 1; k++) (x[k + 1] - x[k]) / (t[k + 1] - t[k])];
    // ∫x''² over stretch k is (4/h)(m0² + m0·m1 + m1²) − (12/h)·secant·(m0 + m1) + const.
    final weights = [for (var k = 0; k < n - 1; k++) 4 / (t[k + 1] - t[k]) / (secants[k] * secants[k])];
    // A start that keeps every stretch above the floor.
    final m = [for (var i = 0; i < n; i++) math.min(secants[math.max(0, i - 1)], secants[math.min(n - 2, i)])];

    // How fast stretch k moves at [s] (0–1) is secant·6s(1−s) + m0·(1−s)(1−3s) + m1·s(3s−2):
    // for each sample the floor bounds m[i] given the other end.
    const samples = [0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875];
    void bound(int k, {required bool atStart, required List<double> range}) {
      final other = atStart ? m[k + 1] : m[k];
      for (final s in samples) {
        final c0 = (1 - s) * (1 - 3 * s), c1 = s * (3 * s - 2);
        final self = atStart ? c0 : c1, rest = atStart ? c1 : c0;
        final limit = (floor - 6 * s * (1 - s)) * secants[k] - rest * other;
        if (self > 1e-12) {
          range[0] = math.max(range[0], limit / self);
        } else if (self < -1e-12) {
          range[1] = math.min(range[1], limit / self);
        }
      }
    }

    for (var sweep = 0; sweep < 500; sweep++) {
      var moved = 0.0;
      for (var i = 0; i < n; i++) {
        var num = 0.0, den = 0.0;
        // The speed at an anchor is at least the floor of the slower stretch beside it.
        final range = [floor * math.min(secants[math.max(0, i - 1)], secants[math.min(n - 2, i)]), double.infinity];
        if (i > 0) {
          num += weights[i - 1] * (3 * secants[i - 1] - m[i - 1]);
          den += 2 * weights[i - 1];
          bound(i - 1, atStart: false, range: range);
        }
        if (i < n - 1) {
          num += weights[i] * (3 * secants[i] - m[i + 1]);
          den += 2 * weights[i];
          bound(i, atStart: true, range: range);
        }
        final best = num / den;
        final next = range[0] <= range[1] ? best.clamp(range[0], range[1]) : (range[0] + range[1]) / 2;
        moved = math.max(moved, (next - m[i]).abs() / math.max(secants[math.max(0, i - 1)], secants[math.min(n - 2, i)]));
        m[i] = next;
      }
      if (moved < 1e-7) break;
    }
    return m;
  }
}
