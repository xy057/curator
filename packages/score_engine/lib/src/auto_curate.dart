/// Where a part's staff is shown when the lanes are filled automatically (on import, and
/// Auto-curate), from the measures it plays in: [playing] has one entry per measure (true =
/// at least one note there).
///
/// The staff is shown for each run of measures the part plays in, and stays through rests of
/// up to [bridge] measures between two runs, so it doesn't vanish for a bar and come straight
/// back (the Instruments tab's tidy menu can bridge longer rests, or drop short runs).
///
/// Returns (first, end) measure ranges, `end` exclusive, ascending and apart.
List<(int, int)> autoCurateMeasures(List<bool> playing, {int bridge = 1}) {
  final ranges = <(int, int)>[];
  int? runStart;
  for (var i = 0; i <= playing.length; i++) {
    final isPlaying = i < playing.length && playing[i];
    if (isPlaying && runStart == null) runStart = i;
    if (!isPlaying && runStart != null) {
      if (ranges.isNotEmpty && runStart - ranges.last.$2 <= bridge) {
        ranges.last = (ranges.last.$1, i);
      } else {
        ranges.add((runStart, i));
      }
      runStart = null;
    }
  }
  return ranges;
}
