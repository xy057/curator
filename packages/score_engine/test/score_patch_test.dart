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

  test('spacers: a vertical one is an empty part of its own, a horizontal one a blank between beats', () async {
    const spacers = [
      VerticalSpacer(id: 'spacer-1', key: SpacerKey.bFlat, lines: true, frozen: true, height: 10),
      VerticalSpacer(id: 'spacer-2'),
    ];
    const gap = HorizontalSpacer(bar: 4, offset: 1.5, width: 8);
    final spaced = await LoadedScore.load(demoScore(), spacers: spacers, gaps: const [gap]);
    expect([for (final p in spaced.metadata.parts.skip(score.metadata.parts.length)) p.id], ['spacer-1', 'spacer-2']);
    expect(spaced.metadata.parts.last.name, 'Spacer 2');
    expect(spaced.condensing.partners.keys, isNot(contains('spacer-1')), reason: 'never paired');
    expect(spaced.engraving.measures.length, score.engraving.measures.length);

    // The blank: before the onsets at and after 1.5 quarters into bar 5, as wide as asked; the rest as it was.
    final sp = spaced.engraving.staffSpace;
    final (plain, wide) = (score.engraving.measures, spaced.engraving.measures);
    for (var k = 0; k < plain[3].onsetXs.length; k++) {
      expect(wide[3].onsetXs[k], closeTo(plain[3].onsetXs[k], 1), reason: 'bar 4 unchanged');
    }
    for (var k = 0; k < plain[4].onsetXs.length; k++) {
      final moved = wide[4].onsetXs[k] - wide[4].left - (plain[4].onsetXs[k] - plain[4].left);
      expect(moved, plain[4].onsetTimes[k] < gap.offset ? closeTo(0, 1) : closeTo(8 * sp, sp / 2));
    }

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
