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
  test('PDF import: a page’s systems, staves and bars found (ties told from lines, a staff leaning), an AI model’s answer put on the ink, the layout round-tripping', () {
    {
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
    }

    // A staff’s lines are told from ties over it, and found leaning.
    {
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
    }

    // An AI model’s answer is put on the page’s ink, and into the layout.
    {
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
    }

    // A divided instrument is a part a division, and the layout round-trips.
    {
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
      expect(PdfScoreLayout.fromJson(layout.toJson()).toJson(), layout.toJson());
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
    }
  });
}
