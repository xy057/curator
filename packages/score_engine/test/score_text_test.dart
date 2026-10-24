import 'dart:convert';
import 'dart:ui' show Rect;

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

/// The size and box of the first music-font glyph from [first] to [last] (SMuFL code points).
({double size, Rect box}) glyphOf(LoadedScore s, int first, int last) {
  final d = s.engraving, f = d.commandFloats;
  for (var i = 0; i < d.commandCount; i++) {
    final b = i * Cmd.words, code = d.commandInts[b + Cmd.codepoint];
    if (d.commandInts[b + Cmd.kind] == VBKind.glyph && code >= first && code <= last) {
      return (size: f[b + Cmd.size], box: Rect.fromLTWH(f[b + Cmd.bounds], f[b + Cmd.bounds + 1], f[b + Cmd.bounds + 2], f[b + Cmd.bounds + 3]));
    }
  }
  throw StateError('No glyph from ${first.toRadixString(16)}.');
}

/// A bar of every music symbol the typography sizes: a clef, key and time signature, segno,
/// pedal, 8va, a dynamic, a chord symbol, an accidental, an articulation, fingering, a trill, a
/// fermata, a breath mark; then a triplet (flagged), a caesura, a rest and a coda; an arpeggiated
/// chord, a dotted note with a tremolo, a wavy glissando; and a bar repeat. The trill has its wavy
/// line, bar 2 ends with a repeat; a guitar plays a fret on a tab staff below.
String symbolsScore() {
  String note(String step, int duration, {String type = 'quarter', int alter = 0, String extra = '', String notations = ''}) =>
      '<note><pitch><step>$step</step>${alter != 0 ? '<alter>$alter</alter>' : ''}<octave>5</octave></pitch>'
      '<duration>$duration</duration><type>$type</type>${alter != 0 ? '<accidental>sharp</accidental>' : ''}$extra'
      '${notations.isEmpty ? '' : '<notations>$notations</notations>'}</note>';
  String direction(String type, {String sound = ''}) =>
      '<direction placement="above"><direction-type>$type</direction-type>$sound</direction>';
  const triplet = '<time-modification><actual-notes>3</actual-notes><normal-notes>2</normal-notes></time-modification>';
  return '<?xml version="1.0" encoding="UTF-8"?><score-partwise version="4.0">'
      '<part-list><score-part id="P1"><part-name>Piano</part-name></score-part>'
      '<score-part id="P2"><part-name>Guitar</part-name></score-part></part-list><part id="P1">'
      '<measure number="1"><attributes><divisions>6</divisions><key><fifths>-1</fifths></key>'
      '<time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>'
      '${direction('<segno/>')}${direction('<pedal type="start" line="no"/>')}'
      '${direction('<octave-shift type="down" size="8"/>')}${direction('<dynamics><mf/></dynamics>')}'
      '<harmony><root><root-step>C</root-step><root-alter>1</root-alter></root><kind>major</kind></harmony>'
      '${note('C', 6, alter: 1, notations: '<articulations><accent/></articulations><technical><fingering>4</fingering></technical>')}'
      '${note('D', 6, notations: '<ornaments><trill-mark/><wavy-line type="start"/></ornaments>')}'
      '${note('E', 6, notations: '<fermata type="upright"/><ornaments><wavy-line type="stop"/></ornaments>')}'
      '${note('F', 6, notations: '<articulations><breath-mark/></articulations>')}</measure>'
      '<measure number="2">'
      '${note('G', 2, type: 'eighth', extra: triplet, notations: '<tuplet type="start" bracket="yes"/>')}'
      '${note('A', 2, type: 'eighth', extra: triplet)}'
      '${note('B', 2, type: 'eighth', extra: triplet, notations: '<tuplet type="stop"/>')}'
      '${note('C', 12, type: 'half', notations: '<articulations><caesura/></articulations>')}'
      '<note><rest/><duration>6</duration><type>quarter</type></note>${direction('<octave-shift type="stop" size="8"/>')}${direction('<pedal type="stop" line="no"/>')}'
      '${direction('<coda/>')}<barline location="right"><bar-style>light-heavy</bar-style><repeat direction="backward"/></barline></measure>'
      '<measure number="3">'
      '${note('C', 6, notations: '<arpeggiate/>')}<note><chord/><pitch><step>E</step><octave>5</octave></pitch>'
      '<duration>6</duration><type>quarter</type><notations><arpeggiate/></notations></note>'
      '${note('G', 9, extra: '<dot/>', notations: '<ornaments><tremolo type="single">3</tremolo></ornaments>')}'
      '${note('A', 3, type: 'eighth', notations: '<glissando type="start" line-type="wavy"/>')}'
      '${note('B', 6, notations: '<glissando type="stop" line-type="wavy"/>')}</measure>'
      '<measure number="4"><attributes><measure-style><measure-repeat type="start">1</measure-repeat></measure-style></attributes>'
      '<note><rest measure="yes"/><duration>24</duration></note></measure>'
      '<measure number="5"><attributes><measure-style><measure-repeat type="stop"/></measure-style></attributes>'
      '${note('C', 24, type: 'whole')}</measure></part><part id="P2">'
      '<measure number="1"><attributes><divisions>6</divisions><key><fifths>-1</fifths></key>'
      '<time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>TAB</sign><line>5</line></clef>'
      '<staff-details><staff-lines>6</staff-lines></staff-details></attributes>'
      '<note><pitch><step>F</step><alter>1</alter><octave>4</octave></pitch><duration>24</duration><type>whole</type>'
      '<notations><technical><string>2</string><fret>7</fret></technical></notations></note></measure>'
      '${[for (var m = 2; m <= 5; m++) '<measure number="$m"><note><rest measure="yes"/><duration>24</duration></note></measure>'].join()}'
      '</part></score-partwise>';
}

/// The width of the first augmentation dot (drawn as a circle).
double dotWidth(LoadedScore s) {
  final d = s.engraving, dots = d.classNames.indexOf('dots');
  for (var i = 0; i < d.commandCount; i++) {
    final b = i * Cmd.words;
    if (d.commandInts[b + Cmd.kind] == VBKind.path && d.commandInts[b + Cmd.classIndex] == dots) {
      return d.pathFloats[d.commandInts[b + Cmd.start] * 7 + 3];
    }
  }
  throw StateError('No dot.');
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

    // The music symbols, each its own size (SMuFL code points, or a text).
    final symbols = <String, (Object, double)>{
      'clefs': ((0xE050, 0xE07F), 1.3),
      'keySignatures': ((0xE260, 0xE260), 1.45),
      'timeSignatures': ((0xE080, 0xE089), 2.1),
      'noteheads': ((0xE0A4, 0xE0A4), 0.85),
      'flags': ((0xE240, 0xE24F), 1.55),
      'dots': ('dot', 1.75),
      'rests': ((0xE4E5, 0xE4E5), 1.35),
      'accidentals': ((0xE262, 0xE262), 1.7),
      'articulations': ((0xE4A0, 0xE4BF), 1.6),
      'dynamics': ((0xE520, 0xE54F), 1.5),
      'ornaments': ((0xE560, 0xE5AF), 0.5),
      'fermatas': ((0xE4C0, 0xE4CD), 2.0),
      'breathMarks': ((0xE4CE, 0xE4D6), 1.8),
      'tremolos': ((0xE220, 0xE22F), 2.3),
      'arpeggios': ((0xEAA9, 0xEAA9), 1.65),
      'glissandos': ((0xEAAF, 0xEAAF), 1.85),
      'tupletNumbers': ((0xE883, 0xE883), 1.25),
      'pedal': ((0xE650, 0xE65F), 1.9),
      'octave': ((0xE510, 0xE51F), 0.6),
      'barRepeats': ((0xE500, 0xE50F), 1.2),
      'repeatDots': ((0xE044, 0xE044), 1.5),
      'tablature': ('7', 1.45),
      'segnoCoda': ((0xE047, 0xE048), 2.2),
    };
    expect(symbols.keys, [for (final k in TextKind.values) if (k.isSymbol) k.name]);
    expect(() => ScoreTypography.standard.withValue('noteheads.size', 1.1), throwsFormatException);
    final plain = await LoadedScore.load(symbolsScore());
    double sizeOf(LoadedScore s, Object what) => switch (what) {
          (int, int) range => glyphOf(s, range.$1, range.$2).size,
          'dot' => dotWidth(s),
          _ => runOf(s, what as String).size,
        };
    // Each its own size, bigger (the ornaments and octave marks smaller), then all at 60%.
    for (final small in [false, true]) {
      var sized = ScoreTypography.standard;
      for (final MapEntry(:key, value: (_, scale)) in symbols.entries) {
        sized = sized.withValue('$key.size', small ? 0.6 : scale);
      }
      // Fingering and chord symbols, text set by options of their own: size, face, letter spacing.
      sized = sized
          .withValue('fingering.size', small ? 0.6 : 1.4)
          .withValue('fingering.face', TextFace.bold)
          .withValue('fingering.tracking', 0.1)
          .withValue('chordSymbols.size', small ? 0.6 : 1.3)
          .withValue('chordSymbols.face', TextFace.italic)
          .withValue('chordSymbols.tracking', 0.05);
      final big = await plain.withEdits(typography: sized);
      for (final MapEntry(:key, value: (what, scale)) in symbols.entries) {
        final was = sizeOf(plain, what);
        expect(sizeOf(big, what), closeTo(was * (small ? 0.6 : scale), was * 0.03), reason: '$key${small ? ' small' : ''}');
      }
      // Parts that follow their kind: the trill's wavy line, the tab clef.
      for (final (code, kind) in [(0xE59D, 'ornaments'), (0xE06D, 'clefs')]) {
        final was = glyphOf(plain, code, code).size, scale = small ? 0.6 : symbols[kind]!.$2;
        expect(glyphOf(big, code, code).size, closeTo(was * scale, was * 0.03), reason: code.toRadixString(16));
      }
      for (final (words, scale, flag) in [
        ('4', small ? 0.6 : 1.4, VBFlag.bold),
        ('C', small ? 0.6 : 1.3, VBFlag.italic),
        (String.fromCharCode(0xEA66), small ? 0.6 : 1.3, 0), // the chord's sharp, in the music font
      ]) {
        final was = runOf(plain, words), now = runOf(big, words);
        expect(now.size, closeTo(was.size * scale, was.size * 0.03), reason: words);
        if (flag != 0) expect((now.flags & flag, now.spacing > 0), (flag, true), reason: words);
      }
      // They keep clear: a sharp moves aside from its note's accent, a caesura sits between its
      // note and the rest after; the frozen zone's clef, key and time are as big.
      expect(glyphOf(big, 0xE262, 0xE262).box.overlaps(glyphOf(big, 0xE4A0, 0xE4A1).box), isFalse);
      expect(glyphOf(big, 0xE4D1, 0xE4D1).box.overlaps(glyphOf(big, 0xE4E5, 0xE4E5).box), isFalse);
      final zone = FrozenZone(big.engraving, const RenderStyle(), typography: sized).maxWidth;
      final house = FrozenZone(plain.engraving, const RenderStyle()).maxWidth;
      expect(zone, small ? lessThan(house * 0.8) : greaterThan(house * 1.3));
    }

    // Only the drawn kinds differ: the same engraving.
    final drawn = typography.withValue('barNumbers.opacity', 0.8).withValue('names.face', TextFace.italic);
    expect(EngraveRequest(typography: drawn), EngraveRequest(typography: typography));
    expect(EngraveRequest(typography: typography), isNot(const EngraveRequest()));
    expect(ScoreTypography.fromJson(drawn.toJson()), drawn);
    expect(() => ScoreTypography.fromJson({'names': {'size': 9}}), throwsFormatException);
  });
}
