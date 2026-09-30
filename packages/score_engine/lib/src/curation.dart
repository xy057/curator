import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'auto_curate.dart';
import 'scroll_map.dart';
import 'search.dart';

/// A stretch of the piece during which one instrument's staff is shown.
/// Stored in score quarters (quarter notes from the start of the performance), so regions
/// stay attached to the music when the audio sync changes.
///
/// A region also has properties of its own (so far its transitions: [transitionIn] at its
/// start, [transitionOut] at its end); null means the curation's. They go with it wherever it
/// is moved, trimmed, split or copied, and a merge keeps each one either region set
/// ([joinedWith]).
@immutable
class Region {
  const Region(this.start, this.end, {this.transitionIn, this.transitionOut})
      : assert(end >= start),
        assert(transitionIn == null || transitionIn >= 0),
        assert(transitionOut == null || transitionOut >= 0);
  final double start;
  final double end;

  /// Seconds for the staff to enter at [start]; null: the curation's [Curation.transition].
  final double? transitionIn;

  /// Seconds for the staff to leave at [end]; null: the curation's [Curation.transition].
  final double? transitionOut;

  double get length => end - start;
  bool overlaps(Region other) => start <= other.end && other.start <= end;

  /// Whether every property is the curation's.
  bool get hasDefaultProperties => transitionIn == null && transitionOut == null;

  /// This region between [start] and [end], with the same properties.
  Region withBounds(double start, double end) => Region(start, end, transitionIn: transitionIn, transitionOut: transitionOut);

  /// This region with its own transitions (null: the curation's) at the edges asked for:
  /// [atStart] ([transitionIn]) and [atEnd] ([transitionOut]).
  Region withTransition(double? seconds, {bool atStart = true, bool atEnd = true}) => Region(start, end,
      transitionIn: atStart ? seconds : transitionIn, transitionOut: atEnd ? seconds : transitionOut);

  /// This region and [later] (which starts no earlier) as one: from this one's start to the
  /// further end. Each edge keeps the transition of the region it came from, else the other's.
  Region joinedWith(Region later) {
    final (last, other) = later.end > end ? (later, this) : (this, later);
    return Region(start, last.end,
        transitionIn: transitionIn ?? later.transitionIn, transitionOut: last.transitionOut ?? other.transitionOut);
  }

  @override
  bool operator ==(Object other) =>
      other is Region &&
      other.start == start &&
      other.end == end &&
      other.transitionIn == transitionIn &&
      other.transitionOut == transitionOut;
  @override
  int get hashCode => Object.hash(start, end, transitionIn, transitionOut);
  @override
  String toString() => 'Region($start–$end'
      '${transitionIn == null ? '' : ', in ${transitionIn}s'}${transitionOut == null ? '' : ', out ${transitionOut}s'})';
}

/// A stretch of playback time a lane is shown, with the seconds it takes to fade in and out.
typedef _Span = ({double start, double end, double fadeIn, double fadeOut});

/// A region edge in playback time, with how long the staves take to glide there.
typedef RegionEdge = ({double seconds, double transition});

/// When each instrument is visible: one lane of non-overlapping regions per part.
///
/// A drag edits live through [updateLanes], which lets regions overlap while they pass over
/// each other; [normalize] merges them when it ends. Undo is kept by whoever owns this (the
/// app keeps one history for the whole document).
class Curation extends ChangeNotifier {
  Curation(Iterable<String> partIds) : _lanes = {for (final id in partIds) id: const []};

  Map<String, List<Region>> _lanes;

  /// Seconds for a staff to enter or leave, centred on the region edge, where the region
  /// doesn't set its own ([Region.transitionIn], [Region.transitionOut]).
  double get transition => _transition;
  double _transition = 0.3;
  set transition(double value) {
    if (value == _transition) return;
    _transition = value;
    notifyListeners();
  }

  Iterable<String> get partIds => _lanes.keys;

  /// Increases on every change, so derived data (like the spacing plan) knows to rebuild.
  int get revision => _revision;
  int _revision = 0;

  @override
  void notifyListeners() {
    _revision++;
    super.notifyListeners();
  }

  /// Seconds for [region]'s staff to enter at its start: its own, or the curation's.
  double transitionInOf(Region region) => region.transitionIn ?? _transition;

  /// Seconds for [region]'s staff to leave at its end: its own, or the curation's.
  double transitionOutOf(Region region) => region.transitionOut ?? _transition;

  /// Every region edge in seconds, all lanes together, each with its region's transition.
  /// The start and end of the piece are not edges: a region there is shown from before bar 1
  /// and after the last bar.
  Iterable<RegionEdge> edgesInSeconds(ScoreTimeline timeline) sync* {
    for (final lane in _lanes.values) {
      for (final (:start, :end, :fadeIn, :fadeOut) in _spans(lane, timeline)) {
        if (start.isFinite) yield (seconds: start, transition: fadeIn);
        if (end.isFinite) yield (seconds: end, transition: fadeOut);
      }
    }
  }

  /// When a lane is shown: each region once in every pass that plays it (see
  /// [ScoreTimeline.passes]), joined where a warp goes on with the lane still shown, so
  /// nothing fades out and in again across the jump. Open-ended where the performance starts
  /// or ends, so nothing fades in on the first bar or out after the last. Each span fades in
  /// and out over the transitions of the regions it starts and ends with.
  List<_Span> _spans(List<Region> lane, ScoreTimeline timeline) {
    final passes = timeline.passes;
    final spans = [
      for (final r in lane)
        for (final s in timeline.spans(r.start, r.end))
          (
            start: s.pass == 0 && s.start <= passes.first.start + 1e-6 ? double.negativeInfinity : s.startSeconds,
            end: s.pass == passes.length - 1 && s.end >= passes.last.end - 1e-6 ? double.infinity : s.endSeconds,
            fadeIn: transitionInOf(r),
            fadeOut: transitionOutOf(r),
          ),
    ];
    if (passes.length == 1) return spans; // regions never touch (see [_normalize])
    spans.sort((a, b) => a.start.compareTo(b.start));
    final joined = <_Span>[];
    for (final s in spans) {
      if (joined.isNotEmpty && s.start <= joined.last.end + 1e-6) {
        final last = joined.last;
        joined.last = s.end > last.end ? (start: last.start, end: s.end, fadeIn: last.fadeIn, fadeOut: s.fadeOut) : last;
      } else {
        joined.add(s);
      }
    }
    return joined;
  }

  List<Region> lane(String partId) => _lanes[partId] ?? const [];

  // MARK: Editing

  /// Replaces a lane. Regions are sorted and overlapping or touching ones merged.
  void setLane(String partId, List<Region> regions) {
    _lanes = _joinedLanes(_lanes, {..._lanes, partId: _normalize(regions)});
    notifyListeners();
  }

  void addRegion(String partId, Region region) => setLane(partId, [...lane(partId), region]);

  void removeRegion(String partId, Region region) =>
      setLane(partId, lane(partId).where((r) => r != region).toList());

  /// Replaces several lanes at once, as one change.
  void setLanes(Map<String, List<Region>> lanes) {
    _lanes = _joinedLanes(
        _lanes, {..._lanes, for (final e in lanes.entries) if (_lanes.containsKey(e.key)) e.key: _normalize(e.value)});
    notifyListeners();
  }

  /// Shows (or, with [shown] false, hides) every lane in [partIds] over [range]: drawing
  /// joins the regions it touches, erasing trims, splits or removes them.
  void paint(Iterable<String> partIds, Region range, {bool shown = true}) =>
      setLanes({for (final id in partIds) id: painted(lane(id), range, shown: shown)});

  /// [regions] with [range] drawn on (or erased).
  static List<Region> painted(List<Region> regions, Region range, {bool shown = true}) {
    if (shown) return [...regions, range];
    return [
      for (final r in regions)
        if (!r.overlaps(range) || range.length <= 0)
          r
        else ...[
          if (r.start < range.start) r.withBounds(r.start, range.start),
          if (r.end > range.end) r.withBounds(range.end, r.end),
        ],
    ];
  }

  /// Joins regions separated by rests of at most [bars] bars, so a staff doesn't vanish
  /// for a moment and come straight back. Acts on [partIds] (all lanes when null).
  void fillGaps(List<double> measureStarts, double bars, {Iterable<String>? partIds}) {
    final ids = partIds ?? _lanes.keys;
    setLanes({
      for (final id in ids)
        id: () {
          final out = <Region>[];
          for (final r in lane(id)) {
            if (out.isNotEmpty && barsBetween(measureStarts, out.last.end, r.start) <= bars + 1e-6) {
              out.last = out.last.joinedWith(r);
            } else {
              out.add(r);
            }
          }
          return out;
        }(),
    });
  }

  /// Removes regions shorter than [bars] bars (a staff flashing up for a single note).
  /// Acts on [partIds] (all lanes when null).
  void removeShort(List<double> measureStarts, double bars, {Iterable<String>? partIds}) {
    final ids = partIds ?? _lanes.keys;
    setLanes({
      for (final id in ids) id: [for (final r in lane(id)) if (barsBetween(measureStarts, r.start, r.end) >= bars - 1e-6) r],
    });
  }

  /// Copies the regions of [from] into each of [to], replacing what they had.
  void copyLane(String from, Iterable<String> to) => setLanes({for (final id in to) id: lane(from)});

  void clearAll() {
    _lanes = {for (final id in _lanes.keys) id: const []};
    notifyListeners();
  }

  /// Fills lanes from where each part actually plays (see [autoCurateMeasures]): [partIds],
  /// or every lane when null.
  void autoCurate(Map<String, List<bool>> activeMeasures, List<double> measureStarts, {Iterable<String>? partIds}) =>
      setLanes(autoCuratedLanes(partIds ?? _lanes.keys, activeMeasures, measureStarts));

  /// The lanes of [partIds] as auto-curation fills them, from where each part plays.
  static Map<String, List<Region>> autoCuratedLanes(
          Iterable<String> partIds, Map<String, List<bool>> activeMeasures, List<double> measureStarts) =>
      {
        for (final id in partIds)
          id: [
            for (final (first, last) in autoCurateMeasures(activeMeasures[id] ?? const []))
              if (last < measureStarts.length) Region(measureStarts[first], measureStarts[last]),
          ],
      };

  /// Live update during a drag: overlaps are kept until [normalize], so regions can pass
  /// over each other while dragging.
  void updateLanes(Map<String, List<Region>> lanes) {
    _lanes = _joinedLanes(
        _lanes,
        {
          ..._lanes,
          for (final e in lanes.entries) e.key: [...e.value]..sort((a, b) => a.start.compareTo(b.start)),
        },
        normalize: false);
    notifyListeners();
  }

  /// Merges what a drag left overlapping or touching (see [updateLanes]).
  void normalize() {
    final normalized = {for (final e in _lanes.entries) e.key: _normalize(e.value)};
    if (sameLanes(normalized, _lanes)) return;
    _lanes = normalized;
    notifyListeners();
  }

  /// Whether two sets of lanes hold the same regions.
  static bool sameLanes(Map<String, List<Region>> a, Map<String, List<Region>> b) =>
      a.length == b.length && a.keys.every((k) => listEquals(a[k], b[k]));

  /// The length from [from] to [to] in bars, counting each bar by its own length (so a
  /// 2/4 bar and a 4/4 bar are both "one bar").
  static double barsBetween(List<double> measureStarts, double from, double to) =>
      _barPosition(measureStarts, to) - _barPosition(measureStarts, from);

  static double _barPosition(List<double> starts, double q) {
    if (starts.length < 2) return 0;
    final lo = segmentAt(starts.length, q, (i) => starts[i]);
    final length = starts[lo + 1] - starts[lo];
    return lo + (length > 0 ? (q - starts[lo]) / length : 0);
  }

  static List<Region> _normalize(List<Region> regions) {
    final sorted = regions.where((r) => r.length > 1e-6).toList()..sort((a, b) => a.start.compareTo(b.start));
    final merged = <Region>[];
    for (final r in sorted) {
      if (merged.isNotEmpty && r.start <= merged.last.end + 1e-6) {
        merged.last = merged.last.joinedWith(r);
      } else {
        merged.add(r);
      }
    }
    return List.unmodifiable(merged);
  }

  // MARK: Joined lanes

  /// Lanes that are one (a condensed pair of players): each follower's id → its leader's.
  /// Joined lanes always hold the same regions: an edit of either is an edit of both.
  Map<String, String> get joined => _joined;
  Map<String, String> _joined = const {};

  /// Joins lanes ([followers]: follower → leader), replacing what was joined. Lanes joined
  /// now show wherever either did; lanes no longer joined keep the regions they had.
  void join(Map<String, String> followers) {
    final next = {
      for (final MapEntry(key: f, value: l) in followers.entries)
        if (f != l && _lanes.containsKey(f) && _lanes.containsKey(l)) f: l,
    };
    if (mapEquals(next, _joined)) return;
    _joined = Map.unmodifiable(next);
    final lanes = _joinedLanes(_lanes, _lanes);
    if (sameLanes(lanes, _lanes)) return;
    _lanes = lanes;
    notifyListeners();
  }

  /// [next] (what [before] becomes) with each pair of joined lanes made the same: the one
  /// that changed, or both together when both did (or neither, but they differ).
  Map<String, List<Region>> _joinedLanes(Map<String, List<Region>> before, Map<String, List<Region>> next,
      {bool normalize = true}) {
    if (_joined.isEmpty) return next;
    final out = {...next};
    for (final MapEntry(key: f, value: l) in _joined.entries) {
      final a = out[f]!, b = out[l]!;
      if (listEquals(a, b)) continue;
      final aChanged = !listEquals(a, before[f]), bChanged = !listEquals(b, before[l]);
      final List<Region> regions;
      if (aChanged != bChanged) {
        regions = aChanged ? a : b;
      } else {
        final both = [...a, ...b];
        regions = normalize ? _normalize(both) : (both..sort((x, y) => x.start.compareTo(y.start)));
      }
      out[f] = regions;
      out[l] = regions;
    }
    return out;
  }

  // MARK: Visibility at playback time

  /// Whether [partId] is inside one of its regions at [seconds] (ignoring the fades).
  bool isShownAt(String partId, double seconds, ScoreTimeline timeline) =>
      _spans(lane(partId), timeline).any((s) => seconds >= s.start && seconds < s.end);

  /// 0…1 for every part at [seconds]. Each region edge is a smooth ramp of that edge's
  /// transition ([transitionInOf], [transitionOutOf]) centred on the edge, so the result is continuous in time.
  /// Regions reaching the start or end of the piece don't fade there.
  Map<String, double> visibilityAt(double seconds, ScoreTimeline timeline) => {
        for (final entry in _lanes.entries)
          entry.key: () {
            var v = 0.0;
            for (final (:start, :end, :fadeIn, :fadeOut) in _spans(entry.value, timeline)) {
              if (seconds < start - fadeIn / 2 || seconds > end + fadeOut / 2) continue;
              v = math.max(v, _smooth(math.min(_ramp(seconds - start, fadeIn), _ramp(end - seconds, fadeOut))));
            }
            return v;
          }(),
      };

  /// 0…1 at [past] seconds past an edge whose ramp lasts [length], centred on it.
  static double _ramp(double past, double length) =>
      length > 0 ? ((past + length / 2) / length).clamp(0.0, 1.0) : (past >= 0 ? 1.0 : 0.0);

  static double _smooth(double t) => t * t * (3 - 2 * t);

  // MARK: Saving

  /// Every lane, by part id.
  Map<String, List<Region>> get lanes => Map.unmodifiable(_lanes);

  /// Replaces every lane (opening a project, or Undo). Lanes for parts this score doesn't
  /// have are ignored; parts without one get none.
  void load(Map<String, List<Region>> lanes, {double? transition}) {
    _lanes = _joinedLanes(_lanes, {for (final id in _lanes.keys) id: _normalize(lanes[id] ?? const [])});
    _transition = transition ?? _transition;
    notifyListeners();
  }
}
