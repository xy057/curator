import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'auto_curate.dart';
import 'score_motion.dart';
import 'scroll_map.dart';
import 'search.dart';

/// A stretch of the piece during which one instrument's staff is shown.
/// Stored in score quarters (quarter notes from the start of the performance), so regions
/// stay attached to the music when the audio sync changes.
///
/// A region also has properties of its own: its transitions ([transitionIn] at its start,
/// [transitionOut] at its end; null means the curation's) and which of the instrument's staves
/// it leaves out ([hiddenStaves]). They go with it wherever it is moved, trimmed, split or
/// copied, and a merge keeps each one either region set ([joinedWith]). Regions that hide
/// different staves are never merged: they meet, and the staves glide there.
@immutable
class Region {
  const Region(this.start, this.end, {this.transitionIn, this.transitionOut, this.hiddenStaves = const []})
      : assert(end >= start),
        assert(transitionIn == null || transitionIn >= 0),
        assert(transitionOut == null || transitionOut >= 0);
  final double start;
  final double end;

  /// The instrument's staves it doesn't show, by number in the part (1 its top one), in
  /// order: a piano's left hand left out where the score leaves it out. Never all of them.
  final List<int> hiddenStaves;

  /// Whether it shows staff [n] (1 the part's top one).
  bool showsStaff(int n) => !hiddenStaves.contains(n);

  /// Seconds for the staff to enter at [start]; null: the curation's [Curation.transition].
  final double? transitionIn;

  /// Seconds for the staff to leave at [end]; null: the curation's [Curation.transition].
  final double? transitionOut;

  double get length => end - start;
  bool overlaps(Region other) => start <= other.end && other.start <= end;

  /// Whether every property is the curation's.
  bool get hasDefaultProperties => transitionIn == null && transitionOut == null && hiddenStaves.isEmpty;

  /// This region between [start] and [end], with the same properties.
  Region withBounds(double start, double end) =>
      Region(start, end, transitionIn: transitionIn, transitionOut: transitionOut, hiddenStaves: hiddenStaves);

  /// This region with its own transitions (null: the curation's) at the edges asked for:
  /// [atStart] ([transitionIn]) and [atEnd] ([transitionOut]).
  Region withTransition(double? seconds, {bool atStart = true, bool atEnd = true}) => Region(start, end,
      transitionIn: atStart ? seconds : transitionIn, transitionOut: atEnd ? seconds : transitionOut, hiddenStaves: hiddenStaves);

  /// This region leaving out [staves] (numbers in the part; sorted, each once).
  Region withHiddenStaves(Iterable<int> staves) => Region(start, end,
      transitionIn: transitionIn, transitionOut: transitionOut, hiddenStaves: List.unmodifiable(({...staves}.toList()..sort())));

  /// This region and [later] (which starts no earlier) as one: from this one's start to the
  /// further end. Each edge keeps the transition of the region it came from, else the other's;
  /// the staves left out are this one's.
  Region joinedWith(Region later) {
    final (last, other) = later.end > end ? (later, this) : (this, later);
    return Region(start, last.end,
        transitionIn: transitionIn ?? later.transitionIn,
        transitionOut: last.transitionOut ?? other.transitionOut,
        hiddenStaves: hiddenStaves);
  }

  @override
  bool operator ==(Object other) =>
      other is Region &&
      other.start == start &&
      other.end == end &&
      other.transitionIn == transitionIn &&
      other.transitionOut == transitionOut &&
      listEquals(other.hiddenStaves, hiddenStaves);
  @override
  int get hashCode => Object.hash(start, end, transitionIn, transitionOut, Object.hashAll(hiddenStaves));
  @override
  String toString() => 'Region($start–$end'
      '${transitionIn == null ? '' : ', in ${transitionIn}s'}${transitionOut == null ? '' : ', out ${transitionOut}s'}'
      '${hiddenStaves.isEmpty ? '' : ', without $hiddenStaves'})';
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
    _changed();
  }

  Iterable<String> get partIds => _lanes.keys;

  /// Increases on every change, so derived data (like the spacing plan) knows to rebuild.
  int get revision => _revision;
  int _revision = 0;

  /// The lanes or the transition changed: counts it, and says so.
  void _changed() {
    _revision++;
    notifyListeners();
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
      // Where two regions meet, leaving out different staves.
      for (final (seconds, transition, _, _) in _meetings(lane, timeline)) {
        yield (seconds: seconds, transition: transition);
      }
    }
  }

  /// Every time two regions of [lane] meet (they leave out different staves; see
  /// [_normalize]), once in each pass that plays it: the seconds, the transition (the longer of
  /// the two edges'), and the regions before and after.
  Iterable<(double, double, Region, Region)> _meetings(List<Region> lane, ScoreTimeline timeline) sync* {
    for (var i = 1; i < lane.length; i++) {
      final (a, b) = (lane[i - 1], lane[i]);
      if (b.start > a.end + 1e-6) continue;
      for (final (pass: _, :seconds) in timeline.timesOf(b.start)) {
        yield (seconds, math.max(transitionOutOf(a), transitionInOf(b)), a, b);
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
    // Regions meet only where they leave out different staves ([_normalize]): shown on through.
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

  /// An instrument's lane, or a staff's of one split ([staffLaneId]).
  List<Region> lane(String partId) => switch (staffOfLane(partId)) {
        (final part, final n) => _staffLanes[part]?.elementAtOrNull(n - 1) ?? const [],
        null => _lanes[partId] ?? const [],
      };

  // MARK: Editing

  /// Replaces a lane (an instrument's, or a staff's of one split). Regions are sorted and
  /// overlapping or touching ones merged.
  void setLane(String partId, List<Region> regions) => _apply({partId: regions}, normalize: true, adding: true);

  /// [lanes] put in (instruments' or split staves' [staffLaneId]): sorted, and with [normalize]
  /// merged ([_normalize]); [adding] takes on lanes not here yet (a spacer's). A staff's lane
  /// changes its instrument's (each region leaving out the staves not shown then, [_combined]),
  /// and an instrument's its staves' ([_projected]).
  void _apply(Map<String, List<Region>> lanes, {required bool normalize, bool adding = false}) {
    List<Region> tidy(List<Region> regions) =>
        normalize ? _normalize(regions) : List.unmodifiable([...regions]..sort((a, b) => a.start.compareTo(b.start)));
    final next = {..._lanes};
    final staves = {for (final MapEntry(:key, :value) in _staffLanes.entries) key: [...value]};
    final combined = <String>{};
    for (final MapEntry(key: id, value: regions) in lanes.entries) {
      if (staffOfLane(id) case (final part, final n)) {
        final lanes = staves[part];
        if (lanes == null || n < 1 || n > lanes.length) continue;
        lanes[n - 1] = tidy([for (final r in regions) r.hiddenStaves.isEmpty ? r : r.withHiddenStaves(const [])]);
        combined.add(part);
      } else if (adding || _lanes.containsKey(id)) {
        next[id] = tidy(regions);
        if (staves[id] case final lanes?) staves[id] = _projected(next[id]!, lanes.length);
      }
    }
    for (final part in combined) {
      next[part] = _combined(staves[part]!);
    }
    _lanes = _joinedLanes(_lanes, next, normalize: normalize);
    _staffLanes = {for (final MapEntry(:key, :value) in staves.entries) key: List.unmodifiable(value)};
    _changed();
  }

  // MARK: Split lanes

  /// The lane of staff [n] (from 1) of [partId], once its lane is split ([setSplit]).
  /// (A part's id is an XML name: it has no `/`.)
  static String staffLaneId(String partId, int n) => '$partId/$n';

  /// A staff's lane's instrument and staff ([staffLaneId]); null for an instrument's lane.
  static (String, int)? staffOfLane(String id) {
    final at = id.lastIndexOf('/');
    final n = at < 0 ? null : int.tryParse(id.substring(at + 1));
    return n == null ? null : (id.substring(0, at), n);
  }

  /// The instruments whose lane is split into one a staff, each with its staves' count. Their
  /// own lanes stay what is shown (each region leaving out the staves not shown then); the
  /// staves' are another way of setting them.
  Map<String, int> get split => {for (final MapEntry(:key, :value) in _staffLanes.entries) key: value.length};
  Map<String, List<List<Region>>> _staffLanes = const {};

  /// Splits the lanes of [counts] (part id → its staves; fewer than two: joined), joining any
  /// other split. Each staff's lane shows where its instrument's shows it. Nothing shown changes.
  void setSplit(Map<String, int> counts) {
    final next = {
      for (final MapEntry(key: id, value: count) in counts.entries)
        if (count > 1 && _lanes.containsKey(id))
          id: _staffLanes[id]?.length == count ? _staffLanes[id]! : _projected(_lanes[id]!, count),
    };
    if (mapEquals(split, {for (final MapEntry(:key, :value) in next.entries) key: value.length})) return;
    _staffLanes = next;
    _changed();
  }

  /// [lane] as each of its [count] staves' lanes: where it is shown (its transitions, where it
  /// starts and ends).
  static List<List<Region>> _projected(List<Region> lane, int count) => List.unmodifiable([
        for (var n = 1; n <= count; n++)
          _normalize([
            for (final r in lane)
              if (r.showsStaff(n)) Region(r.start, r.end, transitionIn: r.transitionIn, transitionOut: r.transitionOut),
          ]),
      ]);

  /// An instrument's lane from its staves' [lanes]: a region for each stretch some are shown,
  /// leaving out the others ([Region.hiddenStaves]); each edge takes the transition of a staff
  /// starting or ending there.
  static List<Region> _combined(List<List<Region>> lanes) {
    final cuts = <double>{
      for (final lane in lanes)
        for (final r in lane) ...[r.start, r.end],
    }.toList()
      ..sort();
    final out = <Region>[];
    for (var i = 0; i + 1 < cuts.length; i++) {
      final (a, b) = (cuts[i], cuts[i + 1]);
      if (b - a <= 1e-9) continue;
      final middle = (a + b) / 2;
      final hidden = <int>[];
      double? fadeIn, fadeOut;
      for (final (k, lane) in lanes.indexed) {
        final r = lane.where((r) => r.start <= middle && r.end > middle).firstOrNull;
        if (r == null) {
          hidden.add(k + 1);
          continue;
        }
        if (r.start == a) fadeIn ??= r.transitionIn;
        if (r.end == b) fadeOut ??= r.transitionOut;
      }
      if (hidden.length == lanes.length) continue;
      out.add(Region(a, b, transitionIn: fadeIn, transitionOut: fadeOut).withHiddenStaves(hidden));
    }
    return _normalize(out);
  }

  void addRegion(String partId, Region region) => setLane(partId, [...lane(partId), region]);

  /// Replaces several lanes at once (instruments' or split staves'), as one change.
  void setLanes(Map<String, List<Region>> lanes) => _apply(lanes, normalize: true);

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
    _staffLanes = {for (final MapEntry(:key, :value) in _staffLanes.entries) key: List.unmodifiable([for (final _ in value) const <Region>[]])};
    _changed();
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
  void updateLanes(Map<String, List<Region>> lanes) => _apply(lanes, normalize: false, adding: true);

  /// Merges what a drag left overlapping or touching (see [updateLanes]).
  void normalize() {
    final normalized = {for (final e in _lanes.entries) e.key: _normalize(e.value)};
    final staves = {
      for (final MapEntry(:key, :value) in _staffLanes.entries) key: List<List<Region>>.unmodifiable(value.map(_normalize)),
    };
    if (sameLanes(normalized, _lanes) &&
        _staffLanes.keys.every((k) => [for (var n = 0; n < staves[k]!.length; n++) listEquals(staves[k]![n], _staffLanes[k]![n])].every((same) => same))) {
      return;
    }
    _lanes = normalized;
    _staffLanes = staves;
    _changed();
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

  /// [regions] sorted, and those that overlap or meet made one; but of two that leave out
  /// different staves, the later one only goes on past the earlier one's end, meeting it.
  static List<Region> _normalize(List<Region> regions) {
    final sorted = regions.where((r) => r.length > 1e-6).toList()..sort((a, b) => a.start.compareTo(b.start));
    final merged = <Region>[];
    for (final r in sorted) {
      final last = merged.lastOrNull;
      if (last == null || r.start > last.end + 1e-6) {
        merged.add(r);
      } else if (listEquals(r.hiddenStaves, last.hiddenStaves)) {
        merged.last = last.joinedWith(r);
      } else if (r.end > last.end + 1e-6) {
        merged.add(r.withBounds(last.end, r.end));
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
    _reproject();
    _changed();
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
  /// Regions reaching the start or end of the piece don't fade there. [curve] shapes each ramp.
  Map<String, double> visibilityAt(double seconds, ScoreTimeline timeline, {MotionCurve curve = MotionCurve.smooth}) => {
        for (final entry in _lanes.entries)
          entry.key: () {
            var v = 0.0;
            for (final (:start, :end, :fadeIn, :fadeOut) in _spans(entry.value, timeline)) {
              if (seconds < start - fadeIn / 2 || seconds > end + fadeOut / 2) continue;
              v = math.max(v, curve.inside(math.min(_ramp(seconds - start, fadeIn), _ramp(end - seconds, fadeOut))));
            }
            return v;
          }(),
      };

  /// The staves of [partId] the region shown at [seconds] leaves out ([Region.hiddenStaves]):
  /// the nearest region's between regions, and before or after the performance (where one
  /// reaching its start or end goes on showing).
  List<int> hiddenStavesAt(String partId, double seconds, ScoreTimeline timeline) {
    final lane = this.lane(partId);
    if (lane.every((r) => r.hiddenStaves.isEmpty)) return const [];
    return (_regionAt(lane, seconds, timeline) ?? _nearestRegion(lane, seconds, timeline))?.hiddenStaves ?? const [];
  }

  /// 0…1: how much of staff [n] of [partId] shows at [seconds], as far as its regions say
  /// ([Region.hiddenStaves]; [visibilityAt] says how much the instrument shows). Where two
  /// regions meet, a staff one leaves out and the other shows fades over the transition there,
  /// centred on it; [curve] shapes the fade.
  double staffVisibilityAt(String partId, int n, double seconds, ScoreTimeline timeline,
      {MotionCurve curve = MotionCurve.smooth}) {
    final lane = this.lane(partId);
    if (lane.every((r) => r.hiddenStaves.isEmpty)) return 1;
    for (final (at, transition, a, b) in _meetings(lane, timeline)) {
      if (a.showsStaff(n) == b.showsStaff(n) || (seconds - at).abs() > transition / 2) continue;
      final p = curve.inside(_ramp(seconds - at, transition));
      return b.showsStaff(n) ? p : 1 - p;
    }
    return (_regionAt(lane, seconds, timeline) ?? _nearestRegion(lane, seconds, timeline))?.showsStaff(n) ?? true ? 1 : 0;
  }

  /// The region of [lane] playing at [seconds], in whichever pass.
  Region? _regionAt(List<Region> lane, double seconds, ScoreTimeline timeline) {
    for (final r in lane) {
      for (final s in timeline.spans(r.start, r.end)) {
        if (seconds >= s.startSeconds && seconds < s.endSeconds) return r;
      }
    }
    return null;
  }

  /// The region of [lane] nearest [seconds], whose staves fade in or out with it.
  Region? _nearestRegion(List<Region> lane, double seconds, ScoreTimeline timeline) {
    Region? best;
    var distance = double.infinity;
    for (final r in lane) {
      for (final s in timeline.spans(r.start, r.end)) {
        final d = seconds < s.startSeconds ? s.startSeconds - seconds : seconds - s.endSeconds;
        if (d < distance) (best, distance) = (r, d);
      }
    }
    return best;
  }

  /// 0…1 at [past] seconds past an edge whose ramp lasts [length], centred on it.
  static double _ramp(double past, double length) =>
      length > 0 ? ((past + length / 2) / length).clamp(0.0, 1.0) : (past >= 0 ? 1.0 : 0.0);

  // MARK: Saving

  /// Every lane, by part id.
  Map<String, List<Region>> get lanes => Map.unmodifiable(_lanes);

  /// Replaces every lane (opening a project, or Undo). Lanes for parts this score doesn't
  /// have are ignored; parts without one get none.
  void load(Map<String, List<Region>> lanes, {double? transition}) {
    _lanes = _joinedLanes(_lanes, {for (final id in _lanes.keys) id: _normalize(lanes[id] ?? const [])});
    _reproject();
    _transition = transition ?? _transition;
    _changed();
  }

  /// The split staves' lanes made again from their instruments' (which were replaced).
  void _reproject() =>
      _staffLanes = {for (final MapEntry(:key, :value) in _staffLanes.entries) key: _projected(_lanes[key] ?? const [], value.length)};
}
