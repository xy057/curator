import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_score.dart';

/// A plain colour, drawn wherever it goes; records where.
class _Swatch implements PatchArt {
  final drawn = <ui.Rect>[];
  @override
  ui.Size get size => const ui.Size(100, 50);
  @override
  void paint(ui.Canvas canvas, ui.Rect source, ui.Rect destination, {double opacity = 1}) {
    drawn.add(destination);
    canvas.drawRect(destination, ui.Paint()..color = const ui.Color(0xFFFF0000));
  }
}

void main() {
  late LoadedScore score;
  setUpAll(() async => score = await LoadedScore.load(demoScore()));

  test('a patch scrolls with the score and is pinned to its quarter', () {
    final scene = CuratedScene(score);
    final curation = Curation([for (final p in score.metadata.parts) p.id]);
    const size = ui.Size(960, 540);
    final art = _Swatch();
    final quarter = score.timeline.measureStarts[4]; // bar 5
    scene.patches = [ScenePatch(quarter: quarter, top: 2, width: 10, height: 5, art: art)];

    final sounds = score.timeline.secondsAtQuarter(quarter);
    final atPointer = scene.patchRect(scene.patches.single, sounds, size);
    expect(atPointer.left, closeTo(scene.renderer.pointerX(size.width), 1), reason: 'under the pointer as bar 5 sounds');
    expect(atPointer.top, 2 * scene.style.staffSpace);
    expect(atPointer.width, 10 * scene.style.staffSpace);
    final later = scene.patchRect(scene.patches.single, sounds + 1, size);
    expect(later.left, lessThan(atPointer.left), reason: 'it moves left with the music');
    expect(scene.quarterAtFrameX(later.left, sounds + 1, size), closeTo(quarter, 1e-6));

    final recorder = ui.PictureRecorder();
    scene.paint(ui.Canvas(recorder), size, time: sounds, curation: curation, devicePixelRatio: 1);
    recorder.endRecording().dispose();
    expect(art.drawn.single, atPointer);
    art.drawn.clear();
    final recorder2 = ui.PictureRecorder();
    scene.paint(ui.Canvas(recorder2), size, time: 0, curation: curation, devicePixelRatio: 1);
    recorder2.endRecording().dispose();
    expect(art.drawn, isEmpty, reason: 'off screen at the start');
    scene.dispose();
  });

  test('spacers: a vertical one is an empty part of its own, a horizontal one a stretch made wider', () async {
    const spacers = [
      VerticalSpacer(id: 'spacer-1', key: SpacerKey.bFlat, lines: true, frozen: true, height: 10),
      VerticalSpacer(id: 'spacer-2'),
    ];
    // Bar 5's second half and bar 6's first (6/8: three quarters a bar), 8 staff spaces wider.
    const gap = HorizontalSpacer(bar: 4, offset: 1.5, length: 3, width: 8);
    final spaced = await LoadedScore.load(demoScore(), spacers: spacers, gaps: const [gap]);
    expect([for (final p in spaced.metadata.parts.skip(score.metadata.parts.length)) p.id], ['spacer-1', 'spacer-2']);
    expect(spaced.metadata.parts.last.name, 'Spacer 2');
    expect(spaced.condensing.partners.keys, isNot(contains('spacer-1')), reason: 'never paired');
    expect(spaced.engraving.measures.length, score.engraving.measures.length);

    // What sounds in it spreads apart by time, half the width in each bar; the rest as it was.
    final sp = spaced.engraving.staffSpace;
    final (plain, wide) = (score.engraving.measures, spaced.engraving.measures);
    for (var k = 0; k < plain[3].onsetXs.length; k++) {
      expect(wide[3].onsetXs[k], closeTo(plain[3].onsetXs[k], 1), reason: 'bar 4 unchanged');
    }
    double moved(int m, int k) => wide[m].onsetXs[k] - wide[m].left - (plain[m].onsetXs[k] - plain[m].left);
    for (var k = 0; k < plain[4].onsetXs.length; k++) {
      final t = plain[4].onsetTimes[k];
      expect(moved(4, k), closeTo(8 * sp * ((t - 1.5) / 3).clamp(0, 1), sp / 2), reason: 'bar 5 at $t');
    }
    expect((wide[4].right - wide[4].left) - (plain[4].right - plain[4].left), closeTo(4 * sp, sp / 2));
    for (var k = 0; k < plain[5].onsetXs.length; k++) {
      final t = plain[5].onsetTimes[k];
      expect(moved(5, k), closeTo(4 * sp * (t / 1.5).clamp(0, 1), sp / 2), reason: 'bar 6 at $t');
    }
    expect(Spacers.verovioOption(const [gap], const [3, 3, 3, 3, 3, 3]), '4:1.5:3.0:4.0,5:0.0:1.5:4.0');

    // Its key: the score's as heard, in B♭.
    final flute = score.metadata.parts.firstWhere((p) => p.name.contains('Flute')).staffNumbers.first;
    final concert = score.engraving.signatures.whereType<KeySignature>().firstWhere((k) => k.staff == flute).fifths;
    final n1 = spaced.metadata.parts.firstWhere((p) => p.id == 'spacer-1').staffNumbers.first;
    expect(spaced.engraving.signatures.whereType<KeySignature>().firstWhere((k) => k.staff == n1).fifths,
        SpacerKey.bFlat.keyOf(concert));

    // Drawn as it looks: lines with room about them, or nothing that tall.
    final scene = CuratedScene(spaced)..settings = const SceneSettings(spacers: spacers);
    final index = {for (final (i, s) in scene.display.staves.indexed) s.info.n: i};
    final n2 = spaced.metadata.parts.last.staffNumbers.first;
    final (lined, blank) = (scene.display.staves[index[n1]!], scene.display.staves[index[n2]!]);
    expect(lined.lines, isNotEmpty);
    expect(lined.reach, closeTo(3 * sp, 0.01));
    expect(blank.items, isEmpty);
    expect(blank.lines, isEmpty);
    expect(blank.info.height, closeTo(6 * sp, 0.01));
    expect(scene.renderer.bare, {index[n2]}, reason: 'the frozen zone draws only the first');
    scene.dispose();
  });
}
