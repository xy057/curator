import 'display_list.dart';
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
      // Everything on screen from a little before the segment starts to a little after it ends.
      final left = scrollMap.xAt(bounds[i] - transition) - visibleLeft;
      final right = scrollMap.xAt(bounds[i + 1] + transition) + visibleRight;

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
  List<double> topsAt(double t) {
    final i = _segmentAt(t);
    final own = _keyframes[i];
    final half = _transition / 2;
    if (half <= 0) return own;

    // Blend towards the neighbouring keyframe inside the transition window of the nearer edge.
    final start = _bounds[i], end = _bounds[i + 1];
    int? other;
    var p = 0.0;
    if (i > 0 && t < start + half && (t - start) <= (end - t)) {
      other = i - 1;
      p = 1 - _smooth(((t - (start - half)) / _transition).clamp(0.0, 1.0));
    } else if (i + 1 < _keyframes.length && t > end - half) {
      other = i + 1;
      p = _smooth(((t - (end - half)) / _transition).clamp(0.0, 1.0));
    }
    if (other == null || p == 0) return own;
    final to = _keyframes[other];
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

  int _segmentAt(double t) => segmentAt(_bounds.length, t, (i) => _bounds[i]).clamp(0, _keyframes.length - 1);

  static double _smooth(double x) => x * x * (3 - 2 * x);
}
