import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'pdf_detect.dart';
import 'pdf_layout.dart';
import 'pdf_text.dart';
import 'spacers.dart' show SpacerKey;

/// How a page of a PDF score is shown to an AI model ([PdfAi.prompt]): the page, then a column at
/// its right where each staff found has its number ([PdfAi.labels]), level with it. The answer's
/// positions are thousandths of that picture, across and down.
class PdfAiView {
  PdfAiView(this.page) : column = math.max(28.0, page.width * 0.06);

  /// The page's size, points.
  final ui.Size page;

  /// How wide the column of numbers is, points.
  final double column;

  /// The picture's width, points: the page and its column.
  double get width => page.width + column;

  /// Thousandths of the picture as page points.
  double x(double thousandths) => thousandths / 1000 * width;
  double y(double thousandths) => thousandths / 1000 * page.height;
}

/// A clef or key change inside a system, on one staff, at the system's bar it takes effect
/// (counted from 1 at the system's start, by the answer's barlines).
typedef PdfAiChange = ({int bar, PdfClef? clef, int? key});

/// What an AI model read of one staff found ([PdfAi.labels]' number): whose it is, and its clef
/// and key at its system's start.
class PdfAiStaff {
  const PdfAiStaff({
    required this.label,
    this.instrument,
    this.staff = 1,
    this.name = '',
    this.printed = '',
    this.clef,
    this.key,
    this.changes = const [],
    this.y,
  });

  final int label;

  /// Where the answer places its middle line, thousandths: what its other places are measured
  /// against ([PdfAi.refine]).
  final double? y;

  /// An instrument's id ([PdfInstrument.id]), as the prompt listed them; null: none of them.
  final String? instrument;

  /// Which of its instrument's staves it is (a piano's lower one 2), or of a section's
  /// divisions, from 1.
  final int staff;

  /// Its instrument's name in full, and what the page prints beside this staff.
  final String name, printed;
  final PdfClef? clef;

  /// The key signature as printed on it: sharps up from 0, flats down.
  final int? key;
  final List<PdfAiChange> changes;
}

/// Where one staff's part ends and the next one's begins: below staff [below] (its number), at
/// [y], or a gap there that is no one's ([gap], its top and bottom). Thousandths.
typedef PdfAiBorder = ({int below, double? y, (double, double)? gap});

/// What an AI model read of one system: its staves, its edges and borders, its barlines, and the
/// time signatures and tempo marks printed in it. Positions are thousandths ([PdfAiView]); bars
/// are counted from 1 at its start by its [barlines].
class PdfAiSystem {
  const PdfAiSystem({
    this.staves = const [],
    this.top,
    this.bottom,
    this.borders = const [],
    this.barlines,
    this.time,
    this.times = const [],
    this.tempos = const [],
  });

  final List<PdfAiStaff> staves;
  final double? top, bottom;
  final List<PdfAiBorder> borders;

  /// Left to right; null when the answer gave none.
  final List<({double x, PdfBarlineKind? kind})>? barlines;

  /// The time signature at its start, when one is printed there.
  final PdfMeter? time;
  final List<({int bar, PdfMeter meter})> times;
  final List<({int bar, PdfTempo tempo})> tempos;
}

/// An AI model's answer about one page ([PdfAi.prompt]): its systems, top to bottom.
class PdfAiPage {
  const PdfAiPage(this.systems);
  final List<PdfAiSystem> systems;

  /// What it read of staff [label].
  PdfAiStaff? staff(int label) {
    for (final s in systems) {
      for (final t in s.staves) {
        if (t.label == label) return t;
      }
    }
    return null;
  }

  /// The answer in [text]: a JSON object, alone or among words (a code fence around it). What
  /// isn't as asked is passed over; a [FormatException] when there is no such object at all.
  static PdfAiPage parse(String text) {
    final from = text.indexOf('{'), to = text.lastIndexOf('}');
    Object? json;
    if (from >= 0 && to > from) {
      try {
        json = jsonDecode(text.substring(from, to + 1));
      } on FormatException {
        json = null;
      }
    }
    final systems = switch (json) {
      {'systems': final List list} => list,
      _ => throw const FormatException('The answer isn’t the JSON asked for.'),
    };
    return PdfAiPage([for (final s in systems) if (s is Map) _system(s)]);
  }

  static PdfAiSystem _system(Map s) => PdfAiSystem(
        staves: [for (final t in _maps(s['staves'])) ?_staff(t)],
        top: _num(s['top']),
        bottom: _num(s['bottom']),
        borders: [
          for (final b in _maps(s['borders']))
            if (_int(b['below']) case final below?)
              (
                below: below,
                y: _num(b['y']),
                gap: switch (b['gap']) {
                  [final a, final b] when _num(a) != null && _num(b) != null => (_num(a)!, _num(b)!),
                  _ => null,
                },
              ),
        ],
        barlines: s['barlines'] is List
            ? [
                for (final b in s['barlines'] as List)
                  if (_num(b is Map ? b['x'] : b) case final x?) (x: x, kind: b is Map ? _kind(b['kind']) : null),
              ]
            : null,
        time: _meter(s['time']),
        times: [
          for (final t in _maps(s['times']))
            if (_meter(t['time']) case final meter?) (bar: math.max(1, _int(t['bar']) ?? 1), meter: meter),
        ],
        tempos: [for (final t in _maps(s['tempos'])) ?_tempo(t)],
      );

  static PdfAiStaff? _staff(Map t) {
    final label = _int(t['label']);
    if (label == null || label < 1) return null;
    return PdfAiStaff(
      label: label,
      instrument: switch (t['instrument']) { final String id when id.trim().isNotEmpty => id.trim(), _ => null },
      staff: (_int(t['staff']) ?? 1).clamp(1, 4),
      name: _text(t['name']),
      printed: _text(t['printed']),
      clef: _clef(t['clef']),
      key: _key(t['key']),
      y: _num(t['y']),
      changes: [
        for (final c in _maps(t['changes']))
          if (_clef(c['clef']) != null || _key(c['key']) != null)
            (bar: math.max(1, _int(c['bar']) ?? 1), clef: _clef(c['clef']), key: _key(c['key'])),
      ],
    );
  }

  static ({int bar, PdfTempo tempo})? _tempo(Map t) {
    final words = _text(t['text']);
    final bpm = switch (_num(t['bpm'])) { final b? when b >= 10 && b <= 1000 => b, _ => null };
    if (words.isEmpty && bpm == null) return null;
    return (bar: math.max(1, _int(t['bar']) ?? 1), tempo: PdfTempo(words, bpm));
  }

  static Iterable<Map> _maps(Object? v) => v is List ? v.whereType<Map>() : const [];

  static double? _num(Object? v) => switch (v) {
        final num n when n.isFinite => n.toDouble(),
        final String s => double.tryParse(s.trim()),
        _ => null,
      };

  static int? _int(Object? v) => _num(v)?.round();

  static String _text(Object? v) => v is String ? PdfText.clean(v) : '';

  static int? _key(Object? v) => switch (_int(v)) { final k? when k >= -7 && k <= 7 => k, _ => null };

  static PdfClef? _clef(Object? v) {
    if (v is! String) return null;
    final s = v.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return switch (s) {
      'treble' || 'g' || 'violin' || 'g2' => PdfClef.treble,
      'treble8vb' || 'treble8' || 'g8vb' || 'g8' || 'tenorg' || 'vocaltenor' || 'treble8vabassa' => PdfClef.treble8vb,
      'alto' || 'c3' || 'c' => PdfClef.alto,
      'tenor' || 'c4' => PdfClef.tenor,
      'bass' || 'f' || 'f4' => PdfClef.bass,
      'percussion' || 'neutral' || 'perc' => PdfClef.percussion,
      _ => null,
    };
  }

  static PdfBarlineKind? _kind(Object? v) {
    if (v is! String) return null;
    return switch (v.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '')) {
      'single' || 'normal' || 'regular' => PdfBarlineKind.normal,
      'double' || 'lightlight' => PdfBarlineKind.double,
      'final' || 'end' || 'lightheavy' => PdfBarlineKind.end,
      'repeatstart' || 'startrepeat' => PdfBarlineKind.repeatStart,
      'repeatend' || 'endrepeat' => PdfBarlineKind.repeatEnd,
      'repeatboth' || 'endstartrepeat' || 'repeatendstart' => PdfBarlineKind.repeatBoth,
      _ => null,
    };
  }

  static PdfMeter? _meter(Object? v) {
    if (v is! String) return null;
    final s = v.trim();
    if (s == 'C' || s == 'c' || s == '𝄴') return PdfMeter.common;
    if (s == 'C|' || s == '¢' || s == '𝄵') return const PdfMeter('2', 2);
    return PdfMeter.parse(s);
  }
}

/// One system of a page as an AI model's answer set it ([PdfAi.refine]): the staves found that
/// are its ([PdfAi.labels]' numbers), the answer's system it is (null: none), and where the
/// answer's bars start, points (its start, then its barlines as the answer placed them).
typedef PdfAiSystemRead = ({PdfSystem system, List<int> labels, int? answer, List<double> starts});

/// A page read by an AI model: its answer, and the page's systems as it sets them.
typedef PdfAiPageRead = ({int page, PdfAiPage answer, List<PdfAiSystemRead> systems});

/// Reading a PDF score's pages with an AI model: what it is asked ([prompt], about a picture of
/// the page with its staves numbered, [labels]), and what its answer sets ([refine] on the page's
/// ink, then [apply] to the layout). Its positions are rough: every edge, cut and barline it
/// gives is placed on the ink near it (a row nothing crosses, a line through the staves); what
/// it names (instruments, clefs, keys, meters, tempo marks) is taken as said.
abstract final class PdfAi {
  /// Each staff of [systems] (one page's), numbered from 1 top to bottom: where it is (its
  /// middle, points) and its staff space.
  static List<({int label, double y, double space})> labels(List<PdfSystem> systems) {
    var n = 0;
    return [
      for (final s in systems)
        for (final t in s.staves) (label: ++n, y: t.middle, space: t.space),
    ];
  }

  /// How far right the second picture reaches, points: past where every system's music starts
  /// (the names, clefs, keys and time signatures at their left).
  static double startsRight(List<PdfSystem> systems, double width) =>
      math.min(width, systems.fold(0.0, (r, s) => math.max(r, s.left + s.space * 3)));

  /// What a model is asked about a page whose staves found are numbered 1 to [staves]
  /// ([labels]), the score's [instruments] listed for it to say whose each is; [first]: the page
  /// they were taken from (its staves are theirs, in order).
  static String prompt({required List<PdfInstrument> instruments, required int staves, bool first = false}) {
    final list = [
      for (final i in instruments)
        if (!i.blank) '${i.id}: ${i.name}${i.abbreviation.isEmpty ? '' : ' (${i.abbreviation})'}${i.staves > 1 ? ', ${i.staves} staves' : ''}',
    ].join('\n');
    final from = first
        ? 'This is the page they were taken from: its staves are these instruments in this order, top to bottom '
            '(an instrument of two staves takes two). A name like "Staff 3" stands for one not named yet.\n'
        : '';
    return '''
You are reading one page of a printed music score for a program that cuts the score into its staves.

Image 1 is the page. At its right is a column where each staff the program found has its number in red, level with the staff: they are 1 to $staves, top to bottom. Image 2 is the left part of the page enlarged (each system's start: instrument names, clefs, key and time signatures), with the same numbers at its right.

Positions are thousandths of image 1 (its column included): x from its left edge (0) to its right edge (1000), y from its top (0) to its bottom (1000).

The score's instruments, by id:
$list
$from
Answer with one JSON object and nothing else, like this:
{"systems": [{
  "staves": [{"label": 1, "y": 152, "instrument": "P1", "staff": 1, "name": "Flute", "printed": "Fl.", "clef": "treble", "key": -1, "changes": [{"bar": 3, "clef": "bass"}, {"bar": 5, "key": 2}]}],
  "top": 120, "bottom": 410,
  "borders": [{"below": 1, "y": 180}, {"below": 2, "y": 250, "gap": [242, 258]}],
  "barlines": [{"x": 310, "kind": "single"}, {"x": 905, "kind": "final"}],
  "time": "3/4",
  "times": [{"bar": 4, "time": "2/4"}],
  "tempos": [{"bar": 1, "text": "Allegro", "bpm": 120}]
}]}

- "systems": the page's systems, top to bottom (staves played together, joined at their left). Every staff number goes in one system.
- "y": where the staff's middle line is.
- "instrument": the id of the instrument the staff is, from the list, by the name or abbreviation printed left of it (a staff with none is the instrument it continues); null when it is none of them. "staff": which of the instrument's staves it is, from 1 (a piano's lower staff is 2; a section divided onto several staves: 2, 3… for the further ones).
- "name": the instrument's full name as the score prints it where it first appears (not an abbreviation). "printed": what is printed left of this staff on this page, or "".
- "clef": the clef at the system's start: "treble", "treble8vb" (an 8 below it), "alto", "tenor", "bass" or "percussion". "key": the key signature there as printed on this staff, sharps positive, flats negative, 0 for none.
- "changes": clef or key changes inside the system on this staff, at the bar they take effect. A courtesy clef, key or time signature at a system's end is not one.
- "bar": a bar of the system, counted from 1 at its start by the barlines you give.
- "top", "bottom": where what belongs to the system begins and ends: its staves and everything printed with them (tempo marks, dynamics, lyrics, bar numbers), not the page's title, headers, footers or page number, nor the next system's marks.
- "borders": between each staff and the one below ("below": the upper one's number), where one's ink ends and the other's begins, so that dynamics, lyrics and markings go with the staff they belong to. "gap": a line of text there belonging to neither staff (a tempo mark repeated inside the system), its top and bottom; leave it out when there is none.
- "barlines": every barline past the clefs, keys and time signatures at the start, left to right, the one ending the system included; "kind": "single", "double", "final", "repeat-start", "repeat-end" or "repeat-both". Stems and other strokes are not barlines.
- "time": the time signature at the system's start, null when none is printed there; "times": those inside it.
- "tempos": tempo marks and changes printed above the system (Allegro, rit., a tempo, ♩ = 96): the words as printed, and "bpm", the metronome mark in quarter notes a minute, or null.
''';
  }

  /// One page's [systems] as [answer] sets them, placed on its ink ([raster], the whole page):
  /// staves joined into systems as it says (two found apart joined only where their bars line
  /// up), each system's top and bottom and the cuts and gaps between its staves at the rows
  /// nothing crosses nearest where it says, and its barlines those found nearest the ones it
  /// gives, else a line through the staves there (one with none there is passed over). What it
  /// doesn't give stays as found. Each system is to be measured again.
  static List<PdfAiSystemRead> refine(PdfRaster raster, List<PdfSystem> systems, PdfAiPage answer, PdfAiView view) {
    final found = [
      for (final (i, s) in systems.indexed)
        for (final (k, t) in s.staves.indexed) (system: i, index: k, staff: t),
    ];
    final n = found.length;
    if (n == 0) return const [];
    // The answer's system each staff is in; one it left out goes with the staff above it.
    final named = List<int?>.filled(n, null);
    for (final (g, s) in answer.systems.indexed) {
      for (final t in s.staves) {
        if (t.label >= 1 && t.label <= n) named[t.label - 1] ??= g;
      }
    }
    final group = [...named];
    final first = named.whereType<int>().firstOrNull;
    var ordered = first != null;
    for (var k = 0; k < n && ordered; k++) {
      group[k] ??= k == 0 ? first : group[k - 1];
      if (k > 0 && group[k]! < group[k - 1]!) ordered = false;
    }
    // Runs of staves, each a system.
    final runs = <({List<int> staves, int? answer})>[];
    if (ordered) {
      for (var k = 0; k < n; k++) {
        final apart = k > 0 &&
            found[k].system != found[k - 1].system &&
            !_aligned(systems[found[k - 1].system], systems[found[k].system]);
        if (k == 0 || group[k] != group[k - 1] || apart) {
          runs.add((staves: [k], answer: group[k]));
        } else {
          runs.last.staves.add(k);
        }
      }
    } else {
      // Systems as found, each the answer's that most of its staves are in.
      for (final (i, _) in systems.indexed) {
        final staves = [for (var k = 0; k < n; k++) if (found[k].system == i) k];
        if (staves.isEmpty) continue;
        final counts = <int, int>{};
        for (final k in staves) {
          if (named[k] case final g?) counts.update(g, (c) => c + 1, ifAbsent: () => 1);
        }
        final most = counts.entries.fold<MapEntry<int, int>?>(null, (b, e) => b == null || e.value > b.value ? e : b);
        runs.add((staves: staves, answer: most?.key));
      }
    }
    // A model's places drift, or are made up: where it says the staves are, against where they
    // are, sets right where it says the rest are (a line through the pairs, those far off left
    // out), or, far from them, says its places are no good (none of them is taken then).
    final pairs = [
      for (final (k, f) in found.indexed)
        if (answer.staff(k + 1)?.y case final y?) (view.y(y), f.staff.middle),
    ];
    final fit = PdfAi.fit(pairs, n, systems.first.space);
    double down(double thousandths) => view.y(thousandths) * fit.scale + fit.shift;
    final out = <PdfAiSystemRead>[];
    var above = 0.0; // where the system before ends, points
    for (final (r, run) in runs.indexed) {
      final staves = [for (final k in run.staves) found[k].staff];
      final from = {for (final k in run.staves) found[k].system};
      int count(int i) => run.staves.where((k) => found[k].system == i).length;
      final main = systems[from.reduce((a, b) => count(b) > count(a) ? b : a)];
      final space = main.space;
      final left = main.left, right = from.map((i) => systems[i].right).reduce(math.max);
      final said = run.answer == null || run.answer! >= answer.systems.length || !fit.sure ? null : answer.systems[run.answer!];
      double quiet(double from, double to, double near) => PdfDetect.quietRow(raster, from, to, near, left, right, space: space);

      // Its top and bottom: between the systems either side of it, short of the ink its outer
      // staves reach (all that less than a space parts from them), at the quiet row nearest where
      // the answer says: a model's places are rough, the page's gaps aren't.
      final head = found[run.staves.first], tail = found[run.staves.last];
      final below = r + 1 < runs.length ? found[runs[r + 1].staves.first].staff.top - space * 0.5 : view.page.height;
      final topLow = math.max(above, staves.first.top - space * 12);
      final topHigh = math.max(
          topLow, math.min(staves.first.top - space * 0.5, PdfDetect.inkEnd(raster, staves.first.top, topLow, space, left, right) - space * 0.25));
      final double top;
      if (said?.top case final t?) {
        top = quiet(topLow, topHigh, down(t).clamp(topLow, topHigh));
      } else {
        final was = head.index == 0 ? systems[head.system].top : systems[head.system].resumeAfter(head.index - 1);
        top = was.clamp(topLow, topHigh);
      }
      final bottomHigh = math.max(staves.last.bottom + space * 0.5, math.min(below, staves.last.bottom + space * 12));
      final bottomLow = math.min(bottomHigh,
          math.max(staves.last.bottom + space * 0.5, PdfDetect.inkEnd(raster, staves.last.bottom, bottomHigh, space, left, right) + space * 0.25));
      final double bottom;
      if (said?.bottom case final b?) {
        bottom = quiet(bottomLow, bottomHigh, down(b).clamp(bottomLow, bottomHigh));
      } else {
        final last = systems[tail.system];
        final was = tail.index == last.staves.length - 1 ? last.bottom : last.cutAfter(tail.index);
        bottom = was.clamp(bottomLow, bottomHigh);
      }
      above = bottom;

      // The cuts between its staves, and the gaps: the quiet rows nearest where it says.
      final cuts = <double>[], gaps = <int, double>{};
      for (var j = 0; j + 1 < run.staves.length; j++) {
        final a = found[run.staves[j]], b = found[run.staves[j + 1]];
        final lo = a.staff.bottom + space * 0.3, hi = math.max(lo, b.staff.top - space * 0.3);
        final source = systems[a.system], together = a.system == b.system;
        final border = said?.borders.where((x) => x.below == run.staves[j] + 1).firstOrNull;
        if (border?.gap case (final g0, final g1)) {
          final y0 = quiet(lo, hi, down(math.min(g0, g1)).clamp(lo, hi));
          final y1 = quiet(y0, hi, down(math.max(g0, g1)).clamp(y0, hi));
          if (y1 - y0 >= space * 0.5) {
            cuts.add(y0);
            gaps[j] = y1;
            continue;
          }
        }
        if (border?.y case final y?) {
          cuts.add(quiet(lo, hi, down(y).clamp(lo, hi)));
        } else if (together) {
          cuts.add(source.cutAfter(a.index));
          if (source.gaps.containsKey(a.index)) gaps[j] = source.resumeAfter(a.index);
        } else {
          cuts.add(quiet(lo, hi, (lo + hi) / 2));
        }
      }
      // A cut in a gap's room above it: cuts and gaps stay in order.
      for (var j = 1; j < cuts.length; j++) {
        if (cuts[j] < (gaps[j - 1] ?? cuts[j - 1])) cuts[j] = gaps[j - 1] ?? cuts[j - 1];
      }

      // Its barlines: those the answer gives, on the page's.
      final lines = [
        for (final i in from)
          for (final b in systems[i].barlines)
            if (b.x > left - space && b.x <= right + space) b,
      ]..sort((a, b) => a.x.compareTo(b.x));
      final (barlines, starts) = switch (said?.barlines) {
        final given? when given.isNotEmpty => _barlines(raster, staves, given, lines, left: left, right: right, space: space, view: view),
        _ => (lines, [left, for (final b in lines) if (b.x >= left + space * 0.5) b.x]),
      };

      out.add((
        system: PdfSystem(
          page: main.page,
          top: top,
          bottom: bottom,
          left: left,
          right: right,
          staves: staves,
          cuts: cuts,
          gaps: gaps,
          barlines: barlines,
        ),
        labels: [for (final k in run.staves) k + 1],
        answer: run.answer,
        starts: starts,
      ));
    }
    return out;
  }

  /// A system's barlines as an answer gives them ([given], thousandths), on the page: lined up in
  /// order with those [found] (each pair within reach: a model places them roughly, often all a
  /// little to one side), a found one kept where it is (with the kind the answer says, though
  /// repeat dots found aren't undone by a plain one); one given that none was found for put on a
  /// line through the staves there, moved as far as the pairs say the answer is off (no line
  /// there: none). A found one the answer leaves out is taken away only from a lone staff (a stem
  /// may pass for one there): through several staves it is a barline. With where the answer's
  /// bars start, points ([PdfAiSystemRead.starts]).
  static (List<PdfBarline>, List<double>) _barlines(PdfRaster raster, List<PdfStaff> staves, List<({double x, PdfBarlineKind? kind})> given,
      List<PdfBarline> found,
      {required double left, required double right, required double space, required PdfAiView view}) {
    final said = [
      for (final b in given)
        if (view.x(b.x) case final x when x > left - space * 8 && x < right + space * 8) (x: x, kind: b.kind),
    ]..sort((a, b) => a.x.compareTo(b.x));
    final reach = math.max(space * 6, (right - left) * 0.06);
    // The cheapest alignment in order: a pair costs how far apart they are, one alone the reach.
    final n = said.length, m = found.length;
    final cost = List.generate(n + 1, (_) => List<double>.filled(m + 1, 0));
    final step = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0)); // 0 pair, 1 given alone, 2 found alone
    for (var i = 0; i <= n; i++) {
      for (var j = 0; j <= m; j++) {
        if (i == 0 && j == 0) continue;
        var best = double.infinity, how = 0;
        if (i > 0 && cost[i - 1][j] + reach < best) (best, how) = (cost[i - 1][j] + reach, 1);
        if (j > 0 && cost[i][j - 1] + reach < best) (best, how) = (cost[i][j - 1] + reach, 2);
        final apart = i > 0 && j > 0 ? (said[i - 1].x - found[j - 1].x).abs() : double.infinity;
        if (apart <= reach && cost[i - 1][j - 1] + apart < best) (best, how) = (cost[i - 1][j - 1] + apart, 0);
        cost[i][j] = best;
        step[i][j] = how;
      }
    }
    final pair = List<int?>.filled(n, null);
    final kept = List<bool>.filled(m, false);
    for (var i = n, j = m; i > 0 || j > 0;) {
      switch (step[i][j]) {
        case 0:
          pair[--i] = --j;
          kept[j] = true;
        case 1:
          i--;
        default:
          j--;
      }
    }
    // Too few of them paired: its barlines aren't the page's (its bars counted as those found).
    final paired = pair.whereType<int>().length;
    if (m > 0 && paired < (math.min(n, m) / 2).ceil()) return (found, [left, for (final b in found) if (b.x >= left + space * 0.5) b.x]);
    // How far off the answer's places are, as the pairs say.
    final offsets = [
      for (var i = 0; i < n; i++)
        if (pair[i] case final j?) found[j].x - said[i].x,
    ]..sort();
    final shift = offsets.isEmpty ? 0.0 : offsets[offsets.length ~/ 2];
    final lines = <PdfBarline>[];
    final starts = <double>[left];
    for (final (i, b) in said.indexed) {
      double? at;
      var kind = b.kind ?? PdfBarlineKind.normal;
      if (pair[i] case final j?) {
        final was = found[j];
        at = was.x;
        final repeat = was.kind == PdfBarlineKind.repeatStart || was.kind == PdfBarlineKind.repeatEnd || was.kind == PdfBarlineKind.repeatBoth;
        // A final barline ends a system, or was found to be a heavy one.
        final ending = (was.x - right).abs() < space || was.kind == PdfBarlineKind.end || was.kind == PdfBarlineKind.double;
        if (b.kind == null || (b.kind == PdfBarlineKind.normal && repeat) || (b.kind == PdfBarlineKind.end && !ending)) kind = was.kind;
      } else {
        at = PdfDetect.lineNear(raster, staves, b.x + shift, offsets.isEmpty ? reach / 2 : space * 2);
      }
      final x = at ?? b.x + shift;
      if (x < left + space * 0.5) continue; // the system's start
      starts.add(x);
      if (at != null) lines.add(PdfBarline(at, kind));
    }
    if (staves.length > 1) {
      for (final (j, b) in found.indexed) {
        if (!kept[j]) lines.add(b);
      }
    }
    lines.sort((a, b) => a.x.compareTo(b.x));
    final out = <PdfBarline>[];
    for (final l in lines) {
      if (l.x < left + space * 0.5 || l.x > right + space || (out.isNotEmpty && l.x - out.last.x < space)) continue;
      out.add(l);
    }
    if (out.isNotEmpty && (out.last.x - right).abs() < space * 0.8) out.last = out.last.copyWith(x: right);
    return (out, starts..sort());
  }

  /// The line `true = said × scale + shift` through [pairs] (said, true), staves' middles, those a
  /// few staff [space]s off it left out once (with too few or too alike, a shift alone); [sure]
  /// when most of the [staves] are among them and lie on it, give or take ¾ of a space. The exam
  /// ([PdfAiExam]) measures an answer's places through it too.
  static ({double scale, double shift, bool sure}) fit(List<(double, double)> pairs, int staves, double space) {
    ({double scale, double shift, bool clamped}) line(List<(double, double)> ps) {
      if (ps.isEmpty) return (scale: 1, shift: 0, clamped: false);
      final n = ps.length;
      final mx = ps.fold(0.0, (s, p) => s + p.$1) / n, my = ps.fold(0.0, (s, p) => s + p.$2) / n;
      final sxx = ps.fold(0.0, (s, p) => s + (p.$1 - mx) * (p.$1 - mx)), sxy = ps.fold(0.0, (s, p) => s + (p.$1 - mx) * (p.$2 - my));
      // A slope only from staves well apart, and no more than a quarter either way.
      final free = n >= 3 && sxx > space * space * 144 ? sxy / sxx : 1.0, scale = free.clamp(0.8, 1.25);
      return (scale: scale, shift: my - scale * mx, clamped: scale != free);
    }

    double off((double, double) p, ({double scale, double shift, bool clamped}) f) => (p.$1 * f.scale + f.shift - p.$2).abs();
    var fit = line(pairs);
    var kept = [for (final p in pairs) if (off(p, fit) < space * 3) p];
    if (kept.length < pairs.length && kept.isNotEmpty) {
      fit = line(kept);
      kept = [for (final p in pairs) if (off(p, fit) < space * 3) p];
    }
    final near = pairs.where((p) => off(p, fit) <= space * 0.75).length;
    final sure = pairs.isNotEmpty && !fit.clamped && pairs.length >= (staves * 0.7).ceil() && near >= (pairs.length * 0.7).ceil();
    return (scale: fit.scale, shift: fit.shift, sure: sure);
  }

  /// [name] as compared: letters and digits, any case, ♭ and ♯ as b and #.
  static String _loose(String name) =>
      name.toLowerCase().replaceAll('♭', 'b').replaceAll('♯', '#').replaceAll(RegExp(r'[^\p{L}\p{N}#]', unicode: true), '');

  /// Whether two systems found apart are one whose staves weren't joined at their left (a voice
  /// over a piano): their music starts and ends alike, and their barlines line up.
  static bool _aligned(PdfSystem a, PdfSystem b) {
    final space = math.max(a.space, b.space);
    if ((a.left - b.left).abs() > space * 3 || (a.right - b.right).abs() > space * 3) return false;
    final (fewer, more) = a.barlines.length <= b.barlines.length ? (a.barlines, b.barlines) : (b.barlines, a.barlines);
    if (fewer.isEmpty) return more.length <= 1;
    final matched = fewer.where((p) => more.any((q) => (p.x - q.x).abs() <= space)).length;
    return matched >= (fewer.length * 0.6).ceil();
  }

  /// [layout] with the pages [read] (in the order read: the page the instruments were taken from
  /// first) as their answers say: their systems as [refine] set them, each staff the instrument
  /// the answer says (a one-staff instrument's further staff a division of it), the instruments
  /// named and abbreviated as printed, and the clefs, keys (concert: each staff's read through
  /// its transposition, the most staves' wins), time signatures and tempo marks it read put in
  /// where they differ from those in force. Nothing else is taken away.
  static PdfScoreLayout apply(PdfScoreLayout layout, List<PdfAiPageRead> read) {
    final byPage = {for (final r in read) r.page: r};
    // The systems: each page read as its answer set them, the others as they were.
    final systems = <PdfSystem>[];
    final placed = <(PdfAiPageRead, PdfAiSystemRead, int)>[];
    final done = <int>{};
    for (final s in layout.systems) {
      final r = byPage[s.page];
      if (r == null) {
        systems.add(s);
      } else if (done.add(s.page)) {
        for (final x in r.systems) {
          placed.add((r, x, systems.length));
          systems.add(x.system);
        }
      }
    }
    // Each staff the instrument the answer says.
    final ids = {for (final i in layout.instruments) if (!i.blank) i.id.toLowerCase(): i};
    final names = <String, String>{}, abbreviations = <String, String>{}, divisi = <String, int>{};
    for (final (r, x, at) in placed) {
      final s = systems[at];
      final staves = [...s.staves];
      for (final (k, label) in x.labels.indexed) {
        final t = r.answer.staff(label);
        final i = t?.instrument == null ? null : ids[t!.instrument!.toLowerCase()];
        if (t == null || i == null) continue;
        final n = t.staff.clamp(1, i.staves > 1 ? i.staves : 4);
        staves[k] = staves[k].copyWith(part: () => i.id, staff: n);
        if (i.staves == 1 && n > 1) divisi.update(i.id, (d) => math.max(d, n), ifAbsent: () => n);
        if (t.name.isNotEmpty) names.putIfAbsent(i.id, () => t.name);
        final printed = t.printed;
        if (printed.isNotEmpty && !RegExp(r'^[\d\s.]+$').hasMatch(printed) && printed.toLowerCase() != (names[i.id] ?? '').toLowerCase()) {
          abbreviations.putIfAbsent(i.id, () => printed);
        }
      }
      systems[at] = s.copyWith(staves: staves);
    }
    final next = layout.copyWith(systems: systems, instruments: [
      for (final i in layout.instruments)
        () {
          var named = i;
          // A name the PDF's text gave, spelled otherwise ("B♭", "Bb"), stays as it was.
          if (names[i.id] case final name? when _loose(name) != _loose(i.name)) named = named.renamed(name);
          if (abbreviations[i.id] case final a? when _loose(a) != _loose(i.abbreviation)) named = named.copyWith(abbreviation: a);
          if (divisi[i.id] case final d? when d > named.divisi) named = named.copyWith(divisi: d);
          return named;
        }(),
    ]);

    // The bar of system [at] that x (points) is in.
    int barAt(int at, double x) {
      final s = next.systems[at], bars = next.barOfSegment[at];
      if (bars.isEmpty) return -1;
      var k = 0;
      for (final (j, (l, _)) in s.segments.indexed) {
        if (x + s.space * 0.5 >= l) k = j;
      }
      return bars[math.min(k, bars.length - 1)];
    }

    double startOf(PdfAiSystemRead x, int bar) => x.starts[(bar - 1).clamp(0, x.starts.length - 1)];

    // What the answers read, bar by bar.
    final clefs = <(int, String, int, PdfClef)>[]; // bar, instrument, its staff, clef
    final keys = <int, Map<int, int>>{}; // bar → concert key → staves' say
    final meters = <(int, PdfMeter)>[];
    final tempos = <int, PdfTempo>{};
    final systemsSeen = <(int, int)>{};
    for (final (r, x, at) in placed) {
      final s = next.systems[at];
      final start = barAt(at, s.left);
      if (start < 0) continue;
      for (final (k, label) in x.labels.indexed) {
        final t = r.answer.staff(label);
        final i = next.instrument(s.staves[k].part);
        if (t == null || i == null || i.blank) continue;
        final n = next.staffInPart(s.staves[k]);
        // A division's clef is its section's: the first staff's says it.
        final first = i.staves > 1 || s.staves[k].staff == 1;
        final drums = t.clef == PdfClef.percussion;
        void observe(int bar, PdfClef? clef, int? key) {
          if (bar < 0) return;
          if (clef != null && first) clefs.add((bar, i.id, n, clef));
          if (key != null && !drums) {
            // Concert-pitch staves say it more surely: a horn's or a timpani's may print none.
            (keys[bar] ??= {}).update(i.key.concertOf(key), (w) => w + (i.key == SpacerKey.c ? 2 : 1),
                ifAbsent: () => i.key == SpacerKey.c ? 2 : 1);
          }
        }

        observe(start, t.clef, t.key);
        for (final c in t.changes) {
          observe(barAt(at, startOf(x, c.bar)), c.clef, c.key);
        }
      }
      // A system's own marks once, though a system found apart from the rest of it says them too.
      final said = x.answer == null || x.answer! >= r.answer.systems.length ? null : r.answer.systems[x.answer!];
      if (said == null || !systemsSeen.add((r.page, x.answer!))) continue;
      if (said.time case final m?) meters.add((start, m));
      for (final t in said.times) {
        meters.add((barAt(at, startOf(x, t.bar)), t.meter));
      }
      for (final t in said.tempos) {
        final bar = barAt(at, startOf(x, t.bar));
        if (bar >= 0) tempos.putIfAbsent(bar, () => t.tempo);
      }
    }

    // Clefs: an instrument's first staff's first one is its clef; one differing from the clef in
    // force a change.
    final instruments = [...next.instruments];
    clefs.sort((a, b) => a.$1.compareTo(b.$1));
    final clefSeen = <(String, int)>{};
    for (final (bar, id, n, clef) in clefs) {
      final at = instruments.indexWhere((i) => i.id == id);
      final i = instruments[at];
      final firstSeen = clefSeen.add((id, n));
      if (n == 1 && firstSeen && !i.clefs.keys.any((c) => c.$2 == 1 && c.$1 <= bar)) {
        instruments[at] = i.copyWith(clef: clef);
      } else if (i.clefAt(bar, n) != clef) {
        instruments[at] = i.copyWith(clefs: {...i.clefs, (bar, n): clef});
      }
    }

    // Keys: the concert key the most staves say, where it differs from the one in force.
    var fifths = next.fifths;
    final keyMap = {...next.keys};
    int keyAt(int bar) {
      var at = -1;
      for (final k in keyMap.keys) {
        if (k <= bar && k > at) at = k;
      }
      return at < 0 ? fifths : keyMap[at]!;
    }

    for (final bar in keys.keys.toList()..sort()) {
      final concert = keys[bar]!.entries.reduce((a, b) => b.value > a.value ? b : a).key;
      if (bar == 0) {
        fifths = concert;
      } else if (keyAt(bar) != concert) {
        keyMap[bar] = concert;
      }
    }

    // Time signatures.
    var meter = next.meter;
    final meterMap = {...next.meters};
    PdfMeter meterAt(int bar) {
      var at = -1;
      for (final k in meterMap.keys) {
        if (k <= bar && k > at) at = k;
      }
      return at < 0 ? meter : meterMap[at]!;
    }

    meters.sort((a, b) => a.$1.compareTo(b.$1));
    for (final (bar, m) in meters) {
      if (bar < 0) continue;
      if (bar == 0) {
        meter = m;
      } else if (meterAt(bar) != m) {
        meterMap[bar] = m;
      }
    }

    // Tempo marks: the first bar's speed is the score's.
    final tempoMap = {...next.tempos};
    var tempo = next.tempo;
    for (final MapEntry(key: bar, value: mark) in tempos.entries) {
      if (bar == 0) {
        if (mark.words.isNotEmpty) tempoMap[0] = PdfTempo(mark.words);
        if (mark.bpm case final bpm?) tempo = bpm;
      } else {
        tempoMap[bar] = mark;
      }
    }

    return next.copyWith(
      instruments: instruments,
      fifths: fifths,
      keys: keyMap,
      meter: meter,
      meters: meterMap,
      tempo: tempo,
      tempos: tempoMap,
    );
  }
}
