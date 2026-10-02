import 'dart:math' as math;

import 'curation.dart';
import 'display_list.dart';
import 'frozen_zone.dart';
import 'scroll_map.dart';
import 'search.dart';
import 'staff_stack.dart';

/// One staff of the curated view, in score order.
typedef PlannedStaff = ({int staffIndex, String partId});

/// The vertical layout of the whole piece, planned ahead of playback.
///
/// The curation's region edges split the piece into segments; within a segment the set of
/// shown instruments is fixed. Each segment gets one complete layout (a keyframe), computed
/// only from the instruments shown in it: a hidden instrument takes no room and its ink is
/// never considered, however dense its part is. Each shown staff is sized for the tallest ink
/// that scrolls past during the whole segment, so nothing moves between edges. An instrument
/// on several staves moves as one, its staves as far apart as the engraving put them.
///
/// Around each edge every staff glides from its place in one keyframe to its place in the
/// next over the edge's transition time (its region's; the longest where edges coincide). A
/// staff that enters grows out of the gap it will occupy; one that leaves closes into its
/// gap; one that takes over from its twin (condensing) swaps with it in place. Per frame this
/// is a lookup and a blend.
class SpacingPlan {
  SpacingPlan._(this._bounds, this._keyframes);

  factory SpacingPlan.build({
    required List<StaffLayer> staves,
    required List<PlannedStaff> order,
    required ScrollMap scrollMap,
    required Iterable<RegionEdge> edges,
    required bool Function(String partId, double seconds) isShown,
    required double visibleLeft,
    required double visibleRight,
    required double transition,
    required double scale,
    required StackMetrics metrics,
    Map<int, List<int>> twins = const {},
  }) {
    // An instrument's staves (a piano's two) are laid out as one: they keep the distance the
    // engraving gave them, where cross-staff notes and their ledger lines were placed.
    final units = <List<int>>[];
    for (final (k, s) in order.indexed) {
      if (k > 0 && order[k - 1].partId == s.partId) {
        units.last.add(k);
      } else {
        units.add([k]);
      }
    }
    final offsets = [
      for (final unit in units)
        for (final k in unit) (staves[order[k].staffIndex].info.top - staves[order[unit.first].staffIndex].info.top) * scale,
    ];
    final unitOf = [for (final (u, unit) in units.indexed) ...List.filled(unit.length, u)];
    final unitTwins = {for (final MapEntry(:key, :value) in twins.entries) unitOf[key]: [for (final j in value) unitOf[j]]};

    final bounds = _Bounds.of(edges, scrollMap.duration, transition);
    final keyframes = <List<double>>[];
    for (var i = 0; i + 1 < bounds.length; i++) {
      final middle = (bounds.at[i] + bounds.at[i + 1]) / 2;
      // Everything on screen from a little before the segment starts to a little after it ends
      // (on both sides of a warp, when one jumps in between).
      final (min: from, max: to) = scrollMap.xRange(bounds.at[i] - bounds.transition[i], bounds.at[i + 1] + bounds.transition[i + 1]);
      final left = from - visibleLeft;
      final right = to + visibleRight;

      final shown = [for (final unit in units) isShown(order[unit.first].partId, middle)];
      final slots = [
        for (final (u, unit) in units.indexed)
          () {
            final last = staves[order[unit.last].staffIndex];
            final height = offsets[unit.last] + last.info.height * scale;
            // Ink beyond the unit's outer lines: a staff's ink can reach past its neighbours'.
            var above = 0.0, below = 0.0;
            if (shown[u]) {
              for (final k in unit) {
                final staff = staves[order[k].staffIndex];
                final ink = staff.maxInk(left, right);
                above = math.max(above, ink.above * scale - offsets[k]);
                below = math.max(below, ink.below * scale - (height - offsets[k] - staff.info.height * scale));
              }
            }
            return StaffSlot(height: height, inkAbove: above, inkBelow: below, visibility: shown[u] ? 1 : 0);
          }(),
      ];
      final tops = _parkHidden(StaffStack.layout(slots, metrics), slots, shown, metrics, unitTwins);
      keyframes.add([for (final (k, u) in unitOf.indexed) tops[u] + offsets[k]]);
    }
    return SpacingPlan._(bounds, keyframes);
  }

  final _Bounds _bounds;
  final List<List<double>> _keyframes; // [segment][staff in order]: top line, logical pixels

  /// Top line of every planned staff at playback time [t], logical pixels from the top of
  /// the available area. Hidden staves report where they would appear.
  List<double> topsAt(double t) => _blendAt(_bounds, _keyframes, t);

  /// The keyframe of the segment of [bounds] around [t], blended towards the neighbouring
  /// keyframe inside the transition window of the nearer bound (each bound has its own).
  static List<double> _blendAt(_Bounds bounds, List<List<double>> keyframes, double t) {
    final i = segmentAt(bounds.length, t, (i) => bounds.at[i]).clamp(0, keyframes.length - 1);
    final own = keyframes[i];
    final start = bounds.at[i], end = bounds.at[i + 1];
    final fadeIn = bounds.transition[i], fadeOut = bounds.transition[i + 1];
    final inStart = i > 0 && fadeIn > 0 && t < start + fadeIn / 2;
    final inEnd = i + 1 < keyframes.length && fadeOut > 0 && t > end - fadeOut / 2;
    int? other;
    var p = 0.0;
    if (inStart && (!inEnd || (t - start) <= (end - t))) {
      other = i - 1;
      p = 1 - _smooth(((t - (start - fadeIn / 2)) / fadeIn).clamp(0.0, 1.0));
    } else if (inEnd) {
      other = i + 1;
      p = _smooth(((t - (end - fadeOut / 2)) / fadeOut).clamp(0.0, 1.0));
    }
    if (other == null || p == 0) return own;
    final to = keyframes[other];
    return [for (var k = 0; k < own.length; k++) own[k] + (to[k] - own[k]) * p];
  }

  /// Hidden staves sit centred in the gap between their shown neighbours, so an entering
  /// staff opens out of the right place and a leaving one closes into it. A staff with a
  /// shown twin (a pair's shared staff and its players' own, see CuratedScene) sits on it
  /// instead, so the two swap in place.
  static List<double> _parkHidden(
      List<double> tops, List<StaffSlot> slots, List<bool> shown, StackMetrics metrics, Map<int, List<int>> twins) {
    final result = [...tops];
    for (var k = 0; k < slots.length; k++) {
      if (shown[k]) continue;
      final twin = twins[k]?.where((j) => shown[j]).firstOrNull;
      if (twin != null) {
        result[k] = tops[twin];
        continue;
      }
      double? above, below;
      for (var j = k - 1; j >= 0; j--) {
        if (shown[j]) {
          above = tops[j] + slots[j].height + slots[j].inkBelow;
          break;
        }
      }
      for (var j = k + 1; j < slots.length; j++) {
        if (shown[j]) {
          below = tops[j] - slots[j].inkAbove;
          break;
        }
      }
      final middle = switch ((above, below)) {
        (final a?, final b?) => (a + b) / 2,
        (final a?, null) => a + metrics.minGap,
        (null, final b?) => b - metrics.minGap,
        _ => metrics.availableHeight / 2,
      };
      result[k] = middle - slots[k].height / 2;
    }
    return result;
  }

  static double _smooth(double x) => x * x * (3 - 2 * x);
}

/// Where a plan's segments meet, in playback time, each with the seconds it glides over: from
/// 5 s before the performance to 5 s after it, where edges fall together the longest of their
/// transitions.
class _Bounds {
  _Bounds._(this.at, this.transition);

  factory _Bounds.of(Iterable<RegionEdge> edges, double duration, double transition) {
    final sorted = [
      (seconds: -5.0, transition: transition),
      for (final e in edges)
        if (e.seconds > -5 && e.seconds < duration + 5) e,
      (seconds: duration + 5, transition: transition),
    ]..sort((a, b) => a.seconds.compareTo(b.seconds));
    final at = <double>[], transitions = <double>[];
    for (final e in sorted) {
      if (at.isNotEmpty && e.seconds == at.last) {
        transitions.last = math.max(transitions.last, e.transition);
      } else {
        at.add(e.seconds);
        transitions.add(e.transition);
      }
    }
    return _Bounds._(at, transitions);
  }

  final List<double> at;
  final List<double> transition;
  int get length => at.length;
}

/// How wide the frozen zone's key column is over the whole piece, planned ahead of playback
/// like [SpacingPlan]: only as wide as the widest key signature among the staves shown.
///
/// The piece is split into segments at the curation's region edges, at key changes and around
/// warps. Each segment's column fits every key signature the zone can show while it lasts, on
/// the staves shown in it. Around each bound the column glides from one width to the next over
/// the transition time: with the staves at a region edge (over its region's); ahead of a
/// wider key, so the room is there before the key reaches the zone; after a narrower one has
/// taken over, so the old key is never cut off.
///
/// The zone's right edge moves as the column changes, so which key it shows depends on its
/// width. The plan never asks: it looks at every key the edge could meet at any width, from
/// the narrowest zone ([minReach]) to the widest ([maxReach]), score distances left of the
/// pointer.
class KeyColumnPlan {
  KeyColumnPlan._(this._bounds, this._keyframes);

  factory KeyColumnPlan.build({
    required FrozenZone zone,
    required List<StaffLayer> staves,
    required List<PlannedStaff> order,
    required ScrollMap scrollMap,
    required Iterable<RegionEdge> edges,
    required bool Function(String partId, double seconds) isShown,
    required double minReach,
    required double maxReach,
    required double transition,
  }) {
    final half = transition / 2;
    const margin = 1e-3; // seconds, so a segment reaching up to a key change leaves it out
    final keyBounds = <double>[
      // Widening ends as the widest zone's edge reaches the key; narrowing starts once the
      // narrowest zone's has passed it.
      for (final staff in {for (final s in order) staves[s.staffIndex].info.n})
        for (final (:x, :before, :after) in zone.keyColumnChanges(staff))
          if (after > before)
            for (final t in scrollMap.timesAt(x + maxReach)) t - half - margin
          else
            for (final t in scrollMap.timesAt(x + minReach)) t + half + margin,
      // A warp jumps between keys: wider before it, narrower after.
      for (final w in scrollMap.warpTimes) ...[w - half - margin, w + half + margin],
    ];
    final bounds = _Bounds.of([...edges, for (final t in keyBounds) (seconds: t, transition: transition)], scrollMap.duration, transition);

    final keyframes = <List<double>>[];
    for (var i = 0; i + 1 < bounds.length; i++) {
      final middle = (bounds.at[i] + bounds.at[i + 1]) / 2;
      var column = 0.0;
      for (final (:min, :max) in scrollMap.xStretches(bounds.at[i] - bounds.transition[i] / 2, bounds.at[i + 1] + bounds.transition[i + 1] / 2)) {
        for (final s in order) {
          if (!isShown(s.partId, middle)) continue;
          column = math.max(column, zone.keyColumnIn(staves[s.staffIndex].info.n, min - minReach, max - maxReach));
        }
      }
      keyframes.add([column]);
    }
    return KeyColumnPlan._(bounds, keyframes);
  }

  final _Bounds _bounds;
  final List<List<double>> _keyframes; // [segment][0]: key column, staff spaces

  /// The key column's width at playback time [t], in staff spaces.
  double columnAt(double t) => SpacingPlan._blendAt(_bounds, _keyframes, t).first;
}
