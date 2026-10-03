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

  test('quarters and x map both ways, in order', () {
    final axis = ScoreAxis(score.engraving, score.timeline.measureStarts);
    final starts = score.timeline.measureStarts;
    var last = double.negativeInfinity;
    for (var q = 0.0; q <= starts.last; q += 0.25) {
      final x = axis.xAt(q);
      expect(x, greaterThan(last));
      expect(axis.quarterAt(x), closeTo(q, 1e-6));
      last = x;
    }
    expect(axis.xAt(starts[1]), closeTo(score.engraving.measures[1].onsetXs.first, 1e-6), reason: 'bar 2 starts at its first note');
  });

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
}
