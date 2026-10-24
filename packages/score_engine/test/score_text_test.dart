import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';
import 'package:score_engine/src/engraving.dart' show Cmd;
import 'package:score_engine/src/native/bindings.dart' show VBFlag, VBKind;

import 'demo_score.dart';

String engravedText(LoadedScore s) => utf8.decode(s.engraving.text, allowMalformed: true);

/// The first run of engraved text that says [words]: its size, flags and letter spacing.
({double size, int flags, double spacing}) runOf(LoadedScore s, String words) {
  final d = s.engraving;
  for (var i = 0; i < d.commandCount; i++) {
    final b = i * Cmd.words, start = d.commandInts[b + Cmd.start];
    if (d.commandInts[b + Cmd.kind] != VBKind.text ||
        utf8.decode(d.text.sublist(start, start + d.commandInts[b + Cmd.count])) != words) {
      continue;
    }
    return (size: d.commandFloats[b + Cmd.size], flags: d.commandInts[b + Cmd.flags], spacing: d.commandFloats[b + Cmd.letterSpacing]);
  }
  throw StateError('No “$words”.');
}

void main() {
  late LoadedScore score;

  setUpAll(() async => score = await LoadedScore.load(demoScore()));

  test('editing a text or its look re-engraves; an empty edit removes it', () async {
    final vivo = score.texts.firstWhere((t) => t.text == 'Vivo');
    final edited = await score.withTextEdits({vivo.id: 'Presto'});
    expect(engravedText(edited), contains('Presto'));
    expect(engravedText(edited), isNot(contains('Vivo')));
    expect(edited.currentText(edited.texts.firstWhere((t) => t.id == vivo.id)), 'Presto');
    expect(edited.engraving.measures.length, score.engraving.measures.length); // structure unchanged

    final removed = await score.withTextEdits({vivo.id: ''});
    expect(engravedText(removed), isNot(contains('Vivo')));

    // What the words say of the speed (the bar numbers' row shows them at the frame's left).
    final rit = score.texts.firstWhere((t) => t.text == 'poco rit.');
    expect([for (final w in ['Vivo', 'poco rit.', 'accel.', 'a tempo', 'dolce']) rit.tempoRole(w)],
        [TempoRole.none, TempoRole.change, TempoRole.change, TempoRole.back, TempoRole.none]);
    expect(vivo.tempoRole('Vivo'), TempoRole.tempo);

    // Typography: the engraved kinds are laid out by Verovio as set; the drawn ones never
    // engrave again.
    final typography = ScoreTypography.standard
        .withValue('tempo.size', 1.5)
        .withValue('tempo.face', TextFace.bold)
        .withValue('tempo.tracking', 0.1);
    final styled = await score.withEdits(typography: typography);
    final before = runOf(score, 'Vivo'), after = runOf(styled, 'Vivo');
    expect(after.size, closeTo(before.size * 1.5, 1));
    expect(after.flags & VBFlag.bold, isNot(0));
    expect(after.spacing, greaterThan(0));
    expect(runOf(styled, 'pizz.').size, runOf(score, 'pizz.').size); // an expression: as it was

    // Only the drawn kinds differ: the same engraving.
    final drawn = typography.withValue('barNumbers.opacity', 0.8).withValue('names.face', TextFace.italic);
    expect(EngraveRequest(typography: drawn), EngraveRequest(typography: typography));
    expect(EngraveRequest(typography: typography), isNot(const EngraveRequest()));
    expect(ScoreTypography.fromJson(drawn.toJson()), drawn);
    expect(() => ScoreTypography.fromJson({'names': {'size': 9}}), throwsFormatException);
  });
}
