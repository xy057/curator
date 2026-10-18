import 'dart:convert';

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
}
