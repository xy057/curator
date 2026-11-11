import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

/// A page of ink at [PdfDetect.scale]: two staves joined by a system barline at x 40 points,
/// with barlines through both at x 120 and 200 (the last one the system's end). [crossing]: a
/// block of ink from one staff to the other at x 80 (no row between them is clear).
PdfRaster _page({bool crossing = false}) {
  const scale = PdfDetect.scale, width = 240, height = 120;
  final w = (width * scale).round(), h = (height * scale).round();
  final ink = Uint8List(w * h);
  void line(double x0, double y0, double x1, double y1) {
    for (var y = (y0 * scale).round(); y <= (y1 * scale).round(); y++) {
      for (var x = (x0 * scale).round(); x <= (x1 * scale).round(); x++) {
        ink[y * w + x] = 255;
      }
    }
  }

  const tops = [20.0, 60.0], space = 4.0;
  for (final top in tops) {
    for (var l = 0; l < 5; l++) {
      line(40, top + l * space, 200, top + l * space);
    }
  }
  for (final x in [40.0, 120.0, 200.0]) {
    line(x, tops.first, x + 0.4, tops.last + 4 * space);
  }
  if (crossing) line(80, tops.first + 4 * space, 84, tops.last);
  return PdfRaster(ink, w, h, scale: scale);
}

/// Staff [k]'s region's top and bottom.
(double, double) _band(PdfSystem s, int k) => (s.regionOf(k).top, s.regionOf(k).bottom);

/// [s] with staff [k]'s region's [top] or [bottom] moved, its sides as they were.
PdfSystem _resized(PdfSystem s, int k, {double? top, double? bottom}) {
  final r = s.regionOf(k), t = s.staves[k];
  return s.withRegion(k, ui.Rect.fromLTRB(r.left, top ?? r.top, r.right, bottom ?? r.bottom),
      followLeft: t.regionLeft == null, followRight: t.regionRight == null);
}

void main() {
  test('finds a page’s systems, staves and bars', () {
    final systems = PdfDetect.page(_page(), 0);
    expect(systems, hasLength(1));
    final system = systems.single;
    expect([for (final s in system.staves) s.top], [closeTo(20, 0.5), closeTo(60, 0.5)]);
    expect([for (final s in system.staves) s.space], [closeTo(4, 0.2), closeTo(4, 0.2)]);
    expect([for (final b in system.barlines) b.x], [closeTo(120, 0.8), closeTo(200, 0.8)]);
    // The staves' regions meet where nothing but the barlines cross, from the music's start to
    // its end.
    final cut = system.staves.first.regionBottom;
    expect(system.staves.last.regionTop, cut);
    expect([system.regionOf(0).left, system.regionOf(0).right], [system.left, system.right]);
    expect(cut, inExclusiveRange(system.staves.first.bottom, system.staves.last.top));
    // Room between two regions is no one's: the barlines crossing it go with neither staff.
    final page = _page();
    List<int> owners(PdfSystem s, double y, {PdfRaster? on, double x = 120}) {
      final r = on ?? page;
      return PdfDetect.assign(r, s, const []).at(r.row(y).round() * r.width + r.col(x).round());
    }

    expect(owners(system, cut + 2), [1]);
    final apart = _resized(system, 1, top: cut + 6);
    expect(_band(apart, 1).$1, cut + 6);
    expect([owners(apart, cut + 2), owners(apart, cut + 8), owners(apart, cut - 2)], [<int>[], [1], [0]]);
    // A mask of one staff's leaves the others' ink as it was.
    List<int> masked(int staff) => PdfDetect.assign(page, system, const [], staffMasks: {
          staff: [ui.Rect.fromCenter(center: ui.Offset(120, cut + 2), width: 4, height: 4)],
        }).at(page.row(cut + 2).round() * page.width + page.col(120).round());
    expect([masked(0), masked(1)], [[1], <int>[]]);
    // A mask in the margin right of what was read, across its last row, leaves out nothing.
    final margin = ui.Rect.fromLTRB(page.xOf(page.width) + 20, 100, page.xOf(page.width) + 40, 140);
    expect(PdfDetect.assign(page, system, [margin]).of, PdfDetect.assign(page, system, const []).of);

    // Regions may overlap. A mark (a dot just below the cut) lying whole in both is both's, and
    // the upper staff's ink then reaches it; one only part in the upper region stays the lower's.
    final dotted = PdfRaster(Uint8List.fromList(page.ink), page.width, page.height, scale: page.scale);
    for (var y = dotted.row(cut + 2).round(); y <= dotted.row(cut + 4).round(); y++) {
      dotted.ink.fillRange(y * dotted.width + dotted.col(78).round(), y * dotted.width + dotted.col(82).round() + 1, 255);
    }
    final over = _resized(system, 0, bottom: cut + 8);
    expect([over.staffAt(80, cut + 2), over.staffAt(80, cut - 2), over.staffAt(80, system.staves.first.top - 30)], [1, 0, -1]);
    expect(owners(system, cut + 3, on: dotted, x: 80), [1]);
    expect(owners(over, cut + 3, on: dotted, x: 80), [0, 1]);
    expect(owners(_resized(system, 0, bottom: cut + 3), cut + 3, on: dotted, x: 80), [1]);
    final reach = [for (final s in [system, over]) PdfDetect.ink(dotted, s, const [])[0][0].below];
    expect(reach, [closeTo(0, 0.3), closeTo((cut + 4 - system.staves.first.bottom) / 4, 0.3)]);
    // A barline through an overlap is cut in it: each row the nearer staff's.
    final wide = _resized(_resized(system, 0, bottom: 58), 1, top: 38);
    expect([owners(wide, 40), owners(wide, 56)], [[0], [1]]);
    // A region's sides are its own: one that starts past the dot leaves it out (no one's, the
    // lower region not reaching it), and the dot no longer reaches the upper staff's ink.
    final narrow = over.withRegion(0, ui.Rect.fromLTRB(90, over.regionOf(0).top, 200, cut + 8), followRight: true);
    expect([narrow.regionOf(0).left, narrow.staves[0].regionRight, narrow.staffAt(80, cut - 2), narrow.staffAt(95, cut - 2)], [90, null, -1, 0]);
    expect(owners(narrow, cut + 3, on: dotted, x: 80), [1]);
    expect(PdfDetect.ink(dotted, narrow, const [])[0][0].below, closeTo(0, 0.3));
    // Following the music's start, a region goes with it; its own left stays.
    expect([over.copyWith(left: 50).regionOf(0).left, narrow.copyWith(left: 50).regionOf(0).left], [50, 90]);
  });

  test('a staff’s lines are told from ties over it, and found leaning', () {
    // Two staves joined by a line at x 30 points, barlines at 160 and 290. Ties over the upper
    // one fill the row a space above its lines a third of the way along, as a line can't; the
    // lower one leans as a scan can, each line's right half three rows below its left.
    const scale = PdfDetect.scale, width = 320, height = 120, space = 4.0;
    final w = (width * scale).round(), h = (height * scale).round();
    final ink = Uint8List(w * h);
    int row(double y) => (y * scale).round();
    void fill(double x0, double x1, int y0, [int? y1]) {
      for (var y = y0; y <= (y1 ?? y0); y++) {
        ink.fillRange(y * w + (x0 * scale).round(), y * w + (x1 * scale).round() + 1, 255);
      }
    }

    for (var l = 0; l < 5; l++) {
      fill(30, 290, row(30 + l * space));
      fill(30, 160, row(70 + l * space) - 1);
      fill(160, 290, row(70 + l * space) + 2);
    }
    for (var t = 0; t < 6; t++) {
      final mid = 60.0 + t * 40;
      fill(mid - 8, mid + 8, row(30 - space));
      fill(mid - 12, mid - 8, row(30 - space) + 1);
      fill(mid + 8, mid + 12, row(30 - space) + 1);
      fill(mid - 14, mid - 12, row(30 - space) + 2, row(30 - space) + 4);
      fill(mid + 12, mid + 14, row(30 - space) + 2, row(30 - space) + 4);
    }
    for (final x in [30.0, 160.0, 290.0]) {
      fill(x, x + 0.4, row(30), row(86) + 2);
    }
    final systems = PdfDetect.page(PdfRaster(ink, w, h, scale: scale), 0);
    expect(systems, hasLength(1));
    // The leaning staff's lines are where their halves are between.
    expect([for (final s in systems.single.staves) s.top], [closeTo(30, 0.2), closeTo(70.2, 0.2)]);
    expect([for (final s in systems.single.staves) s.space], [closeTo(4, 0.2), closeTo(4, 0.2)]);
  });

  test('an AI model\u2019s answer is put on the page\u2019s ink, and into the layout', () {
    final page = _page();
    // Found without the barline at 120, the staves the instruments' "Staff 1" and "Staff 2".
    final found = PdfDetect.page(page, 0).single;
    final system = found.copyWith(
      barlines: [found.barlines.last],
      staves: [found.staves[0].copyWith(part: () => 'P1'), found.staves[1].copyWith(part: () => 'P2')],
    );
    final layout = PdfScoreLayout(
      pages: const [ui.Size(240, 120)],
      instruments: const [PdfInstrument(id: 'P1', name: 'Staff 1'), PdfInstrument(id: 'P2', name: 'Staff 2')],
      systems: [system],
    );
    final view = PdfAiView(const ui.Size(240, 120));
    String x(double points) => (points / view.width * 1000).toStringAsFixed(1);
    String y(double points) => (points / 120 * 1000).toStringAsFixed(1);
    // Its places off, as a model's are (all 6 points low, barlines to the left); in a code fence.
    final answer = PdfAiPage.parse('''Here it is:
```json
{"systems": [{"staves": [
  {"label": 1, "y": ${y(34)}, "region": [${y(16)}, ${y(50)}], "instrument": "P1", "staff": 1, "name": "Flute", "printed": "Fl.", "clef": "treble", "key": -1},
  {"label": 2, "y": ${y(74)}, "region": [${y(50)}, ${y(96)}], "instrument": "p2", "staff": 1, "name": "Clarinet in B♭", "printed": "", "clef": "treble", "key": 1,
   "changes": [{"bar": 2, "clef": "bass"}]}],
  "barlines": [{"x": ${x(114)}, "kind": "single"}, {"x": ${x(196)}, "kind": "final"}],
  "time": "3/4", "tempos": [{"bar": 1, "text": "Allegro", "bpm": 132}, {"bar": 2, "text": "rit.", "bpm": null}]}]}
```''');
    final refined = PdfAi.refine(page, [system], answer, view);
    final s = refined.single.system;
    // The barline missed is found where it says, the last one kept where it was.
    expect([for (final b in s.barlines) b.x], [closeTo(120, 0.8), s.right]);
    expect([for (final b in s.barlines) b.kind], [PdfBarlineKind.normal, PdfBarlineKind.end]);
    // Where it says the staves are sets right where it says the rest is.
    expect([s.top, s.bottom, s.staves.first.regionBottom, s.staves.last.regionTop], [closeTo(10, 1), closeTo(90, 1), closeTo(44, 1), closeTo(44, 1)]);
    expect(refined.single.starts, [s.left, closeTo(120, 0.8), s.right]);
    final next = PdfAi.apply(layout, [(page: 0, answer: answer, systems: refined)]);
    // Named and abbreviated as printed, the transposition following the name.
    expect([for (final i in next.instruments) (i.name, i.abbreviation, i.key)],
        [('Flute', 'Fl.', SpacerKey.c), ('Clarinet in B♭', '', SpacerKey.bFlat)]);
    // The clarinet's two sharps and the flute's flat both say F major.
    expect([next.fifths, '${next.meter}', next.tempo], [-1, '3/4', 132]);
    expect(next.tempos, {0: const PdfTempo('Allegro'), 1: const PdfTempo('rit.')});
    expect(next.instruments.last.clefs, {(1, 1): PdfClef.bass});
    expect(next.systems.single.ink, isNull);
  });

  test('an instrument’s abbreviation is what a later page prints, not its name with a full stop', () {
    final page = _page();
    final view = PdfAiView(const ui.Size(240, 120));
    String y(double points) => (points / 120 * 1000).toStringAsFixed(1);
    final systems = [
      for (var p = 0; p < 2; p++)
        () {
          final found = PdfDetect.page(page, p).single;
          return found.copyWith(staves: [found.staves[0].copyWith(part: () => 'P1'), found.staves[1].copyWith(part: () => 'P2')]);
        }(),
    ];
    final layout = PdfScoreLayout(
      pages: const [ui.Size(240, 120), ui.Size(240, 120)],
      instruments: const [PdfInstrument(id: 'P1', name: 'Staff 1'), PdfInstrument(id: 'P2', name: 'Oboi')],
      systems: systems,
    );
    PdfAiPage answer(String first, String second) => PdfAiPage.parse('{"systems": [{"staves": ['
        '{"label": 1, "y": ${y(28)}, "instrument": "P1", "name": "Flauti", "printed": "$first"}, '
        '{"label": 2, "y": ${y(68)}, "instrument": "P2", "name": "", "printed": "$second"}]}]}');
    // The page they are named from prints the names in full; the next, their abbreviations.
    final read = [
      for (final (p, a) in [answer('Flauti.', 'OBOI.'), answer('Fl.', 'Ob.')].indexed)
        (page: p, answer: a, systems: PdfAi.refine(page, [systems[p]], a, view)),
    ];
    final next = PdfAi.apply(layout, read);
    expect([for (final i in next.instruments) (i.name, i.abbreviation)], [('Flauti', 'Fl.'), ('Oboi', 'Ob.')]);
  });

  test('two systems found apart that an AI model says are one have each barline once', () {
    final page = _page();
    final view = PdfAiView(const ui.Size(240, 120));
    String y(double points) => (points / 120 * 1000).toStringAsFixed(1);
    // Found as two systems of a staff each, the lower one's barlines a hair to the right.
    final found = PdfDetect.page(page, 0).single;
    final upper = found.copyWith(staves: [found.staves[0]]);
    final lower = found.copyWith(
        staves: [found.staves[1]], barlines: [for (final b in found.barlines) b.copyWith(x: b.x + 0.7, kind: PdfBarlineKind.end)]);
    // One system, it says, and nothing of its barlines.
    final answer = PdfAiPage.parse('{"systems": [{"staves": [{"label": 1, "y": ${y(28)}}, {"label": 2, "y": ${y(68)}}]}]}');
    final refined = PdfAi.refine(page, [upper, lower], answer, view).single;
    expect(refined.system.staves, hasLength(2));
    expect([for (final b in refined.system.barlines) b.x], [for (final b in found.barlines) b.x]);
    expect({for (final b in refined.system.barlines) b.kind}, {PdfBarlineKind.end});
    expect(refined.system.segments, hasLength(found.segments.length));
    expect(refined.starts, [found.left, for (final b in found.barlines) b.x]);
  });

  test('a lone staff keeps its barlines when an AI model’s are nowhere near it', () {
    final page = _page();
    final view = PdfAiView(const ui.Size(240, 120));
    final found = PdfDetect.page(page, 0).single;
    final system = found.copyWith(staves: [found.staves[0]]);
    // Its staff where it is, its only barline at the page's left edge.
    final answer = PdfAiPage.parse('{"systems": [{"staves": [{"label": 1, "y": ${(28 / 120 * 1000).toStringAsFixed(1)}}], "barlines": [{"x": 0}]}]}');
    final refined = PdfAi.refine(page, [system], answer, view).single;
    expect(refined.system.barlines, system.barlines);
    expect(refined.starts, [system.left, for (final b in system.barlines) b.x]);
  });

  test('an answer’s numbers that are no numbers are passed over', () {
    // "NaN" and "Infinity" read as numbers: rounding one would throw, where a wrong answer is
    // only wrong.
    final answer = PdfAiPage.parse('{"systems": [{"staves": ['
        '{"label": "1", "y": "NaN", "region": ["Infinity", 50], "staff": "NaN", "key": "-Infinity", "changes": [{"bar": "NaN", "key": 2}]}, '
        '{"label": null, "y": "NaN"}], '
        '"barlines": [{"x": "NaN"}, "Infinity", {"x": "310"}], "times": [{"bar": "NaN", "time": "2/4"}], '
        '"tempos": [{"bar": "Infinity", "text": "Lento", "bpm": "NaN"}]}]}');
    final system = answer.systems.single, staff = system.staves.single;
    expect((staff.label, staff.y, staff.region, staff.staff, staff.key), (1, null, null, 1, null));
    expect(staff.changes, [(bar: 1, clef: null, key: 2)]);
    expect([for (final b in system.barlines!) b.x], [310]);
    expect(system.times, [(bar: 1, meter: const PdfMeter('2', 4))]);
    expect(system.tempos, [(bar: 1, tempo: const PdfTempo('Lento'))]);
  });

  test('regions an AI model says overlap do only where no row between the staves is clear', () {
    final view = PdfAiView(const ui.Size(240, 120));
    String y(double points) => (points / 120 * 1000).toStringAsFixed(1);
    // The upper staff's region down to 54, the lower one's up from 42; then a gap, 42 to 54.
    PdfAiPage answer(double end, double start) => PdfAiPage.parse(
        '{"systems": [{"staves": [{"label": 1, "y": ${y(28)}, "region": [${y(10)}, ${y(end)}]}, '
        '{"label": 2, "y": ${y(68)}, "region": [${y(start)}, ${y(90)}]}]}]}');
    (double, double) between(PdfRaster page, PdfAiPage answer) {
      final s = PdfAi.refine(page, [PdfDetect.page(page, 0).single], answer, view).single.system;
      return (s.staves.first.regionBottom, s.staves.last.regionTop);
    }

    // Ink from one staff to the other: each keeps what it says is its.
    final (under, over) = between(_page(crossing: true), answer(54, 42));
    expect([under, over], [closeTo(54, 1), closeTo(42, 1)]);
    // Rows clear between them: a cut loses nothing, so they meet, between where it said.
    final (end, start) = between(_page(), answer(54, 42));
    expect(end, start);
    expect(end, inInclusiveRange(42, 54));
    // Room it says is no one's stays no one's.
    final (above, below) = between(_page(), answer(42, 54));
    expect([above, below], [closeTo(42, 1), closeTo(54, 1)]);
  });

  test('a staff an AI model says was missed is added where the page has its lines', () {
    final page = _page();
    final found = PdfDetect.page(page, 0).single;
    // Found without its lower staff.
    final system = found.copyWith(staves: [found.staves[0].copyWith(part: () => 'P1')]);
    final layout = PdfScoreLayout(
      pages: const [ui.Size(240, 120)],
      instruments: const [PdfInstrument(id: 'P1', name: 'Staff 1'), PdfInstrument(id: 'P2', name: 'Staff 2')],
      systems: [system],
    );
    final view = PdfAiView(const ui.Size(240, 120));
    String y(double points) => (points / 120 * 1000).toStringAsFixed(1);
    // Its places 5 points low; a staff at 68, where there is one, and one at 100, where there isn't.
    final answer = PdfAiPage.parse('''{"systems": [{"staves": [
  {"label": 1, "y": ${y(33)}, "region": [${y(15)}, ${y(53)}], "instrument": "P1", "clef": "treble"},
  {"label": null, "y": ${y(73)}, "region": [${y(53)}, ${y(95)}], "instrument": "P2", "name": "Bassoon", "clef": "bass"},
  {"label": null, "y": ${y(105)}, "instrument": "P2", "staff": 2}]}]}''');
    expect([for (final t in answer.systems.single.staves) (t.label, t.found)], [(1, true), (-1, false), (-2, false)]);
    final refined = PdfAi.refine(page, [system], answer, view);
    final s = refined.single.system;
    expect(refined.single.labels, [1, -1]);
    expect([for (final t in s.staves) t.top], [closeTo(20, 0.3), closeTo(60, 0.3)]);
    expect([for (final t in s.staves) t.space], [closeTo(4, 0.1), closeTo(4, 0.1)]);
    // Its region as said, meeting the staff above's.
    expect([s.staves.first.regionBottom, s.staves.last.regionTop, s.staves.last.regionBottom], [closeTo(48, 1), closeTo(48, 1), closeTo(90, 1)]);
    // Whose it says, named and with the clef it says.
    final next = PdfAi.apply(layout, [(page: 0, answer: answer, systems: refined)]);
    expect([for (final t in next.systems.single.staves) t.part], ['P1', 'P2']);
    expect([for (final i in next.instruments) (i.name, i.clef)], [('Staff 1', PdfClef.treble), ('Bassoon', PdfClef.bass)]);
    // Places that are no good add nothing.
    final wild = PdfAiPage.parse('{"systems": [{"staves": [{"label": 1, "y": 900}, {"label": null, "y": ${y(68)}}]}]}');
    expect(PdfAi.refine(page, [system], wild, view).single.system.staves, hasLength(1));
  });

  test('the exam marks a model’s answers as Read with AI takes them', () {
    final view = PdfAiView(PdfAiExam.size);
    // A page's answer as printed, its places scaled and moved as a model's drift.
    String answer(PdfAiExamPage page,
        {double scale = 1, double by = 0, double across = 0, int regions = 99, List<Object>? barlines, List<Object>? tempos,
        Map<String, Object?> Function(int k, Map<String, Object?> staff)? staff}) {
      double y(double p) => (p * scale + by) / PdfAiExam.size.height * 1000;
      double x(double p) => (p + across) / view.width * 1000;
      // Between each two staves' lines, and past the ink above and below the system.
      final cuts = [
        (page.top.$1 + page.top.$2) / 2,
        for (var k = 1; k < page.staves.length; k++) (page.staves[k - 1].bottom + page.staves[k].top) / 2,
        (page.bottom.$1 + page.bottom.$2) / 2,
      ];
      return jsonEncode({
        'systems': [
          {
            'staves': [
              for (final (k, s) in page.staves.indexed)
                (staff ?? (_, m) => m)(k, {
                  'label': k + 1, 'y': y((s.top + s.bottom) / 2), 'instrument': 'P${k + 1}', 'staff': 1, //
                  'name': s.name, 'printed': s.printed, 'clef': s.clef.name, 'key': s.key,
                  if (k < regions) 'region': [y(cuts[k]), y(cuts[k + 1])],
                }),
            ],
            'barlines': barlines ?? [for (final b in page.barlines) {'x': x(b), 'kind': 'single'}],
            'time': page.time?.toString(),
            'tempos': tempos ?? [if (page.tempo case final t?) {'bar': 1, 'text': t.words, 'bpm': t.bpm}],
          },
        ],
      });
    }

    PdfAiExamResult score(List<String?> answers) => PdfAiExam.score([for (final a in answers) a == null ? null : PdfAiPage.parse(a)]);
    final [first, second] = PdfAiExam.pages;
    final all = {for (final p in PdfAiExamPart.values) p: 1.0};
    expect(score([answer(first), answer(second)]).parts, all);
    // Places off by as much throughout are as good: Read with AI sets them right.
    expect(score([answer(first, scale: 1.03, by: 8, across: 10), answer(second, scale: 0.98, by: -6, across: -12)]).parts, all);

    // The clarinets' key misread, a clef change made up, two staves' regions, four barlines and the
    // metronome mark left out, the system's end called final; the next page's answer unreadable.
    double x(double p) => p / view.width * 1000;
    final poor = score([
      answer(first,
          regions: 11,
          barlines: [for (final b in first.barlines.take(5)) {'x': x(b)}, {'x': x(first.barlines.last), 'kind': 'final'}],
          tempos: [{'bar': 1, 'text': 'Allegro ma non troppo, un poco maestoso', 'bpm': null}],
          staff: (k, s) => {...s, if (k == 2) 'key': -1, if (k == 3) 'changes': [{'bar': 3, 'clef': 'treble'}]}),
      null,
    ]);
    expect(poor.parts, {
      PdfAiExamPart.horizontal: 23 / 54,
      PdfAiExamPart.barlines: 10 / 24,
      PdfAiExamPart.names: 26 / 52,
      PdfAiExamPart.clefs: 12 / 26,
      PdfAiExamPart.keys: 12 / 26,
      PdfAiExamPart.tempo: 2 / 5,
    });
    // Kept as this exam's, and not another's.
    final kept = PdfAiExamResult.fromJson(jsonDecode(jsonEncode(poor.toJson())))!;
    expect(kept.accuracy, closeTo(poor.accuracy, 0.001));
    expect(PdfAiExamResult.fromJson({...poor.toJson(), 'version': PdfAiExam.version + 1}), isNull);
  });

  test('a divided instrument is a part a division, and the layout round-trips', () {
    const violin = PdfInstrument(id: 'P1', name: 'Violin', divisi: 2);
    PdfSystem system(int page, List<PdfStaff> staves, {List<double> cuts = const []}) => PdfSystem.cut(
        page: page,
        top: 20,
        bottom: 76,
        left: 40,
        right: 200,
        staves: staves,
        cuts: cuts,
        gaps: cuts.isEmpty ? const {} : {0: 48},
        barlines: const [PdfBarline(120), PdfBarline(200)]);
    final layout = PdfScoreLayout(
      title: 'Divisi',
      pages: const [ui.Size(240, 120), ui.Size(240, 120)],
      instruments: const [violin],
      systems: [
        // Together on one staff, then divided onto two: the second one division 2's.
        system(0, const [PdfStaff(top: 20, space: 4, part: 'P1')]),
        system(1, const [PdfStaff(top: 20, space: 4, part: 'P1'), PdfStaff(top: 60, space: 4, part: 'P1', staff: 2)], cuts: [40]),
      ],
      masks: const [PdfMask(1, ui.Rect.fromLTRB(50, 30, 60, 40)), PdfMask(1, ui.Rect.fromLTRB(50, 60, 60, 70), 'P1d2')],
    );
    // A mask of one lane's is left out of its staves only.
    expect(layout.masksOf(layout.systems[1]).all, [const ui.Rect.fromLTRB(50, 30, 60, 40)]);
    expect(layout.masksOf(layout.systems[1]).staves, {
      1: [const ui.Rect.fromLTRB(50, 60, 60, 70)],
    });
    expect(PdfScoreLayout.fromJson(layout.toJson()).masks, layout.masks);
    expect([for (final p in violin.players) (p.id, p.name)], [('P1', 'Violin'), ('P1d2', 'Violin 2')]);
    expect(layout.playerOf('P1d2'), (violin, 2));
    expect(layout.bars, hasLength(4));
    expect(layout.played, {
      'P1': [true, true, true, true],
      'P1d2': [false, false, true, true],
    });
    final xml = layout.musicXML();
    expect(ScoreMetadata.read(xml).parts.map((p) => p.name), ['Violin', 'Violin 2']);
    expect([_band(layout.systems[1], 0), _band(layout.systems[1], 1)], [(20.0, 40.0), (48.0, 76.0)]);
    expect([layout.systems[0].top, layout.systems[1].top, layout.systems[1].bottom], [20.0, 20.0, 76.0]);
    // A staff added takes the room between its neighbours' regions, or halfway into one that
    // covered its lines (or, drawn, the region drawn); one removed leaves its region no one's.
    final two = layout.systems[1];
    final three = two.withStaff(const PdfStaff(top: 42, space: 1));
    expect(three.ink, isNull);
    expect([for (var k = 0; k < 3; k++) _band(three, k)], [(20.0, 40.0), (40.0, 48.0), (48.0, 76.0)]);
    final middleGone = three.withoutStaff(1);
    expect([_band(middleGone, 0), _band(middleGone, 1)], [(20.0, 40.0), (48.0, 76.0)]);
    expect([_band(two.withoutStaff(0), 0), _band(two.withoutStaff(1), 0)], [(48.0, 76.0), (20.0, 40.0)]);
    final below = two.withStaff(const PdfStaff(top: 90, space: 4));
    expect([_band(below, 2), below.bottom], [(76.0, 114.0), 114.0]);
    final inside = layout.systems[0].withStaff(const PdfStaff(top: 50, space: 2));
    expect([_band(inside, 0), _band(inside, 1)], [(20.0, 43.0), (43.0, 62.0)]);
    final drawn = two.withStaff(const PdfStaff(top: 42, space: 1, regionTop: 30, regionBottom: 55, regionLeft: 60, regionRight: 150), fit: false);
    expect([drawn.regionOf(1), _band(drawn, 0), _band(drawn, 2)], [const ui.Rect.fromLTRB(60, 30, 150, 55), (20.0, 40.0), (48.0, 76.0)]);
    // A region is dragged on its own, over another's if need be, never off its lines nor
    // narrower than a space.
    final overlapping = _resized(_resized(two, 0, bottom: 64), 1, top: 10);
    expect([_band(overlapping, 0), _band(overlapping, 1), overlapping.top], [(20.0, 64.0), (10.0, 76.0), 10.0]);
    expect([_band(_resized(two, 0, top: 30, bottom: 30), 0)], [(20.0, 36.0)]);
    expect(two.withRegion(0, const ui.Rect.fromLTRB(100, 20, 90, 40)).regionOf(0), const ui.Rect.fromLTRB(100, 20, 104, 40));
    expect(PdfScoreLayout.fromJson(layout.toJson()).toJson(), layout.toJson());
    expect(PdfScoreLayout.fromJson(layout.copyWith(systems: [overlapping]).toJson()).systems.single, overlapping);
    expect(PdfScoreLayout.fromJson(layout.copyWith(systems: [drawn]).toJson()).systems.single, drawn);
    // As the pdf module's version 1 kept it: a system's top, bottom, cuts and gaps.
    final v1 = {
      ...layout.toJson(),
      'systems': [
        {
          'page': 1, 'top': 20, 'bottom': 76, 'left': 40, 'right': 200, 'cuts': [40], 'gaps': [[0, 48]], //
          'staves': [
            {'top': 20, 'space': 4, 'lines': 5, 'part': 'P1', 'staff': 1},
            {'top': 60, 'space': 4, 'lines': 5, 'part': 'P1', 'staff': 2},
          ],
          'barlines': [[120, 'normal'], [200, 'normal']],
        },
      ],
    };
    expect(PdfScoreLayout.fromJson(PdfScoreLayout.upgradeJson(v1)).systems.single, layout.systems[1]);

    // Changes inserted: a tempo mark, the violin's own clef and time signature from bar 2.
    final changed = layout.copyWith(
      instruments: [violin.copyWith(clefs: {(1, 1): PdfClef.alto}, meters: {1: const PdfMeter('6', 8)})],
      tempos: {0: const PdfTempo('Allegro'), 1: const PdfTempo('rit.')},
    );
    final v = changed.instruments.single;
    expect([v.clefAt(0, 1), v.clefAt(3, 1)], [PdfClef.treble, PdfClef.alto]);
    expect(['${changed.meterOf(v, 0)}', '${changed.meterOf(v, 2)}', '${changed.meterAt(2)}'], ['4/4', '6/8', '4/4']);
    final changedXml = changed.musicXML();
    expect(changedXml, contains('<direction id="${PdfScoreLayout.tempoId(1)}"'));
    expect(changedXml, contains('<words>Allegro</words>'));
    expect(changedXml, contains('<sign>C</sign><line>3</line>'));
    expect(PdfScoreLayout.fromJson(changed.toJson()), changed);
    // A key read off a transposing staff is kept as the concert key; a name says the transposition.
    expect(PdfInstrument.keyForName('Clarinet in B♭'), SpacerKey.bFlat);
    expect(PdfInstrument.keyForName('Klarinette in B'), SpacerKey.bFlat, reason: 'German for B♭');
    expect(PdfInstrument.keyForName('Bass Clarinet'), SpacerKey.c);
    expect(SpacerKey.bFlat.concertOf(SpacerKey.bFlat.keyOf(-3)), -3);
    expect(const PdfInstrument(id: 'P2', name: 'Clarinet in B♭', key: SpacerKey.bFlat).renamed('Flute').key, SpacerKey.c);

    // A blank lane: a part of the score that no staff is, and that shows no signature.
    final blanked = layout.copyWith(instruments: [const PdfInstrument.blank(id: 'P2'), violin]);
    expect(PdfScoreLayout.fromJson(blanked.toJson()), blanked);
    expect(blanked.played['P2'], [false, false, false, false]);
    final metadata = ScoreMetadata.read(blanked.musicXML());
    expect(metadata.parts.map((p) => p.id), ['P2', 'P1', 'P1d2']);
    final staffOfBlank = metadata.parts.first.staffNumbers.single;
    expect(PdfEngraving.of(blanked, metadata).signatures.where((s) => s.staff == staffOfBlank), isEmpty);

    // Words on the pages (the PDF's own, or read off a scan): a name left of the staves, a
    // shorter one later; tempo marks above a system's first staff, at the bar they start over.
    final runs = {
      0: const [
        PdfTextRun('Divisi Suite', ui.Rect.fromLTRB(80, 2, 160, 10)), // the title: no tempo
        PdfTextRun('Violin', ui.Rect.fromLTRB(5, 24, 30, 30)),
        PdfTextRun('a dedication', ui.Rect.fromLTRB(5, 50, 30, 56)), // in its region, well below it
        PdfTextRun('Allegro (q', ui.Rect.fromLTRB(45, 10, 80, 16)),
        PdfTextRun('= 120)', ui.Rect.fromLTRB(82, 10, 100, 16)),
        PdfTextRun('dolce', ui.Rect.fromLTRB(50, 38, 70, 44)), // below the first staff's top
      ],
      1: const [
        PdfTextRun('2 Vl.', ui.Rect.fromLTRB(10, 44, 30, 50)), // a bar's number read with it
        PdfTextRun('rit.', ui.Rect.fromLTRB(125, 12, 140, 18)),
      ],
    };
    expect(PdfText.names(layout, runs), {'P1': (name: 'Violin', abbreviation: 'Vl.')});
    expect(PdfText.tempos(layout, runs), {0: const PdfTempo('Allegro', 120), 3: const PdfTempo('rit.')});
    expect([PdfText.tempoOf('Promenade'), PdfText.tempoOf('Più mosso')?.words], [null, 'Più mosso']);
  });
}
