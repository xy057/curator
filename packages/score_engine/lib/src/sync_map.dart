import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'beat_grid.dart';
import 'scroll_map.dart';
import 'search.dart';

/// A point where the score is pinned to the recording: [quarter] (score quarters from the
/// start of the piece) sounds at [seconds] in the audio.
///
/// A warp is an anchor that also jumps: the score arrives at [quarter] and, from that very
/// moment, goes on from [jumpTo] instead: back for a repeat, forward to skip to a coda.
@immutable
class SyncAnchor {
  const SyncAnchor(this.quarter, this.seconds, {this.jumpTo});
  final double quarter;
  final double seconds;

  /// Where a warp goes on from; null for a plain anchor.
  final double? jumpTo;

  bool get isWarp => jumpTo != null;

  /// Where the score goes on from after this anchor: [jumpTo] for a warp, else [quarter].
  double get departure => jumpTo ?? quarter;

  /// The same anchor (or warp) at another time.
  SyncAnchor at(double seconds) => SyncAnchor(quarter, seconds, jumpTo: jumpTo);

  /// The same anchor (or warp) arriving at another place in the score.
  SyncAnchor pointingAt(double quarter) => SyncAnchor(quarter, seconds, jumpTo: jumpTo);

  @override
  bool operator ==(Object other) =>
      other is SyncAnchor && other.quarter == quarter && other.seconds == seconds && other.jumpTo == jumpTo;
  @override
  int get hashCode => Object.hash(quarter, seconds, jumpTo);
  @override
  String toString() =>
      'SyncAnchor($quarter q${isWarp ? ' → $jumpTo q' : ''} @ ${seconds.toStringAsFixed(3)} s)';
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
/// Warps (anchors with a [SyncAnchor.jumpTo]) split the performance into passes
/// ([passes]). Underneath, the map works on the *performed* position: quarters played so far,
/// which a warp does not interrupt (arriving and going on are the same moment). So the tempo
/// runs on through a warp, and only where that position is in the score jumps. The anchors
/// are kept in time order; after each one the next arrives further on in the score than it
/// went on from.
///
/// Tapping (see [tap]) follows these rules:
///  * the first tap is always the beginning of the piece;
///  * every later tap is predicted from the tempo so far and snapped to the nearest bar (or
///    beat), and the segment before it is re-timed to end exactly there. Until two taps have
///    measured a tempo, the prediction uses the score's own tempo ([defaultTempo], from the
///    MusicXML);
///  * warps stay: a tap after one goes on from where it jumps to, and a tap on one (within
///    0.15 s) re-times it.
class SyncMap extends ChangeNotifier implements ScoreTimeline {
  /// [beats] says where the beats fall (quarter notes when not given).
  SyncMap({required List<double> measureStarts, required this.defaultTempo, double leadIn = 0, BeatGrid? beats})
      : measureStarts = List.unmodifiable(measureStarts),
        beats = beats ?? BeatGrid(measureStarts),
        // ignore: prefer_initializing_formals
        _leadIn = leadIn {
    _derive();
  }

  @override
  final List<double> measureStarts;

  /// The beats of every bar: what [SyncGrid.beat] taps, snaps and shifts to.
  final BeatGrid beats;

  /// Quarter notes per minute used where no anchors say otherwise.
  final double defaultTempo;

  /// Every anchor and warp, in time order.
  List<SyncAnchor> get anchors => _anchors;
  List<SyncAnchor> _anchors = const [];

  int get revision => _revision;
  int _revision = 0;

  @override
  void notifyListeners() {
    _derive();
    _revision++;
    super.notifyListeners();
  }

  // Derived from the anchors (see [_derive]).
  List<double> _performed = const []; // each anchor's performed position
  List<ScorePass> _passes = const [];
  List<double> _passOffsets = const []; // the performed position where each pass starts
  List<double> _warpTimes = const []; // when each pass after the first starts

  /// Works out the passes, and where each anchor is in the performance.
  void _derive() {
    final performed = <double>[], passes = <ScorePass>[], offsets = <double>[0], warps = <double>[];
    var start = 0.0, offset = 0.0;
    for (final a in _anchors) {
      final p = offset + a.quarter - start;
      performed.add(p);
      if (a.isWarp) {
        passes.add(ScorePass(start, a.quarter));
        start = a.jumpTo!;
        offset = p;
        offsets.add(p);
        warps.add(a.seconds);
      }
    }
    passes.add(ScorePass(start, totalQuarters));
    _performed = List.unmodifiable(performed);
    _passes = List.unmodifiable(passes);
    _passOffsets = List.unmodifiable(offsets);
    _warpTimes = List.unmodifiable(warps);
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
      _anchors = List.unmodifiable([_anchors.first.at(seconds.clamp(0, limit)), ..._anchors.skip(1)]);
    } else {
      _leadIn = math.max(0, seconds);
    }
    notifyListeners();
  }

  // MARK: Mapping

  /// Tempo of segment [i] (between anchors i and i + 1), quarter notes per minute.
  double segmentTempo(int i) =>
      (_performed[i + 1] - _performed[i]) / (_anchors[i + 1].seconds - _anchors[i].seconds) * 60;

  double get _firstTempo => _anchors.length > 1 ? segmentTempo(0) : defaultTempo;
  double get _lastTempo => _anchors.length > 1 ? segmentTempo(_anchors.length - 2) : defaultTempo;

  /// When the performance reaches performed position [p] (see the class notes).
  double _secondsAtPerformed(double p) {
    if (_anchors.isEmpty) return _leadIn + p * 60 / defaultTempo;
    final n = _anchors.length;
    if (p <= _performed.first) return _anchors.first.seconds - (_performed.first - p) * 60 / _firstTempo;
    if (p >= _performed.last) return _anchors.last.seconds + (p - _performed.last) * 60 / _lastTempo;
    final i = segmentAt(n, p, (i) => _performed[i]);
    final a = _anchors[i], b = _anchors[i + 1];
    return a.seconds + (p - _performed[i]) / (_performed[i + 1] - _performed[i]) * (b.seconds - a.seconds);
  }

  double _performedAtSeconds(double seconds) {
    if (_anchors.isEmpty) return (seconds - _leadIn) * defaultTempo / 60;
    final first = _anchors.first, last = _anchors.last;
    if (seconds <= first.seconds) return _performed.first - (first.seconds - seconds) * _firstTempo / 60;
    if (seconds >= last.seconds) return _performed.last + (seconds - last.seconds) * _lastTempo / 60;
    final i = segmentAt(_anchors.length, seconds, (i) => _anchors[i].seconds);
    final a = _anchors[i], b = _anchors[i + 1];
    return _performed[i] + (seconds - a.seconds) / (b.seconds - a.seconds) * (_performed[i + 1] - _performed[i]);
  }

  @override
  List<ScorePass> get passes => _passes;

  @override
  int passAt(double seconds) {
    var k = 0;
    while (k < _warpTimes.length && _warpTimes[k] <= seconds) {
      k++;
    }
    return k;
  }

  @override
  double secondsAtQuarter(double quarter, {int pass = 0}) {
    final k = pass.clamp(0, _passes.length - 1);
    return _secondsAtPerformed(_passOffsets[k] + quarter - _passes[k].start);
  }

  @override
  double quarterAtSeconds(double seconds) {
    final k = passAt(seconds);
    return _passes[k].start + _performedAtSeconds(seconds) - _passOffsets[k];
  }

  @override
  double secondsAt(MusicalPosition p, {int pass = 0}) {
    final start = p.measure < measureStarts.length ? measureStarts[p.measure] : 0.0;
    return secondsAtQuarter(start + p.beat, pass: pass);
  }

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
    // The downbeat after a repeat is the warp itself: tapping it re-times the warp.
    final warp = _anchors.indexWhere((a) => a.isWarp && (a.seconds - seconds).abs() <= 0.15);
    if (warp >= 0) {
      moveAnchor(warp, seconds);
      _sessionLastTap = _anchors[warp].seconds;
      return _anchors[warp];
    }

    // Overwrite what this pass has moved over (and an old anchor for this very beat).
    final from = _sessionLastTap ?? seconds - 0.15;
    final anchors = [
      for (final a in _anchors)
        if (a.isWarp || a.seconds <= from || a.seconds > seconds + 0.15) a,
    ];
    _sessionLastTap = seconds;

    final before = anchors.where((a) => a.seconds < seconds).toList();
    final double quarter;
    if (before.isEmpty) {
      quarter = 0; // the first anchor is always the beginning of the piece
    } else {
      final b = before.last;
      // Quarters per second: the last tapped segment, or the score's tempo before there is one.
      final a = before.length > 1 ? before[before.length - 2] : null;
      final tempo = a != null ? (b.quarter - a.departure) / (b.seconds - a.seconds) : defaultTempo / 60;
      final predicted = b.departure + (seconds - b.seconds) * tempo;
      final snapped = nearestGrid(predicted, grid);
      quarter = snapped > b.departure + 1e-6 ? snapped : nextGrid(b.departure, grid);
    }
    final anchor = SyncAnchor(math.min(quarter, totalQuarters), seconds);
    // Later anchors that no longer fit after this one are dropped.
    _anchors = _fitted([...before, anchor, ...anchors.where((a) => a.seconds > seconds)], keep: before.length);
    notifyListeners();
    return anchor;
  }

  // MARK: Editing

  /// Adds an anchor (or a warp) at its time, replacing any that would cross it.
  void addAnchor(SyncAnchor anchor) {
    final anchors = [
      for (final a in _anchors)
        if ((a.seconds - anchor.seconds).abs() > 1e-9) a,
      anchor,
    ]..sort((a, b) => a.seconds.compareTo(b.seconds));
    _anchors = _fitted(anchors, keep: anchors.indexOf(anchor));
    notifyListeners();
  }

  /// Moves anchor [index] in time, kept between its neighbours.
  void moveAnchor(int index, double seconds) {
    final lo = index > 0 ? _anchors[index - 1].seconds + 0.01 : 0.0;
    final hi = index + 1 < _anchors.length ? _anchors[index + 1].seconds - 0.01 : double.infinity;
    _replace(index, _anchors[index].at(seconds.clamp(lo, hi)));
  }

  /// Points anchor [index] at another place in the score (e.g. "this is bar 12, not 11").
  /// A warp still goes on from where it jumps to. Returns false if that would cross a
  /// neighbouring anchor.
  bool setAnchorQuarter(int index, double quarter) => setAnchor(index, quarter, jumpTo: _anchors[index].jumpTo);

  /// Makes anchor [index] a warp that goes on from [jumpTo] (null: a plain anchor again).
  ///
  /// The anchors after it, up to and including the next warp's arrival, move with the jump:
  /// they keep their times and their distance from it, and so point that much further back
  /// (or on). A stretch tapped before the repeat was marked lands where it belongs, and
  /// nothing scrolls at another speed. Returns false (changing nothing) when a warp would
  /// jump to where it is, or an anchor would leave the score.
  bool setJump(int index, double? jumpTo) => setAnchor(index, _anchors[index].quarter, jumpTo: jumpTo);

  /// Points anchor [index] at [quarter] and makes it go on from [jumpTo] (a warp; null: a
  /// plain anchor) in one step: [setAnchorQuarter] and [setJump] together. Returns false
  /// (changing nothing) if the anchors would be out of order or outside the score.
  bool setAnchor(int index, double quarter, {double? jumpTo}) {
    final a = _anchors[index];
    // Only a jump moves the anchors after it; re-pointing a plain anchor moves it alone.
    final delta = a.isWarp || jumpTo != null ? (jumpTo ?? quarter) - a.departure : 0.0;
    final changed = _shiftedAfter(_anchors, index, delta)..[index] = SyncAnchor(quarter, a.seconds, jumpTo: jumpTo);
    if (!_inOrder(changed)) return false;
    _anchors = List.unmodifiable(changed);
    notifyListeners();
    return true;
  }

  /// [anchors] with those after [index], up to and including the next warp's arrival,
  /// pointing [delta] quarters further on.
  static List<SyncAnchor> _shiftedAfter(List<SyncAnchor> anchors, int index, double delta) {
    final out = [...anchors];
    if (delta == 0) return out;
    for (var j = index + 1; j < out.length; j++) {
      out[j] = out[j].pointingAt(out[j].quarter + delta);
      if (out[j].isWarp) break;
    }
    return out;
  }

  /// [anchors] (in time order) without those that would put the score out of order or
  /// outside it. Walking out from anchor [keep] (or on from the first), each anchor must
  /// come later in time than the one before it, and arrive further on in the score than
  /// that one went on from; one that doesn't is dropped.
  List<SyncAnchor> _fitted(List<SyncAnchor> anchors, {int? keep}) {
    final out = <SyncAnchor>[];
    final k = keep ?? anchors.indexWhere(_valid);
    if (k < 0) return const [];
    var next = anchors[k];
    for (var j = k - 1; j >= 0; j--) {
      if (_valid(anchors[j]) && _follows(next, anchors[j])) out.insert(0, next = anchors[j]);
    }
    var previous = anchors[k];
    out.add(previous);
    for (var j = k + 1; j < anchors.length; j++) {
      if (_valid(anchors[j]) && _follows(anchors[j], previous)) out.add(previous = anchors[j]);
    }
    return List.unmodifiable(out);
  }

  /// Whether every anchor is valid and follows the one before it (see [_fitted]).
  bool _inOrder(List<SyncAnchor> anchors) {
    for (var i = 0; i < anchors.length; i++) {
      if (!_valid(anchors[i]) || (i > 0 && !_follows(anchors[i], anchors[i - 1]))) return false;
    }
    return true;
  }

  bool _inScore(double q) => q >= -1e-9 && q <= totalQuarters + 1e-9;

  /// Inside the score, and a warp jumps somewhere else.
  bool _valid(SyncAnchor a) =>
      _inScore(a.quarter) && (a.jumpTo == null || (_inScore(a.jumpTo!) && (a.jumpTo! - a.quarter).abs() >= 1e-6));

  /// [a] comes after [before] in time, and further on in the score than [before] went on from.
  static bool _follows(SyncAnchor a, SyncAnchor before) =>
      a.seconds > before.seconds + 1e-9 && a.quarter > before.departure + 1e-6;

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
      for (final (i, a) in base.indexed) indices.contains(i) ? a.at(a.seconds + applied) : a,
    ]);
    notifyListeners();
    return applied;
  }

  /// Re-points every anchor at [indices] to the next ([direction] > 0) or previous grid point,
  /// e.g. "all of these were one bar off" (a warp's arrival; it still jumps to the same place). Returns false (and changes nothing) if that would
  /// put anchors out of order.
  bool shiftAnchors(Set<int> indices, int direction, SyncGrid grid) {
    if (indices.isEmpty) return false;
    final shifted = [
      for (final (i, a) in _anchors.indexed)
        indices.contains(i) ? a.pointingAt(direction > 0 ? nextGrid(a.quarter, grid) : previousGrid(a.quarter, grid)) : a,
    ];
    if (!_inOrder(shifted)) return false;
    if (indices.every((i) => shifted[i].quarter == _anchors[i].quarter)) return false;
    _anchors = List.unmodifiable(shifted);
    notifyListeners();
    return true;
  }

  /// Removes the anchors at [indices]. Removing a warp takes its jump back (see [setJump]):
  /// the anchors it led to point where they would without it, and any that would then be
  /// past the end of the score go too.
  void removeAnchors(Set<int> indices) {
    if (indices.isEmpty) return;
    var anchors = [..._anchors];
    for (final i in indices.toList()..sort((a, b) => b.compareTo(a))) {
      if (i < 0 || i >= anchors.length) continue;
      final a = anchors[i];
      if (a.isWarp) anchors = _shiftedAfter(anchors, i, a.quarter - a.departure);
      anchors.removeAt(i);
    }
    _anchors = _fitted(anchors);
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

  /// Replaces every anchor and the lead-in (opening a project, or Undo). Anchors out of
  /// order are dropped (see [_fitted]).
  void load(List<SyncAnchor> anchors, {double leadIn = 0}) {
    _leadIn = leadIn;
    _anchors = _fitted([...anchors]..sort((a, b) => a.seconds.compareTo(b.seconds)));
    notifyListeners();
  }
}
