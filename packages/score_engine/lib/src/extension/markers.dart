import '../scroll_map.dart';

/// A marker as it sounds: [marker] (an index into the places; -1: the music before the first)
/// from [start] to [end] seconds.
typedef MarkerSpan = ({int marker, double start, double end});

/// Markers (places in the score, in quarters, each running to the next: chapters) in time, in
/// order: at any moment the marker is the last one at or before the place in the score that
/// sounds, so a repeat back into an earlier one is that one again, and a repeat inside a single
/// one doesn't split it. They cover the whole performance: the first from 0 (the silence before
/// the music is its), the last to [end] seconds (the end of the music by default). Empty
/// without markers. What a markers lane draws, and `score.spans` in an extension's Lua.
List<MarkerSpan> markerSpans(List<double> places, ScoreTimeline timeline, {double? end}) {
  if (places.isEmpty) return const [];
  final order = [for (var i = 0; i < places.length; i++) i]..sort((a, b) {
      final by = places[a].compareTo(places[b]);
      return by != 0 ? by : a.compareTo(b);
    });
  final out = <MarkerSpan>[];
  void add(int marker, double start, double end) {
    if (end - start <= 1e-6) return;
    if (out.lastOrNull case final last? when last.marker == marker) {
      out[out.length - 1] = (marker: marker, start: last.start, end: end);
    } else {
      out.add((marker: marker, start: start, end: end));
    }
  }

  for (final (k, p) in timeline.passes.indexed) {
    double seconds(double q) => timeline.secondsAtQuarter(q, pass: k);
    var from = p.start, current = -1;
    for (final i in order) {
      final at = places[i];
      if (at >= p.end - 1e-9) break;
      if (at > p.start + 1e-9) {
        add(current, seconds(from), seconds(at));
        from = at;
      }
      current = i;
    }
    add(current, seconds(from), seconds(p.end));
  }
  if (out.isEmpty) return out;
  if (out.first.start > 0) out[0] = (marker: out.first.marker, start: 0, end: out.first.end);
  end ??= timeline.endSeconds;
  if (end > out.last.end) out[out.length - 1] = (marker: out.last.marker, start: out.last.start, end: end);
  return out;
}
