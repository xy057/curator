import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'beat_grid.dart';
import 'scroll_map.dart';
import 'search.dart';

/// A point where the score is pinned to the recording: [quarter] (score quarters from the
/// start of the piece) sounds at [seconds] in the audio.
@immutable
class SyncAnchor {
  const SyncAnchor(this.quarter, this.seconds);
  final double quarter;
  final double seconds;

  @override
  bool operator ==(Object other) => other is SyncAnchor && other.quarter == quarter && other.seconds == seconds;
  @override
  int get hashCode => Object.hash(quarter, seconds);
  @override
  String toString() => 'SyncAnchor($quarter q @ ${seconds.toStringAsFixed(3)} s)';
}

/// What a tap or a nudge snaps to.
enum SyncGrid { bar, beat }

/// The tempo track: maps the score to the recording through anchors. Undo is kept by whoever
/// owns it (the app keeps one history for the whole document).
///
/// Between two anchors the tempo is constant, so any rubato, ritardando or accelerando is
/// followed by adding anchors where it happens. Before the first and after the last anchor
/// the neighbouring segment's tempo continues. With no anchors the score's own tempo is used,
/// starting at [leadIn].
///
/// Tapping (see [tap]) follows these rules:
///  * the first tap is always the beginning of the piece;
///  * every later tap is predicted from the tempo so far and snapped to the nearest bar (or
///    beat), and the segment before it is re-timed to end exactly there. Until two taps have
///    measured a tempo, the prediction uses the score's own tempo ([defaultTempo], from the
///    MusicXML).
class SyncMap extends ChangeNotifier implements ScoreTimeline {
  /// [beats] says where the beats fall (quarter notes when not given).
  SyncMap({required List<double> measureStarts, required this.defaultTempo, double leadIn = 0, BeatGrid? beats})
      : measureStarts = List.unmodifiable(measureStarts),
        beats = beats ?? BeatGrid(measureStarts),
        // ignore: prefer_initializing_formals
        _leadIn = leadIn;

  @override
  final List<double> measureStarts;

  /// The beats of every bar: what [SyncGrid.beat] taps, snaps and shifts to.
  final BeatGrid beats;

  /// Quarter notes per minute used where no anchors say otherwise.
  final double defaultTempo;

  List<SyncAnchor> get anchors => _anchors;
  List<SyncAnchor> _anchors = const [];

  int get revision => _revision;
  int _revision = 0;

  @override
  void notifyListeners() {
    _revision++;
    super.notifyListeners();
  }

  double get totalQuarters => measureStarts.last;

  // MARK: Start of the piece

  double _leadIn;

  /// Where bar 1 beat 1 sounds: the first anchor, or the lead-in when there are none.
  double get startSeconds => _anchors.isNotEmpty && _anchors.first.quarter == 0 ? _anchors.first.seconds : _leadIn;

  /// Moves the start of the piece. With anchors, only the opening anchor moves (the rest are
  /// tied to events in the recording).
  set startSeconds(double seconds) {
    if (_anchors.isNotEmpty && _anchors.first.quarter == 0) {
      final limit = _anchors.length > 1 ? _anchors[1].seconds - 0.01 : double.infinity;
      _anchors = [SyncAnchor(0, seconds.clamp(0, limit)), ..._anchors.skip(1)];
    } else {
      _leadIn = math.max(0, seconds);
    }
    notifyListeners();
  }

  // MARK: Mapping

  /// Tempo of segment [i] (between anchors i and i + 1), quarter notes per minute.
  double segmentTempo(int i) {
    final a = _anchors[i], b = _anchors[i + 1];
    return (b.quarter - a.quarter) / (b.seconds - a.seconds) * 60;
  }

  double get _firstTempo => _anchors.length > 1 ? segmentTempo(0) : defaultTempo;
  double get _lastTempo => _anchors.length > 1 ? segmentTempo(_anchors.length - 2) : defaultTempo;

  @override
  double secondsAtQuarter(double quarter) {
    if (_anchors.isEmpty) return _leadIn + quarter * 60 / defaultTempo;
    final first = _anchors.first, last = _anchors.last;
    if (quarter <= first.quarter) return first.seconds - (first.quarter - quarter) * 60 / _firstTempo;
    if (quarter >= last.quarter) return last.seconds + (quarter - last.quarter) * 60 / _lastTempo;
    final i = _segmentByQuarter(quarter);
    final a = _anchors[i], b = _anchors[i + 1];
    return a.seconds + (quarter - a.quarter) / (b.quarter - a.quarter) * (b.seconds - a.seconds);
  }

  @override
  double quarterAtSeconds(double seconds) {
    if (_anchors.isEmpty) return (seconds - _leadIn) * defaultTempo / 60;
    final first = _anchors.first, last = _anchors.last;
    if (seconds <= first.seconds) return first.quarter - (first.seconds - seconds) * _firstTempo / 60;
    if (seconds >= last.seconds) return last.quarter + (seconds - last.seconds) * _lastTempo / 60;
    final i = _segmentBySeconds(seconds);
    final a = _anchors[i], b = _anchors[i + 1];
    return a.quarter + (seconds - a.seconds) / (b.seconds - a.seconds) * (b.quarter - a.quarter);
  }

  @override
  double secondsAt(MusicalPosition p) {
    final start = p.measure < measureStarts.length ? measureStarts[p.measure] : 0.0;
    return secondsAtQuarter(start + p.beat);
  }

  int _segmentByQuarter(double q) => segmentAt(_anchors.length, q, (i) => _anchors[i].quarter);
  int _segmentBySeconds(double s) => segmentAt(_anchors.length, s, (i) => _anchors[i].seconds);

  // MARK: Grid

  int measureAt(double quarter) => beats.measureAt(quarter);

  /// Grid points (bar starts, or the beats of the time signature) as score quarters.
  Iterable<double> _gridAround(double quarter, SyncGrid grid) sync* {
    final m = measureAt(quarter);
    for (var i = math.max(0, m - 1); i <= math.min(measureStarts.length - 1, m + 2); i++) {
      yield measureStarts[i];
      if (grid == SyncGrid.beat && i + 1 < measureStarts.length) yield* beats.beatsIn(i).skip(1);
    }
  }

  double nearestGrid(double quarter, SyncGrid grid) {
    final q = quarter.clamp(0.0, totalQuarters);
    return _gridAround(q, grid).reduce((a, b) => (a - q).abs() <= (b - q).abs() ? a : b);
  }

  /// The first grid point strictly after [quarter].
  double nextGrid(double quarter, SyncGrid grid) {
    final candidates = _gridAround(quarter, grid).where((g) => g > quarter + 1e-6);
    return candidates.isEmpty ? totalQuarters : candidates.reduce(math.min);
  }

  /// The last grid point strictly before [quarter].
  double previousGrid(double quarter, SyncGrid grid) {
    final candidates = _gridAround(quarter, grid).where((g) => g < quarter - 1e-6);
    return candidates.isEmpty ? 0 : candidates.reduce(math.max);
  }

  // MARK: Tapping

  double? _sessionLastTap;

  /// Starts a tapping pass: taps from now on overwrite the anchors they pass over.
  void beginTapping() => _sessionLastTap = null;

  /// Adds an anchor for a tap at [seconds] and returns it (see the class rules).
  SyncAnchor tap(double seconds, {SyncGrid grid = SyncGrid.bar}) {
    // Overwrite what this pass has moved over (and an old anchor for this very beat).
    final from = _sessionLastTap ?? seconds - 0.15;
    var anchors = [for (final a in _anchors) if (a.seconds <= from || a.seconds > seconds + 0.15) a];
    _sessionLastTap = seconds;

    final before = anchors.where((a) => a.seconds < seconds).toList();
    final double quarter;
    if (before.isEmpty) {
      quarter = 0; // the first anchor is always the beginning of the piece
    } else {
      final b = before.last;
      // Quarters per second: the last tapped segment, or the score's tempo before there is one.
      final a = before.length > 1 ? before[before.length - 2] : null;
      final tempo = a != null ? (b.quarter - a.quarter) / (b.seconds - a.seconds) : defaultTempo / 60;
      final predicted = b.quarter + (seconds - b.seconds) * tempo;
      final snapped = nearestGrid(predicted, grid);
      quarter = snapped > b.quarter + 1e-6 ? snapped : nextGrid(b.quarter, grid);
    }
    final anchor = SyncAnchor(math.min(quarter, totalQuarters), seconds);
    // Later anchors that no longer fit after this one are dropped.
    anchors = [
      ...before,
      anchor,
      for (final a in anchors) if (a.seconds > seconds && a.quarter > anchor.quarter) a,
    ];
    _anchors = List.unmodifiable(anchors);
    notifyListeners();
    return anchor;
  }

  // MARK: Editing

  /// Adds an anchor at [seconds] for [quarter], replacing any anchor that would cross it.
  void addAnchor(SyncAnchor anchor) {
    _anchors = List.unmodifiable([
      for (final a in _anchors)
        if ((a.quarter < anchor.quarter && a.seconds < anchor.seconds) ||
            (a.quarter > anchor.quarter && a.seconds > anchor.seconds))
          a,
      anchor,
    ]..sort((a, b) => a.quarter.compareTo(b.quarter)));
    notifyListeners();
  }

  /// Moves anchor [index] in time, kept between its neighbours.
  void moveAnchor(int index, double seconds) {
    final lo = index > 0 ? _anchors[index - 1].seconds + 0.01 : 0.0;
    final hi = index + 1 < _anchors.length ? _anchors[index + 1].seconds - 0.01 : double.infinity;
    _replace(index, SyncAnchor(_anchors[index].quarter, seconds.clamp(lo, hi)));
  }

  /// Points anchor [index] at another place in the score (e.g. "this is bar 12, not 11").
  /// Returns false if that would cross a neighbouring anchor.
  bool setAnchorQuarter(int index, double quarter) {
    final lo = index > 0 ? _anchors[index - 1].quarter : double.negativeInfinity;
    final hi = index + 1 < _anchors.length ? _anchors[index + 1].quarter : double.infinity;
    if (quarter <= lo + 1e-6 || quarter >= hi - 1e-6 || quarter < 0 || quarter > totalQuarters) return false;
    _replace(index, SyncAnchor(quarter, _anchors[index].seconds));
    return true;
  }

  // MARK: Batch editing (a selection of anchors)

  /// Moves the anchors at [indices] together by [delta] seconds, starting from [from] (the
  /// anchors when a drag began; defaults to the current ones). The block is clamped so it never
  /// crosses an unselected neighbour. Returns the delta actually applied.
  double moveAnchors(Set<int> indices, double delta, {List<SyncAnchor>? from}) {
    final base = from ?? _anchors;
    if (indices.isEmpty) return 0;
    var lo = double.negativeInfinity, hi = double.infinity;
    for (final i in indices) {
      if (i < 0 || i >= base.length) continue;
      if (i == 0 || !indices.contains(i - 1)) {
        lo = math.max(lo, (i > 0 ? base[i - 1].seconds + 0.01 : 0) - base[i].seconds);
      }
      if (i == base.length - 1 || !indices.contains(i + 1)) {
        if (i + 1 < base.length) hi = math.min(hi, base[i + 1].seconds - 0.01 - base[i].seconds);
      }
    }
    final applied = delta.clamp(lo, hi).toDouble();
    _anchors = List.unmodifiable([
      for (final (i, a) in base.indexed) indices.contains(i) ? SyncAnchor(a.quarter, a.seconds + applied) : a,
    ]);
    notifyListeners();
    return applied;
  }

  /// Re-points every anchor at [indices] to the next ([direction] > 0) or previous grid point,
  /// e.g. "all of these were one bar off". Returns false (and changes nothing) if that would
  /// put anchors out of order.
  bool shiftAnchors(Set<int> indices, int direction, SyncGrid grid) {
    if (indices.isEmpty) return false;
    final shifted = [
      for (final (i, a) in _anchors.indexed)
        indices.contains(i)
            ? SyncAnchor(direction > 0 ? nextGrid(a.quarter, grid) : previousGrid(a.quarter, grid), a.seconds)
            : a,
    ];
    for (var i = 0; i < shifted.length; i++) {
      final q = shifted[i].quarter;
      if (q < 0 || q > totalQuarters + 1e-9) return false;
      if (i > 0 && q <= shifted[i - 1].quarter + 1e-6) return false;
    }
    if (indices.every((i) => shifted[i].quarter == _anchors[i].quarter)) return false;
    _anchors = List.unmodifiable(shifted);
    notifyListeners();
    return true;
  }

  void removeAnchors(Set<int> indices) {
    if (indices.isEmpty) return;
    _anchors = List.unmodifiable([
      for (final (i, a) in _anchors.indexed)
        if (!indices.contains(i)) a,
    ]);
    notifyListeners();
  }

  /// Indices of the anchors between two times (inclusive), for box selection.
  Set<int> anchorsBetween(double t0, double t1) {
    final lo = math.min(t0, t1), hi = math.max(t0, t1);
    return {
      for (final (i, a) in _anchors.indexed)
        if (a.seconds >= lo && a.seconds <= hi) i,
    };
  }

  void clear() {
    _anchors = const [];
    notifyListeners();
  }

  void _replace(int index, SyncAnchor anchor) {
    _anchors = List.unmodifiable([..._anchors]..[index] = anchor);
    notifyListeners();
  }

  // MARK: Saving

  /// Where bar 1 sounds when there are no anchors.
  double get leadIn => _leadIn;

  /// Replaces every anchor and the lead-in (opening a project, or Undo).
  void load(List<SyncAnchor> anchors, {double leadIn = 0}) {
    _leadIn = leadIn;
    _anchors = List.unmodifiable([...anchors]..sort((a, b) => a.seconds.compareTo(b.seconds)));
    notifyListeners();
  }
}
