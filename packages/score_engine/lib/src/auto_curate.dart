import 'dart:math' as math;

import 'package:xml/xml.dart';

import 'curation.dart';
import 'score_metadata.dart';
import 'scroll_map.dart';
import 'search.dart';
import 'sounding_notes.dart';

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

/// How much each part's bars ask to be heard, and which bars only double another part: what
/// [fittedCuratedLanes] hides first when the staves don't fit.
///
/// A bar's score (0 silent … 1) is half how melodic it is (the top line's steps, its range,
/// how many notes start), a quarter how exposed (how few other parts sound as each note
/// starts), a quarter its dynamic (the last marking, carried on; mf before any).
class BarSalience {
  BarSalience._(this.scores, this.doubles);

  /// Part id → for each measure, 0 (silent) … 1.
  final Map<String, List<double>> scores;

  /// Part id → for each measure, the parts that play every note it starts there at the same
  /// moments and in the same pitch classes (unison or octaves).
  final Map<String, List<Set<String>>> doubles;

  static const _levels = {
    'pppppp': 0.0, 'ppppp': 0.05, 'pppp': 0.1, 'ppp': 0.15, 'pp': 0.25, 'p': 0.35, 'mp': 0.45, 'mf': 0.55, //
    'f': 0.7, 'ff': 0.85, 'fff': 0.95, 'ffff': 1.0, 'fffff': 1.0, 'ffffff': 1.0,
    'sf': 0.7, 'sfz': 0.75, 'sffz': 0.85, 'sfp': 0.7, 'sfpp': 0.7, 'fp': 0.7, 'fz': 0.7, 'rf': 0.65, 'rfz': 0.7, 'pf': 0.6,
  };

  static BarSalience of(String musicXML, ScoreMetadata metadata, List<double> measureStarts) {
    final bars = math.max(0, measureStarts.length - 1);
    int barOf(double q) => segmentAt(measureStarts.length, q + 1e-6, (i) => measureStarts[i]).clamp(0, math.max(0, bars - 1));
    final ids = [for (final p in metadata.parts) p.id];
    final notes = {for (final id in ids) id: List.generate(bars, (_) => <SoundingNote>[])};
    if (bars > 0) {
      for (final n in soundingNotes(musicXML, measureStarts)) {
        notes[n.partId]?[barOf(n.start)].add(n);
      }
    }

    // The dynamic in force in each bar: the loudest marked in it, else the last before.
    final dynamics = <String, List<double>>{};
    for (final part in XmlDocument.parse(musicXML).rootElement.findElements('part')) {
      final id = part.getAttribute('id') ?? '';
      var level = _levels['mf']!;
      dynamics[id] = [
        for (final measure in part.findElements('measure').take(bars))
          () {
            double? loudest;
            for (final d in measure.findAllElements('dynamics')) {
              for (final mark in d.childElements) {
                final value = _levels[mark.name.local == 'other-dynamics' ? mark.innerText.trim() : mark.name.local];
                if (value == null) continue;
                loudest = math.max(loudest ?? 0, value);
                level = value;
              }
            }
            return loudest ?? level;
          }(),
      ];
    }

    final scores = <String, List<double>>{for (final id in ids) id: List.filled(bars, 0)};
    final doubles = <String, List<Set<String>>>{for (final id in ids) id: List.generate(bars, (_) => <String>{})};
    for (var m = 0; m < bars; m++) {
      final length = math.max(1e-6, measureStarts[m + 1] - measureStarts[m]);
      // What each part starts there: (moment, pitch class).
      final starts = {
        for (final id in ids)
          id: {for (final n in notes[id]![m]) if (!n.tied) ((n.start * 960).round(), n.midi % 12)},
      };
      for (final id in ids) {
        if (metadata.activeMeasures[id]?.elementAtOrNull(m) != true) continue;
        final own = notes[id]![m];
        final dynamic = dynamics[id]?.elementAtOrNull(m) ?? _levels['mf']!;
        if (own.isEmpty) {
          scores[id]![m] = 0.25 * 0.25 + 0.25 * dynamic; // unpitched percussion: no line to follow
          continue;
        }
        // The top line: the highest note starting at each moment.
        final top = <double, int>{};
        for (final n in own) {
          if (!n.tied) top[n.start] = math.max(top[n.start] ?? n.midi, n.midi);
        }
        final line = (top.entries.toList()..sort((a, b) => a.key.compareTo(b.key))).map((e) => e.value).toList();
        var steps = 0.0;
        for (var i = 1; i < line.length; i++) {
          steps += (line[i] - line[i - 1]).abs();
        }
        final motion = line.length < 2 ? 0.0 : math.min(1.0, steps / (line.length - 1) / 4);
        final range = line.isEmpty ? 0.0 : math.min(1.0, (line.reduce(math.max) - line.reduce(math.min)) / 12);
        final density = math.min(1.0, line.length / length / 4);
        final melodic = 0.4 * motion + 0.3 * range + 0.3 * density;

        // Exposed: few other parts sounding as its notes start.
        var exposure = 0.0;
        for (final t in top.keys) {
          var others = 0;
          for (final other in ids) {
            if (other != id && notes[other]![m].any((n) => n.start <= t + 1e-6 && n.end > t + 1e-6)) others++;
          }
          exposure += 1 / (1 + others);
        }
        exposure = top.isEmpty ? 0.5 : exposure / top.length;
        scores[id]![m] = 0.5 * melodic + 0.25 * exposure + 0.25 * dynamic;

        // Doubled: another part starts notes at the same moments (two or more), in the same
        // pitch classes as these.
        final mine = starts[id]!, moments = {for (final (t, _) in mine) t};
        if (moments.length < 2) continue;
        for (final other in ids) {
          if (other == id || !starts[other]!.containsAll(mine)) continue;
          if ({for (final (t, _) in starts[other]!) t}.length == moments.length) doubles[id]![m].add(other);
        }
      }
    }
    return BarSalience._(scores, doubles);
  }

  /// Each pair of [pairs] ([first, second]) as one lane under its first player's id: the
  /// louder of the two in each bar, doubled where what plays there is (each other aside).
  BarSalience condensed(Iterable<List<String>> pairs) {
    final scores = {...this.scores}, doubles = {...this.doubles};
    for (final [a, b] in pairs) {
      final sa = scores[a], sb = scores[b];
      if (sa == null || sb == null) continue;
      scores[a] = [for (var m = 0; m < sa.length; m++) math.max(sa[m], sb.elementAtOrNull(m) ?? 0)];
      final da = doubles[a]!, db = doubles[b]!;
      doubles[a] = [
        for (var m = 0; m < da.length; m++)
          (sa[m] == 0 ? db[m] : sb[m] == 0 ? da[m] : da[m].intersection(db[m])).difference({a, b}),
      ];
    }
    return BarSalience._(scores, doubles);
  }
}

/// The lanes of [partIds] as auto-curation fills them ([autoCurateMeasures]: where each part
/// plays), then, wherever notation would run off the frame ([overflowing], asked of [others]'
/// lanes kept as they are and these), cut back: in each [phrase] bars that overflow, the
/// staff that matters least there ([salience]; a doubling, while what it doubles is shown,
/// counts a quarter, and what plays every note of one hidden counts as much as it does) is
/// hidden, and the frame asked again, until it fits, nothing more can go (one staff left), or
/// [rounds] have been tried. Then, once it fits, each staff hidden is tried back (the one
/// that matters most first, its phrase else bar by bar, [refills] tries at most), kept where
/// the frame still holds it: cut
/// while the segments around were fuller, there may be room for it now. A staff left for a
/// single bar between bars it was hidden for goes too.
Map<String, List<Region>> fittedCuratedLanes({
  required Iterable<String> partIds,
  required Map<String, List<bool>> activeMeasures,
  required List<double> measureStarts,
  required BarSalience salience,
  required ScoreTimeline timeline,
  required List<({double start, double end})> Function(Map<String, List<Region>> lanes) overflowing,
  Map<String, List<Region>> others = const {},
  int phrase = 4,
  int rounds = 32,
  int refills = 96,
}) {
  final bars = math.max(0, measureStarts.length - 1);
  final ids = partIds.toList();
  final shown = {
    for (final id in ids)
      id: () {
        final mask = List.filled(bars, false);
        for (final (first, end) in autoCurateMeasures(activeMeasures[id] ?? const [])) {
          for (var m = first; m < math.min(end, bars); m++) {
            mask[m] = true;
          }
        }
        return mask;
      }(),
  };
  final cut = {for (final id in ids) id: List.filled(bars, false)};
  // The lanes kept as they are, bar by bar (shown at the bar's middle).
  final kept = {
    for (final MapEntry(:key, :value) in others.entries)
      key: [
        for (var m = 0; m < bars; m++)
          value.any((r) => r.start <= (measureStarts[m] + measureStarts[m + 1]) / 2 && r.end > (measureStarts[m] + measureStarts[m + 1]) / 2),
      ],
  };
  bool isShown(String id, int m) => (shown[id] ?? kept[id])?.elementAtOrNull(m) ?? false;

  Map<String, List<Region>> lanes() => {
        for (final id in ids)
          id: [
            for (final (first, end) in autoCurateMeasures(shown[id]!, bridge: 0))
              Region(measureStarts[first], measureStarts[end]),
          ],
      };

  double weight(String id, int m) {
    var s = salience.scores[id]?.elementAtOrNull(m) ?? 0;
    for (final x in ids) {
      if (cut[x]![m] && (salience.doubles[x]?.elementAtOrNull(m)?.contains(id) ?? false)) {
        s = math.max(s, salience.scores[x]![m]);
      }
    }
    final doubled = salience.doubles[id]?.elementAtOrNull(m) ?? const <String>{};
    return doubled.any((d) => isShown(d, m)) ? s / 4 : s;
  }

  int barAt(double seconds) =>
      segmentAt(measureStarts.length, timeline.quarterAtSeconds(seconds), (i) => measureStarts[i]).clamp(0, math.max(0, bars - 1));

  final cuts = <({String id, List<int> bars, double weight})>[];
  var fits = bars == 0;
  for (var round = 0; round < rounds && bars > 0; round++) {
    final off = overflowing({...others, ...lanes()});
    if (off.isEmpty) {
      fits = true;
      break;
    }
    final hit = <int>{};
    for (final s in off) {
      for (var t = s.start; t < s.end; t += 0.1) {
        hit.add(barAt(t));
      }
      hit.add(barAt(s.end));
    }
    // Phrases of up to [phrase] bars of each run that overflows.
    final sorted = hit.toList()..sort();
    final phrases = <List<int>>[];
    for (final (k, m) in sorted.indexed) {
      if (k == 0 || m != sorted[k - 1] + 1 || phrases.last.length == phrase) {
        phrases.add([m]);
      } else {
        phrases.last.add(m);
      }
    }
    var changed = false;
    for (final run in phrases) {
      final candidates = [for (final id in ids) if (run.any((m) => shown[id]![m])) id];
      if (candidates.length < 2) continue;
      String? least;
      var lowest = double.infinity;
      for (final id in candidates) {
        final mine = [for (final m in run) if (shown[id]![m]) weight(id, m)];
        final mean = mine.reduce((a, b) => a + b) / mine.length;
        if (mean < lowest) (least, lowest) = (id, mean);
      }
      final hidden = [for (final m in run) if (shown[least]![m]) m];
      for (final m in hidden) {
        shown[least]![m] = false;
        cut[least]![m] = true;
      }
      cuts.add((id: least!, bars: hidden, weight: lowest));
      changed = true;
    }
    if (!changed) break;
  }
  if (!fits && cuts.isNotEmpty) fits = overflowing({...others, ...lanes()}).isEmpty;

  // Cut while the segments around were fuller: back, the heaviest first, where it still fits.
  if (fits) {
    cuts.sort((a, b) => b.weight.compareTo(a.weight));
    var tries = 0;
    bool tryBack(String id, List<int> bars) {
      final back = [for (final m in bars) if (cut[id]![m]) m];
      if (back.isEmpty || tries++ >= refills) return false;
      void mark(bool on) {
        for (final m in back) {
          shown[id]![m] = on;
          cut[id]![m] = !on;
        }
      }

      mark(true);
      if (overflowing({...others, ...lanes()}).isEmpty) return true;
      mark(false);
      return false;
    }

    // The whole phrase, else bar by bar.
    for (final c in cuts) {
      if (!tryBack(c.id, c.bars) && c.bars.length > 1) {
        for (final m in c.bars) {
          tryBack(c.id, [m]);
        }
      }
    }
  }

  // No staff left showing for one bar between bars it was cut from.
  for (final id in ids) {
    final mask = shown[id]!, gone = cut[id]!;
    for (var m = 0; m < bars; m++) {
      final alone = mask[m] && (m == 0 || !mask[m - 1]) && (m + 1 == bars || !mask[m + 1]);
      if (alone && ((m > 0 && gone[m - 1]) || (m + 1 < bars && gone[m + 1]))) mask[m] = false;
    }
  }
  return lanes();
}
