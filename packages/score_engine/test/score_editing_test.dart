import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';
import 'package:xml/xml.dart';

import 'demo_score.dart';

/// A flute, two empty bars of 4/4.
const _flute = '''<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="4.0">
  <part-list><score-part id="P1"><part-name>Flute</part-name></score-part></part-list>
  <part id="P1">
    <measure number="1"><attributes><divisions>1</divisions><key><fifths>0</fifths></key><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>
      <note><rest measure="yes"/><duration>4</duration><voice>1</voice></note></measure>
    <measure number="2"><note><rest measure="yes"/><duration>4</duration><voice>1</voice></note><barline location="right"><bar-style>light-heavy</bar-style></barline></measure>
  </part>
</score-partwise>''';

void main() {
  test('the score editor types notes over rests, ties them across a barline, and writes MusicXML', () async {
    final score = EditableScore.parse(_flute);
    const voice = VoiceKey(1, '1');
    final start = ScorePosition(0, voice, 0, Frac.zero);
    Pitch near(int step, Pitch before) => Pitch.nearest(step, before);
    var before = score.pitchBefore(start); // the clef's middle line: B4
    expect(before, const Pitch(6, 4));
    final c5 = near(0, before), d5 = near(1, c5), fSharp = near(3, d5).withAlter(1), f = near(3, fSharp);
    var at = score.input(start, [
      InputItem(const Rhythm(NoteType.quarter), [c5]),
      InputItem(const Rhythm(NoteType.eighth), [d5]),
      InputItem(const Rhythm(NoteType.eighth), [fSharp]),
      InputItem(const Rhythm(NoteType.quarter), [f]),
      InputItem(const Rhythm(NoteType.half), [c5]), // a beat left: tied on into bar 2
    ]);
    expect(at, ScorePosition(0, voice, 1, Frac.one));
    final bar1 = score.eventsIn(0, 0, voice);
    expect([for (final e in bar1) e.pitches.single], [c5, d5, fSharp, f, c5]);
    expect(bar1.last.tiedOn, isTrue);
    final bar2 = score.eventsIn(0, 1, voice);
    expect(bar2.first.pitches.single, c5);
    expect([for (final e in bar2.skip(1)) e.isRest], everyElement(isTrue)); // the rest of the bar is rests

    final xml = XmlDocument.parse(score.toMusicXML());
    final notes = xml.findAllElements('note').toList();
    expect(xml.findAllElements('beam').length, 2); // the two eighths, beamed
    expect(notes[3].getElement('accidental')?.innerText, 'natural'); // F after F♯ in the bar
    expect(notes[2].getElement('accidental')?.innerText, 'sharp');
    expect(xml.toXmlString(), isNot(contains('cxe'))); // the editor's ids stay its own
    expect(xml.findAllElements('barline').length, 1); // the final barline kept

    // A click on a note's head finds it.
    final chunk = await EditChunk.engrave(score, 0, score.measureCount);
    final galley = EditGalley([chunk]);
    final id = bar1[2].ids.single;
    final bounds = galley.boundsOf(id)!;
    expect(galley.hitTest(bounds.center), id);
    expect(galley.timeAtX(galley.xOf(0, Frac(3, 2))!), (measure: 0, time: Frac(3, 2)));
    chunk.dispose();

    // Pitches and rhythms change; Undo takes each back.
    score.transpose([id], steps: 1);
    expect(score.locate(id)!.pitches.single, const Pitch(4, 5)); // G5: the key's, no sharp
    score.setRhythm([bar1.first.ids.single], NoteType.half);
    expect(score.eventsIn(0, 0, voice).first.length, Frac(2));
    score.undo();
    score.undo();
    expect(score.locate(id)!.pitches.single, fSharp);
    while (score.canUndo) {
      score.undo();
    }
    expect(score.eventsIn(0, 0, voice).single.isRest, isTrue);
  });

  test('Undo and Redo put back the bars a step changed, and only what is in the score has an id', () {
    final score = EditableScore.parse(demoScore());
    // (The space between bars aside: a part whose bars were counted again is written without.)
    String written() => score.toMusicXML().replaceAll(RegExp(r'>\s+<'), '><');
    final states = [written()];
    final voice = score.voicesIn(0, 2).first;
    final at = ScorePosition(0, voice, 2, Frac.zero);
    score.input(at, [InputItem(const Rhythm(NoteType.quarter), [const Pitch(0, 5)])]);
    states.add(written());
    score.addDynamic(at, 'mf');
    states.add(written());
    score.addBars(3, 2); // the bars' number changes: every bar after is put back
    states.add(written());
    score.setKey(1, KeySig.parse('A')!);
    states.add(written());
    score.deleteBars(0, 1);
    states.add(written());
    for (var i = states.length - 2; i >= 0; i--) {
      score.undo();
      expect(written(), states[i], reason: 'undone to state $i');
    }
    expect(score.canUndo, isFalse);
    // A step of one bar says one bar changed.
    score.takeChanged();
    score.redo();
    final changed = score.takeChanged();
    expect(changed.bars, {2});
    expect(changed.from, isNull);
    for (var i = 2; i < states.length; i++) {
      score.redo();
      expect(written(), states[i], reason: 'redone to state $i');
    }
    expect(score.canRedo, isFalse);

    // A dynamic deleted is nothing in the score; undone, it is again.
    final flute = EditableScore.parse(_flute);
    final start = ScorePosition(0, const VoiceKey(1, '1'), 0, Frac.zero);
    flute.addDynamic(start, 'p');
    final id = RegExp(r'<direction[^>]* id="(cxe\d+)"').firstMatch(flute.chunk(0, 2).xml)!.group(1)!;
    expect(flute.has(id), isTrue);
    flute.delete([id]);
    expect(flute.has(id), isFalse);
    flute.undo();
    expect(flute.has(id), isTrue);
    flute.undo();
    expect(flute.has(id), isFalse);
  });

  test('the score editor changes keys, time signatures and bars in every part of the demo', () async {
    final score = EditableScore.parse(demoScore());
    final bars = score.measureCount;
    score.addBars(4, 2);
    expect(score.measureCount, bars + 2);
    expect(score.barNumber(5), '6');
    score.deleteBars(4, 2);
    expect(score.measureCount, bars);
    score.setKey(8, KeySig.parse('D')!);
    final clarinet = score.parts.indexWhere((p) => p.name.contains('B Flat'));
    expect(score.keyAt(clarinet, 8, Frac.zero).fifths, 4); // E major, written for B♭
    expect(score.keyAt(0, 8, Frac.zero).fifths, 2);
    score.setTime(10, TimeSig.parse('3/4')!);
    expect(score.barLength(10), Frac(3));
    expect(score.setBarline(12, ':|'), isTrue);
    score.toggleMark([score.eventsIn(0, 2, score.voicesIn(0, 2).first).first.ids.first], 'fermata');
    // Bars 8–16 engrave on their own.
    final chunk = await EditChunk.engrave(score, 8, 16);
    expect(chunk.data.measures.length, 8);
    expect(chunk.data.staves.length, greaterThanOrEqualTo(score.parts.length));
    chunk.dispose();
    // A chunk after the first carries on the one before: the clefs and keys Verovio starts
    // it with are cut off, all but a change the bar makes (bass clef at bar 25, top staff).
    score.setClef(ScorePosition(0, score.defaultVoice(0, 1, 24), 24, Frac.zero), Clef.named('bass')!);
    for (final from in [16, 24]) {
      final c = await EditChunk.engrave(score, from, from + 8);
      final start = c.data.measures.first.left;
      final shown = [
        for (final s in c.data.signatures)
          if (s.x < start && !c.hides(s.commandStart)) s,
      ];
      if (from == 16) {
        expect(shown, isEmpty);
        expect(c.left, start);
      } else {
        expect([for (final s in shown) (s.runtimeType, s.staff)], [(ClefSignature, 1)]);
        expect(c.left, lessThan(shown.single.x));
      }
      c.dispose();
    }
    score.undo();
    // And what was written reads as a score again.
    final again = EditableScore.parse(score.toMusicXML());
    expect(again.measureCount, bars);
    expect(again.barLength(10), Frac(3));
  });
}
