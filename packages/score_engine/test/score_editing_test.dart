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

/// A flute, [bars] empty bars of 4/4.
String _fluteOf(int bars) => _flute.replaceFirst(
    RegExp(r'<measure number="2">.*</measure>'),
    [for (var i = 2; i <= bars; i++) '<measure number="$i"><note><rest measure="yes"/><duration>4</duration><voice>1</voice></note></measure>'].join());

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

    // The last bar filled, the caret is past it: everything asked of that place answers, and a
    // note typed there adds the bar it goes in. Undone, the bar is gone again.
    final end = score.input(at, [InputItem(const Rhythm(NoteType.half, dots: 1), [d5])]);
    expect(end, ScorePosition(0, voice, 2, Frac.zero));
    expect(score.measureCount, 2);
    expect(score.barLength(2), Frac(4));
    expect(score.describe(2, Frac.zero), '3.1');
    expect(score.keyAt(0, 2, Frac.zero).fifths, 0);
    expect(score.pitchBefore(end), d5);
    expect(score.eventBefore(end)!.pitches.single, d5);
    expect(score.eventAt(0, 1, 2, Frac.zero), isNull);
    expect(score.eventsIn(0, 2, voice), isEmpty);
    expect(score.defaultVoice(0, 1, 2), voice);
    expect(score.input(end, [InputItem(const Rhythm(NoteType.quarter), [c5])]), ScorePosition(0, voice, 2, Frac.one));
    expect(score.measureCount, 3);
    expect(score.barNumber(2), '3');
    score.undo();
    expect(score.measureCount, 2);
    score.undo();
    at = ScorePosition(0, voice, 1, Frac.one);

    final xml = XmlDocument.parse(score.toMusicXML());
    final notes = xml.findAllElements('note').toList();
    expect(xml.findAllElements('beam').length, 2); // the two eighths, beamed
    expect(notes[3].getElement('accidental')?.innerText, 'natural'); // F after F♯ in the bar
    expect(notes[2].getElement('accidental')?.innerText, 'sharp');
    expect(xml.toXmlString(), isNot(contains('cxe'))); // the editor's ids stay its own
    expect(xml.findAllElements('barline').length, 1); // the final barline kept

    // A click on a note's head finds it, and one on a dynamic the dynamic.
    score.addDynamic(start, 'mf');
    final chunk = await EditChunk.engrave(score, 0, score.measureCount);
    final galley = EditGalley([chunk]);
    final id = bar1[2].ids.single;
    final bounds = galley.boundsOf(id)!;
    expect(galley.hitTest(bounds.center), id);
    final dynamic = RegExp(r'<dynamics id="(cxe\d+)"').firstMatch(score.chunk(0, 1).xml)!.group(1)!;
    expect(galley.hitTest(galley.boundsOf(dynamic)!.center), dynamic);
    expect(galley.timeAtX(galley.xOf(0, Frac(3, 2))!), (measure: 0, time: Frac(3, 2)));
    chunk.dispose();

    // The same sound spelled as the note above, and back: F♯ is G♭, and its accidental follows.
    score.respell([id], up: true);
    expect(score.locate(id)!.pitches.single, const Pitch(4, 5, -1));
    expect(XmlDocument.parse(score.toMusicXML()).findAllElements('note').elementAt(2).getElement('accidental')?.innerText, 'flat');
    score.respell([id], up: false);
    expect(score.locate(id)!.pitches.single, fSharp);
    score.respell([id], up: false);
    expect(score.locate(id)!.pitches.single, const Pitch(2, 5, 2)); // E double sharp
    score.respell([id], up: false);
    expect(score.locate(id)!.pitches.single, const Pitch(2, 5, 2)); // no further: D would take three sharps
    score.undo();
    score.undo();
    score.undo();
    expect(score.locate(id)!.pitches.single, fSharp);

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
    // What is in force in a bar, and where a note is, follow the bars before it.
    final key = score.keyAt(0, 6, Frac.zero).fifths;
    final later = score.eventsIn(0, 5, score.voicesIn(0, 5).first).first.ids.first;
    expect(score.whereIs(later)!.measure, 5);
    score.addBars(3, 2); // the bars' number changes: every bar after is put back
    states.add(written());
    expect(score.whereIs(later)!.measure, 7);
    score.setKey(1, KeySig.parse('A')!);
    states.add(written());
    expect(score.keyAt(0, 8, Frac.zero).fifths, 3);
    expect(score.keyAt(0, 0, Frac.zero).fifths, key);
    score.deleteBars(0, 1);
    states.add(written());
    for (var i = states.length - 2; i >= 0; i--) {
      score.undo();
      expect(written(), states[i], reason: 'undone to state $i');
    }
    expect(score.canUndo, isFalse);
    expect(score.keyAt(0, 6, Frac.zero).fifths, key);
    expect(score.whereIs(later)!.measure, 5);
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

    // A triplet needs finer divisions in every bar of its part: only its own bar is engraved again.
    score.takeChanged();
    score.input(at, [InputItem(const Rhythm(NoteType.eighth, tuplet: Tuplet(7, 4, NoteType.eighth)), [const Pitch(0, 5)])]);
    expect(score.takeChanged().bars, {2});
    expect(EditableScore.parse(score.toMusicXML()).eventsIn(0, 2, voice).first.length, Frac(2, 7));

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

  test('chunks side by side draw what one engraving of the whole score does, each thing once', () async {
    final score = EditableScore.parse(_fluteOf(12));
    const voice = VoiceKey(1, '1');
    var at = ScorePosition(0, voice, 0, Frac.zero);
    for (var i = 0; i < 24; i++) {
      at = score.input(at, [InputItem(const Rhythm(NoteType.half), [Pitch(i % 7, 4)])]);
    }
    List<String> idsIn(int m) => [for (final e in score.eventsIn(0, m, voice)) e.ids.first];
    // Across the barline between bars 4 and 5, where chunks of two and of four bars both meet:
    // a tie, a slur, a hairpin, a clef and a key and a time signature that change, a repeat
    // that ends and one that starts; and a slur over bars 1 to 4, longer than a chunk of two.
    score.input(ScorePosition(0, voice, 3, Frac(3)), [InputItem(const Rhythm(NoteType.half), [const Pitch(4, 4)])]);
    score.toggleSlur([idsIn(3)[1], idsIn(4).last]);
    score.addHairpin(ScorePosition(0, voice, 3, Frac.one), ScorePosition(0, voice, 4, Frac(3)), crescendo: true);
    score.setClef(ScorePosition(0, voice, 4, Frac.zero), Clef.named('alto')!);
    score.setKey(4, KeySig.parse('Eb')!);
    score.setTime(4, TimeSig.parse('3/4')!);
    score.setBarline(3, ':|:');
    score.toggleSlur([idsIn(0).first, idsIn(3).first]);
    final slur = RegExp(r'<slur[^>]*type="start"[^>]* id="(cxe\d+)"|<slur[^>]* id="(cxe\d+)"[^>]*type="start"').allMatches(score.chunk(3, 4).xml).map((m) => m.group(1) ?? m.group(2)!).first;

    int drawn(EditChunk c) => [...c.list.staves, c.list.barlines].fold(0, (n, layer) => n + layer.items.where(c.owns).length);
    final whole = await EditChunk.engrave(score, 0, 12);
    expect((whole.lead, whole.trail), (0, 0));
    for (final bars in [2, 4]) {
      final chunks = [for (var from = 0; from < 12; from += bars) await EditChunk.engrave(score, from, from + bars)];
      expect(chunks.fold(0, (n, c) => n + drawn(c)), drawn(whole), reason: 'chunks of $bars bars');
      // The first of two bars is engraved with a third, where its slur ends.
      expect(chunks.first.trail, bars == 2 ? 2 : 1);
      // The slur over the barline is the chunk's it starts in, whole, and found on either side.
      final galley = EditGalley(chunks, bars: bars);
      final before = chunks[4 ~/ bars - 1], after = chunks[4 ~/ bars];
      expect(before.outlines[slur], isNotNull);
      expect(after.outlines[slur], isNull);
      final seam = galley.barOf(4)!.left, bounds = galley.boundsOf(slur)!;
      expect(bounds.left, lessThan(seam));
      expect(bounds.right, greaterThan(seam));
      expect(before.spill, greaterThan(0));
      // Bars are where they are in the whole score, to a hair.
      final one = EditGalley([whole]);
      for (var m = 0; m < 12; m++) {
        expect(galley.barOf(m)!.right - galley.barOf(m)!.left, closeTo(one.barOf(m)!.right - one.barOf(m)!.left, 1), reason: 'bar $m, chunks of $bars');
        expect(galley.barOf(m)!.left, closeTo(one.barOf(m)!.left, 20), reason: 'bar $m, chunks of $bars');
      }
      expect(galley.timeAtX(galley.xOf(5, Frac(2))!), (measure: 5, time: Frac(2)));
      for (final c in chunks) {
        c.dispose();
      }
    }
    whole.dispose();
    expect([for (final staves in [1, 2, 4, 5, 8, 12, 21, 60]) EditChunk.barsFor(staves)], [6, 6, 6, 4, 3, 2, 2, 2]);
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
    // Bars 8–16 engrave with the bar before them and the one after, and say where their own are.
    final chunk = await EditChunk.engrave(score, 8, 16);
    expect((chunk.lead, chunk.trail), (1, 1));
    expect(chunk.data.measures.length, 10);
    expect(chunk.data.staves.length, greaterThanOrEqualTo(score.parts.length));
    expect(chunk.left, chunk.data.measures.first.right);
    expect(chunk.right, chunk.data.measures[8].right);
    expect(chunk.measure(8), same(chunk.data.measures[1]));
    expect(chunk.measure(16), isNull);
    chunk.dispose();
    score.undo();
    // And what was written reads as a score again.
    final again = EditableScore.parse(score.toMusicXML());
    expect(again.measureCount, bars);
    expect(again.barLength(10), Frac(3));
  });
}
