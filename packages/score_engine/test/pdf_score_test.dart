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
      masks: const [PdfMask(1, ui.Rect.fromLTRB(50, 30, 60, 40))],
    );
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
