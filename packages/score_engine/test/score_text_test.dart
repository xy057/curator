import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_score.dart';


String engravedText(LoadedScore s) => utf8.decode(s.engraving.text, allowMalformed: true);

void main() {
  late LoadedScore score;

  setUpAll(() async => score = await LoadedScore.load(demoScore()));

  test('every direction text is listed with a stable id', () async {
    final vivo = score.texts.firstWhere((t) => t.text == 'Vivo');
    expect(vivo.kind, ScoreTextKind.tempo); // it carries a tempo
    expect(score.texts.where((t) => t.text == 'arco'), isNotEmpty);
    // Ids are deterministic, so edits keep pointing at the same text after re-engraving.
    final again = await LoadedScore.load(demoScore());
    expect(again.texts.map((t) => t.id), score.texts.map((t) => t.id));
    // The engraving knows which drawn text came from which id.
    expect(score.engraving.sourceIds, contains(vivo.id));
  });

  test('editing a text re-engraves with the new words; an empty edit removes it', () async {
    final vivo = score.texts.firstWhere((t) => t.text == 'Vivo');
    final edited = await score.withTextEdits({vivo.id: 'Presto'});
    expect(engravedText(edited), contains('Presto'));
    expect(engravedText(edited), isNot(contains('Vivo')));
    expect(edited.currentText(edited.texts.firstWhere((t) => t.id == vivo.id)), 'Presto');
    expect(edited.engraving.measures.length, score.engraving.measures.length); // structure unchanged

    final removed = await score.withTextEdits({vivo.id: ''});
    expect(engravedText(removed), isNot(contains('Vivo')));
  });

  test('a text can be found under the pointer in the preview', () {
    final scene = CuratedScene(score);
    const size = ui.Size(1600, 900);
    final curation = Curation(score.metadata.parts.map((p) => p.id));
    for (final p in score.metadata.parts) {
      curation.setLane(p.id, [Region(0, score.timeline.measureStarts.last)]);
    }
    final vivo = score.texts.firstWhere((t) => t.text == 'Vivo');
    // Put the bar with "Vivo" under the pointer, then look for the text on screen.
    final time = score.timeline.secondsAtQuarter(score.timeline.measureStarts[vivo.measure]);
    final layout = scene.layoutAt(time, curation, size);
    ({String id, ui.Rect rect})? hit;
    for (final placement in layout.placements) {
      for (var y = placement.y - 60; y < placement.y + 100 && hit?.id != vivo.id; y += 4) {
        for (var x = scene.renderer.musicLeft + 10; x < size.width && hit?.id != vivo.id; x += 6) {
          final h = scene.textAt(ui.Offset(x, y), time, curation, size);
          if (h != null && h.id == vivo.id) hit = h;
        }
      }
      if (hit != null) break;
    }
    expect(hit, isNotNull);
    expect(hit!.rect.width, greaterThan(10));
    scene.dispose();
  });
}
