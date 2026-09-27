/// The segment of an ascending sequence that holds [x]: the largest `i < length - 1` with
/// `valueAt(i) <= x`, or 0 when [x] comes before them all (or there are fewer than two).
/// Segment `i` runs from `valueAt(i)` to `valueAt(i + 1)`.
int segmentAt(int length, double x, double Function(int i) valueAt) {
  var lo = 0, hi = length - 1;
  while (hi - lo > 1) {
    final mid = (lo + hi) >> 1;
    if (valueAt(mid) <= x) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return lo;
}
