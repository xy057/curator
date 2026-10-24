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

/// The size of the first music-font glyph from [first] to [last] (SMuFL code points).
double glyphSize(LoadedScore s, int first, int last) {
  final d = s.engraving;
  for (var i = 0; i < d.commandCount; i++) {
    final b = i * Cmd.words, code = d.commandInts[b + Cmd.codepoint];
    if (d.commandInts[b + Cmd.kind] == VBKind.glyph && code >= first && code <= last) return d.commandFloats[b + Cmd.size];
  }
  throw StateError('No glyph from ${first.toRadixString(16)}.');
}

/// A bar of every music symbol the typography sizes: segno, pedal, 8va, a dynamic, a chord
/// symbol, an accidental, an articulation, fingering, a trill, a fermata, a breath mark; then a
/// triplet, a caesura and a coda.
String symbolsScore() {
  String note(String step, int duration, {String type = 'quarter', int alter = 0, String extra = '', String notations = ''}) =>
      '<note><pitch><step>$step</step>${alter != 0 ? '<alter>$alter</alter>' : ''}<octave>5</octave></pitch>'
      '<duration>$duration</duration><type>$type</type>${alter != 0 ? '<accidental>sharp</accidental>' : ''}$extra'
      '${notations.isEmpty ? '' : '<notations>$notations</notations>'}</note>';
  String direction(String type, {String sound = ''}) =>
      '<direction placement="above"><direction-type>$type</direction-type>$sound</direction>';
  const triplet = '<time-modification><actual-notes>3</actual-notes><normal-notes>2</normal-notes></time-modification>';
  return '<?xml version="1.0" encoding="UTF-8"?><score-partwise version="4.0">'
      '<part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list><part id="P1">'
      '<measure number="1"><attributes><divisions>6</divisions><key><fifths>0</fifths></key>'
      '<time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>'
      '${direction('<segno/>')}${direction('<pedal type="start" line="no"/>')}'
      '${direction('<octave-shift type="down" size="8"/>')}${direction('<dynamics><mf/></dynamics>')}'
      '<harmony><root><root-step>C</root-step></root><kind>major</kind></harmony>'
      '${note('C', 6, alter: 1, notations: '<articulations><accent/></articulations><technical><fingering>4</fingering></technical>')}'
      '${note('D', 6, notations: '<ornaments><trill-mark/></ornaments>')}'
      '${note('E', 6, notations: '<fermata type="upright"/>')}'
      '${note('F', 6, notations: '<articulations><breath-mark/></articulations>')}</measure>'
      '<measure number="2">'
      '${note('G', 2, type: 'eighth', extra: triplet, notations: '<tuplet type="start" bracket="yes"/>')}'
      '${note('A', 2, type: 'eighth', extra: triplet)}'
      '${note('B', 2, type: 'eighth', extra: triplet, notations: '<tuplet type="stop"/>')}'
      '${note('C', 12, type: 'half', notations: '<articulations><caesura/></articulations>')}'
      '${note('D', 6)}${direction('<octave-shift type="stop" size="8"/>')}${direction('<pedal type="stop" line="no"/>')}'
      '${direction('<coda/>')}</measure></part></score-partwise>';
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

    // The music symbols, each its own size (SMuFL code points, or a text); the notes as they were.
    final symbols = <String, (Object, double)>{
      'dynamics': ((0xE520, 0xE54F), 1.5),
      'articulations': ((0xE4A0, 0xE4BF), 1.6),
      'accidentals': ((0xE260, 0xE26F), 1.7),
      'ornaments': ((0xE560, 0xE5AF), 0.5),
      'fermatas': ((0xE4C0, 0xE4CD), 2.0),
      'breathMarks': ((0xE4CE, 0xE4D6), 1.8),
      'tupletNumbers': ((0xE880, 0xE88F), 1.25),
      'fingering': ('4', 1.4),
      'chordSymbols': ('C', 1.3),
      'pedal': ((0xE650, 0xE65F), 1.9),
      'octave': ((0xE510, 0xE51F), 0.6),
      'segnoCoda': ((0xE047, 0xE048), 2.2),
    };
    expect(symbols.keys, [for (final k in TextKind.values) if (k.isSymbol) k.name]);
    var sized = ScoreTypography.standard;
    for (final MapEntry(:key, value: (_, scale)) in symbols.entries) {
      sized = sized.withValue('$key.size', scale);
    }
    final plain = await LoadedScore.load(symbolsScore()), big = await plain.withEdits(typography: sized);
    double sizeOf(LoadedScore s, Object what) =>
        what is (int, int) ? glyphSize(s, what.$1, what.$2) : runOf(s, what as String).size;
    for (final MapEntry(:key, value: (what, scale)) in [...symbols.entries, const MapEntry('notes', ((0xE0A4, 0xE0A4), 1.0))]) {
      final was = sizeOf(plain, what);
      expect(sizeOf(big, what), closeTo(was * scale, was * 0.02), reason: key);
    }

    // Only the drawn kinds differ: the same engraving.
    final drawn = typography.withValue('barNumbers.opacity', 0.8).withValue('names.face', TextFace.italic);
    expect(EngraveRequest(typography: drawn), EngraveRequest(typography: typography));
    expect(EngraveRequest(typography: typography), isNot(const EngraveRequest()));
    expect(ScoreTypography.fromJson(drawn.toJson()), drawn);
    expect(() => ScoreTypography.fromJson({'names': {'size': 9}}), throwsFormatException);
  });
}
