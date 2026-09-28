import 'dart:math' as math;

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
/// that scrolls past during the whole segment, so nothing moves between edges.
///
/// Around each edge every staff glides from its place in one keyframe to its place in the
/// next over the transition time. A staff that enters grows out of the gap it will occupy;
/// one that leaves closes into its gap; one that takes over from its twin (condensing) swaps
/// with it in place. Per frame this is a lookup and a blend.
class SpacingPlan {
  SpacingPlan._(this._bounds, this._keyframes, this._transition);

  factory SpacingPlan.build({
    required List<StaffLayer> staves,
    required List<PlannedStaff> order,
    required ScrollMap scrollMap,
    required Iterable<double> edges,
    required bool Function(String partId, double seconds) isShown,
    required double visibleLeft,
    required double visibleRight,
    required double transition,
    required double scale,
    required StackMetrics metrics,
    Map<int, List<int>> twins = const {},
  }) {
    final duration = scrollMap.duration;
    final bounds = <double>{-5, ...edges.where((e) => e > -5 && e < duration + 5), duration + 5}.toList()..sort();
    final keyframes = <List<double>>[];
    for (var i = 0; i + 1 < bounds.length; i++) {
      final middle = (bounds[i] + bounds[i + 1]) / 2;
      // Everything on screen from a little before the segment starts to a little after it ends
      // (on both sides of a warp, when one jumps in between).
      final (min: from, max: to) = scrollMap.xRange(bounds[i] - transition, bounds[i + 1] + transition);
      final left = from - visibleLeft;
      final right = to + visibleRight;

      final shown = [for (final s in order) isShown(s.partId, middle)];
      final slots = [
        for (final (j, s) in order.indexed)
          () {
            final staff = staves[s.staffIndex];
            final ink = shown[j] ? staff.maxInk(left, right) : (above: 0.0, below: 0.0);
            return StaffSlot(
              height: staff.info.height * scale,
              inkAbove: ink.above * scale,
              inkBelow: ink.below * scale,
              visibility: shown[j] ? 1 : 0,
            );
          }(),
      ];
      final tops = StaffStack.layout(slots, metrics);
      keyframes.add(_parkHidden(tops, slots, shown, metrics, twins));
    }
    return SpacingPlan._(bounds, keyframes, transition);
  }

  final List<double> _bounds;
  final List<List<double>> _keyframes; // [segment][staff in order]: top line, logical pixels
  final double _transition;

  /// Top line of every planned staff at playback time [t], logical pixels from the top of
  /// the available area. Hidden staves report where they would appear.
  List<double> topsAt(double t) => _blendAt(_bounds, _keyframes, _transition, t);

  /// The keyframe of the segment of [bounds] around [t], blended towards the neighbouring
  /// keyframe inside the transition window of the nearer bound.
  static List<double> _blendAt(List<double> bounds, List<List<double>> keyframes, double transition, double t) {
    final i = segmentAt(bounds.length, t, (i) => bounds[i]).clamp(0, keyframes.length - 1);
    final own = keyframes[i];
    final half = transition / 2;
    if (half <= 0) return own;

    final start = bounds[i], end = bounds[i + 1];
    int? other;
    var p = 0.0;
    if (i > 0 && t < start + half && (t - start) <= (end - t)) {
      other = i - 1;
      p = 1 - _smooth(((t - (start - half)) / transition).clamp(0.0, 1.0));
    } else if (i + 1 < keyframes.length && t > end - half) {
      other = i + 1;
      p = _smooth(((t - (end - half)) / transition).clamp(0.0, 1.0));
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

/// How wide the frozen zone's key column is over the whole piece, planned ahead of playback
/// like [SpacingPlan]: only as wide as the widest key signature among the staves shown.
///
/// The piece is split into segments at the curation's region edges, at key changes and around
/// warps. Each segment's column fits every key signature the zone can show while it lasts, on
/// the staves shown in it. Around each bound the column glides from one width to the next over
/// the transition time: with the staves at a region edge; ahead of a wider key, so the room is
/// there before the key reaches the zone; after a narrower one has taken over, so the old key
/// is never cut off.
///
/// The zone's right edge moves as the column changes, so which key it shows depends on its
/// width. The plan never asks: it looks at every key the edge could meet at any width, from
/// the narrowest zone ([minReach]) to the widest ([maxReach]), score distances left of the
/// pointer.
class KeyColumnPlan {
  KeyColumnPlan._(this._bounds, this._keyframes, this._transition);

  factory KeyColumnPlan.build({
    required FrozenZone zone,
    required List<StaffLayer> staves,
    required List<PlannedStaff> order,
    required ScrollMap scrollMap,
    required Iterable<double> edges,
    required bool Function(String partId, double seconds) isShown,
    required double minReach,
    required double maxReach,
    required double transition,
  }) {
    final half = transition / 2;
    const margin = 1e-3; // seconds, so a segment reaching up to a key change leaves it out
    final duration = scrollMap.duration;
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
    final bounds = <double>{
      -5,
      for (final e in [...edges, ...keyBounds])
        if (e > -5 && e < duration + 5) e,
      duration + 5,
    }.toList()
      ..sort();

    final keyframes = <List<double>>[];
    for (var i = 0; i + 1 < bounds.length; i++) {
      final middle = (bounds[i] + bounds[i + 1]) / 2;
      var column = 0.0;
      for (final (:min, :max) in scrollMap.xStretches(bounds[i] - half, bounds[i + 1] + half)) {
        for (final s in order) {
          if (!isShown(s.partId, middle)) continue;
          column = math.max(column, zone.keyColumnIn(staves[s.staffIndex].info.n, min - minReach, max - maxReach));
        }
      }
      keyframes.add([column]);
    }
    return KeyColumnPlan._(bounds, keyframes, transition);
  }

  final List<double> _bounds;
  final List<List<double>> _keyframes; // [segment][0]: key column, staff spaces
  final double _transition;

  /// The key column's width at playback time [t], in staff spaces.
  double columnAt(double t) => SpacingPlan._blendAt(_bounds, _keyframes, _transition, t).first;
}
