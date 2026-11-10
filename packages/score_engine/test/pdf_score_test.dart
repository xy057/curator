import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

/// A page of ink at [PdfDetect.scale]: two staves joined by a system barline at x 40 points,
/// with barlines through both at x 120 and 200 (the last one the system's end).
PdfRaster _page() {
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
  return PdfRaster(ink, w, h, scale: scale);
}

void main() {
  test('finds a page’s systems, staves and bars', () {
    final systems = PdfDetect.page(_page(), 0);
    expect(systems, hasLength(1));
    final system = systems.single;
    expect([for (final s in system.staves) s.top], [closeTo(20, 0.5), closeTo(60, 0.5)]);
    expect([for (final s in system.staves) s.space], [closeTo(4, 0.2), closeTo(4, 0.2)]);
    expect([for (final b in system.barlines) b.x], [closeTo(120, 0.8), closeTo(200, 0.8)]);
    // The cut between the staves is where nothing but the barlines cross.
    expect(system.cuts.single, inExclusiveRange(system.staves.first.bottom, system.staves.last.top));
    // A gap between them is no one's: the barlines crossing it go with neither staff.
    final page = _page(), cut = system.cuts.single;
    int owner(PdfSystem s, double y) => PdfDetect.assign(page, s, const [])[page.row(y).round() * page.width + page.col(120).round()];
    expect(owner(system, cut + 2), 1);
    final gapped = system.copyWith(gaps: {0: cut + 6});
    expect(gapped.bandOf(1).$1, cut + 6);
    expect([owner(gapped, cut + 2), owner(gapped, cut + 8), owner(gapped, cut - 2)], [-1, 1, 0]);
    // A mask of one staff's leaves the others' ink as it was.
    int masked(int staff) => PdfDetect.assign(page, system, const [], staffMasks: {
          staff: [ui.Rect.fromCenter(center: ui.Offset(120, cut + 2), width: 4, height: 4)],
        })[page.row(cut + 2).round() * page.width + page.col(120).round()];
    expect([masked(0), masked(1)], [1, -1]);
    // A mask in the margin right of what was read, across its last row, leaves out nothing.
    final margin = ui.Rect.fromLTRB(page.xOf(page.width) + 20, 100, page.xOf(page.width) + 40, 140);
    expect(PdfDetect.assign(page, system, [margin]), PdfDetect.assign(page, system, const []));
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
  {"label": 1, "y": ${y(34)}, "instrument": "P1", "staff": 1, "name": "Flute", "printed": "Fl.", "clef": "treble", "key": -1},
  {"label": 2, "y": ${y(74)}, "instrument": "p2", "staff": 1, "name": "Clarinet in B♭", "printed": "", "clef": "treble", "key": 1,
   "changes": [{"bar": 2, "clef": "bass"}]}],
  "top": ${y(16)}, "bottom": ${y(96)}, "borders": [{"below": 1, "y": ${y(50)}}],
  "barlines": [{"x": ${x(114)}, "kind": "single"}, {"x": ${x(196)}, "kind": "final"}],
  "time": "3/4", "tempos": [{"bar": 1, "text": "Allegro", "bpm": 132}, {"bar": 2, "text": "rit.", "bpm": null}]}]}
```''');
    final refined = PdfAi.refine(page, [system], answer, view);
    final s = refined.single.system;
    // The barline missed is found where it says, the last one kept where it was.
    expect([for (final b in s.barlines) b.x], [closeTo(120, 0.8), s.right]);
    expect([for (final b in s.barlines) b.kind], [PdfBarlineKind.normal, PdfBarlineKind.end]);
    // Where it says the staves are sets right where it says the rest is.
    expect([s.top, s.bottom, s.cuts.single], [closeTo(10, 1), closeTo(90, 1), closeTo(44, 1)]);
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

  test('the exam marks a model’s answers as Read with AI takes them', () {
    final view = PdfAiView(PdfAiExam.size);
    // A page's answer as printed, its places scaled and moved as a model's drift.
    String answer(PdfAiExamPage page,
        {double scale = 1, double by = 0, double across = 0, int borders = 99, List<Object>? barlines, List<Object>? tempos,
        Map<String, Object?> Function(int k, Map<String, Object?> staff)? staff}) {
      double y(double p) => (p * scale + by) / PdfAiExam.size.height * 1000;
      double x(double p) => (p + across) / view.width * 1000;
      return jsonEncode({
        'systems': [
          {
            'staves': [
              for (final (k, s) in page.staves.indexed)
                (staff ?? (_, m) => m)(k, {
                  'label': k + 1, 'y': y((s.top + s.bottom) / 2), 'instrument': 'P${k + 1}', 'staff': 1, //
                  'name': s.name, 'printed': s.printed, 'clef': s.clef.name, 'key': s.key,
                }),
            ],
            'top': y((page.top.$1 + page.top.$2) / 2),
            'bottom': y((page.bottom.$1 + page.bottom.$2) / 2),
            'borders': [
              for (var k = 1; k < page.staves.length && k <= borders; k++) {'below': k, 'y': y((page.staves[k - 1].bottom + page.staves[k].top) / 2)},
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

    // The clarinets' key misread, a clef change made up, two borders, four barlines and the
    // metronome mark left out, the system's end called final; the next page's answer unreadable.
    double x(double p) => p / view.width * 1000;
    final poor = score([
      answer(first,
          borders: 10,
          barlines: [for (final b in first.barlines.take(5)) {'x': x(b)}, {'x': x(first.barlines.last), 'kind': 'final'}],
          tempos: [{'bar': 1, 'text': 'Allegro ma non troppo, un poco maestoso', 'bpm': null}],
          staff: (k, s) => {...s, if (k == 2) 'key': -1, if (k == 3) 'changes': [{'bar': 3, 'clef': 'treble'}]}),
      null,
    ]);
    expect(poor.parts, {
      PdfAiExamPart.horizontal: 13 / 30,
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
    PdfSystem system(int page, List<PdfStaff> staves) => PdfSystem(
        page: page, top: 20, bottom: 76, left: 40, right: 200, staves: staves, barlines: const [PdfBarline(120), PdfBarline(200)]);
    final layout = PdfScoreLayout(
      title: 'Divisi',
      pages: const [ui.Size(240, 120), ui.Size(240, 120)],
      instruments: const [violin],
      systems: [
        // Together on one staff, then divided onto two: the second one division 2's.
        system(0, const [PdfStaff(top: 20, space: 4, part: 'P1')]),
        system(1, const [PdfStaff(top: 20, space: 4, part: 'P1'), PdfStaff(top: 60, space: 4, part: 'P1', staff: 2)])
            .copyWith(cuts: [40], gaps: {0: 48}),
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
    expect([layout.systems[1].bandOf(0), layout.systems[1].bandOf(1)], [(20.0, 40.0), (48.0, 76.0)]);
    expect(PdfScoreLayout.fromJson(layout.toJson()).systems[1].gaps, {0: 48.0});
    // A staff added or removed: its band made or left no one's, the others' kept.
    final two = layout.systems[1];
    final three = two.withStaff(const PdfStaff(top: 42, space: 1));
    expect([three.cuts, three.gaps, three.ink], [[39.0, 53.0], <int, double>{}, null]);
    expect([for (var k = 0; k < 3; k++) three.bandOf(k)], [(20.0, 39.0), (39.0, 53.0), (53.0, 76.0)]);
    final middleGone = three.withoutStaff(1);
    expect([middleGone.bandOf(0), middleGone.gapAfter(0), middleGone.bandOf(1)], [(20.0, 39.0), (39.0, 53.0), (53.0, 76.0)]);
    expect([two.withoutStaff(0).bandOf(0), two.withoutStaff(1).bandOf(0)], [(48.0, 76.0), (20.0, 40.0)]);
    final below = two.withStaff(const PdfStaff(top: 90, space: 4));
    expect([below.cuts, below.gaps, below.bottom], [[40.0, 83.0], {0: 48.0}, 114.0]);
    expect(PdfScoreLayout.fromJson(layout.toJson()).toJson(), layout.toJson());

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
        PdfTextRun('a dedication', ui.Rect.fromLTRB(5, 50, 30, 56)), // in its band, well below it
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
