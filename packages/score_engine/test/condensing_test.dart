import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';
import 'package:score_engine/src/score_renderer.dart' show StaffPlacement;
import 'package:xml/xml.dart';

import 'demo_score.dart';

/// Two flutes in 3/4, a bar of each kind: Flute 1 alone, both the same, the same rhythm a
/// third apart, different rhythms, both resting, Flute 2 alone. Flute 2 counts in halves of
/// Flute 1's divisions, and slurs across bars 3–4 (a chord bar, then two voices). Flute 1
/// plays dolce, and the two play different dynamics in bar 4.
String twoFlutes() {
  String note(String step, int octave, int duration, String type, {String extra = ''}) =>
      '<note><pitch><step>$step</step><octave>$octave</octave></pitch><duration>$duration</duration>'
      '<voice>1</voice><type>$type</type><stem>up</stem>$extra</note>';
  String dynamic(String mark) => '<direction><direction-type><dynamics><$mark/></dynamics></direction-type></direction>';
  String rest(int duration) => '<note><rest measure="yes"/><duration>$duration</duration><voice>1</voice></note>';
  String part(String id, int divisions, List<String> bars) => '<part id="$id">${[
        for (final (i, bar) in bars.indexed)
          '<measure number="${i + 1}">'
              '${i == 0 ? '<attributes><divisions>$divisions</divisions><key><fifths>0</fifths></key>'
                  '<time><beats>3</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>' : ''}'
              '$bar</measure>',
      ].join()}</part>';
  const q = 1, h = 2; // a crotchet in Flute 1's divisions, and in Flute 2's
  return '''<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="4.0"><part-list>
<score-part id="P1"><part-name>Flute 1</part-name><part-abbreviation>Fl. 1</part-abbreviation></score-part>
<score-part id="P2"><part-name>Flute 2</part-name><part-abbreviation>Fl. 2</part-abbreviation></score-part>
<score-part id="P3"><part-name>Violin I</part-name></score-part>
<score-part id="P4"><part-name>Violin II</part-name></score-part>
</part-list>
${part('P1', q, [
        '<direction><direction-type><words>dolce</words></direction-type></direction>${note('C', 5, 3 * q, 'half', extra: '<dot/>')}',
        note('E', 5, q, 'quarter') * 3,
        note('G', 5, q, 'quarter', extra: '<notations><slur type="start"/></notations>') + note('G', 5, q, 'quarter') * 2,
        '${dynamic('p')}${note('A', 5, 3 * q, 'half', extra: '<dot/><notations><slur type="stop"/></notations>')}',
        rest(3 * q),
        rest(3 * q),
      ])}
${part('P2', h, [
        rest(3 * h),
        note('E', 5, h, 'quarter') * 3,
        note('E', 5, h, 'quarter', extra: '<notations><slur type="start"/></notations>') + note('E', 5, h, 'quarter') * 2,
        dynamic('mf') + note('F', 5, h, 'quarter') * 2 + note('F', 5, h, 'quarter', extra: '<notations><slur type="stop"/></notations>'),
        rest(3 * h),
        note('D', 5, 3 * h, 'half', extra: '<dot/>'),
      ])}
${part('P3', q, List.filled(6, note('C', 4, 3 * q, 'half', extra: '<dot/>')))}
${part('P4', q, List.filled(6, note('C', 4, 3 * q, 'half', extra: '<dot/>')))}
</score-partwise>''';
}

/// A flute (C, no sharps), a clarinet in B♭ (written a tone above sounding), a violin that
/// plays in two voices, and an oboe written in D major, in 3/4. The flute and the oboe:
///  1. both play C (the oboe's with a natural);
///  2. the oboe alone: F♯ (in its key) and C♮;
///  3. the flute's F♯s against the oboe's (in its key), in other rhythms.
String flutesAndClarinet() {
  String note(String step, int octave, int duration, String type, {int alter = 0, String accidental = '', int voice = 1, String extra = ''}) =>
      '<note><pitch><step>$step</step>${alter == 0 ? '' : '<alter>$alter</alter>'}<octave>$octave</octave></pitch>'
      '<duration>$duration</duration><voice>$voice</voice><type>$type</type>'
      '${accidental.isEmpty ? '' : '<accidental>$accidental</accidental>'}$extra</note>';
  String rest(int duration) => '<note><rest measure="yes"/><duration>$duration</duration><voice>1</voice></note>';
  String part(String id, String attributes, List<String> bars) => '<part id="$id">${[
        for (final (i, bar) in bars.indexed)
          '<measure number="${i + 1}">${i == 0 ? '<attributes><divisions>1</divisions>$attributes'
              '<time><beats>3</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>' : ''}'
              '$bar</measure>',
      ].join()}</part>';
  return '''<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="4.0"><part-list>
<score-part id="P1"><part-name>Flute</part-name><part-abbreviation>Fl.</part-abbreviation></score-part>
<score-part id="P2"><part-name>Clarinet in B♭</part-name><part-abbreviation>Cl.</part-abbreviation></score-part>
<score-part id="P3"><part-name>Violin</part-name><part-abbreviation>Vn.</part-abbreviation></score-part>
<score-part id="P4"><part-name>Oboe</part-name><part-abbreviation>Ob.</part-abbreviation></score-part>
</part-list>
${part('P1', '<key><fifths>0</fifths></key>', [
        note('C', 5, 3, 'half', extra: '<dot/>'),
        rest(3),
        note('F', 5, 1, 'quarter', alter: 1, accidental: 'sharp') + note('F', 5, 1, 'quarter', alter: 1) * 2,
      ])}
${part('P2', '<key><fifths>2</fifths></key><transpose><diatonic>-1</diatonic><chromatic>-2</chromatic></transpose>', [
        note('D', 5, 3, 'half', extra: '<dot/>'),
        rest(3),
        rest(3),
      ])}
${part('P3', '<key><fifths>0</fifths></key>', [
        '${note('C', 5, 3, 'half', extra: '<dot/>')}<backup><duration>3</duration></backup>${note('E', 4, 3, 'half', voice: 2, extra: '<dot/>')}',
        rest(3),
        rest(3),
      ])}
${part('P4', '<key><fifths>2</fifths></key>', [
        note('C', 5, 3, 'half', accidental: 'natural', extra: '<dot/>'),
        note('F', 5, 2, 'half', alter: 1) + note('C', 5, 1, 'quarter', accidental: 'natural'),
        note('F', 5, 3, 'half', alter: 1, extra: '<dot/>'),
      ])}
</score-partwise>''';
}

({XmlDocument doc, List<CondensedGroup> groups}) condense(String musicXML, {List<PlayerPair> pairs = const []}) {
  final doc = ScoreMetadata.parse(musicXML);
  final groups = Condenser.condense(doc, ScoreMetadata.fromDocument(doc), custom: pairs);
  return (doc: doc, groups: groups);
}

List<XmlElement> sharedBars(XmlDocument doc, String id) =>
    doc.rootElement.findElements('part').firstWhere((p) => p.getAttribute('id') == id).findElements('measure').toList();

/// The player labels in a bar: "1.", "2.", "a2".
List<String> labels(XmlElement bar) =>
    [for (final w in bar.findAllElements('words')) if (const {'1.', '2.', 'a2'}.contains(w.innerText)) w.innerText];
Set<String> voices(XmlElement bar) => {for (final v in bar.findElements('note').expand((n) => n.findElements('voice'))) v.innerText};

Future<void> _font(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final path in paths) {
    loader.addFont(Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
  }
  await loader.load();
}

void main() {
  test('numbered players of one instrument pair up; sections do not', () {
    final (:doc, :groups) = condense(twoFlutes());
    expect(groups, [const CondensedGroup(id: 'cond-P1-P2', partIds: ['P1', 'P2'], staffNumber: 5)]);
    final added = doc.findAllElements('score-part').last;
    expect(added.getAttribute('id'), 'cond-P1-P2');
    expect(added.getElement('part-name')!.innerText, 'Flute 1.2');
    expect(added.getElement('part-abbreviation')!.innerText, 'Fl. 1.2');
  });

  test('each bar is written the simplest way that shows both players', () {
    final bars = sharedBars(condense(twoFlutes()).doc, 'cond-P1-P2');
    expect(bars, hasLength(6));

    // Flute 1 alone: its notes, marked "1.".
    expect(labels(bars[0]), ['1.']);
    expect(bars[0].findAllElements('step').map((s) => s.innerText), ['C']);
    // The same notes: once, marked "a2".
    expect(labels(bars[1]), ['a2']);
    expect(bars[1].findElements('note'), hasLength(3));
    // The same rhythm a third apart: one voice of chords, stems left to Verovio.
    expect(labels(bars[2]), isEmpty);
    expect(bars[2].findElements('note').where((n) => n.getElement('chord') != null), hasLength(3));
    expect(voices(bars[2]), {'1'});
    expect(bars[2].findAllElements('stem'), isEmpty);
    // Different rhythms: two voices, Flute 1's stems up and Flute 2's down, after a backup
    // written in the shared divisions (a crotchet is 1 in Flute 1, 2 in Flute 2: 2 in both).
    expect(voices(bars[3]), {'1', '2'});
    expect(bars[3].findElements('backup').single.getElement('duration')!.innerText, '6');
    final stems = {for (final n in bars[3].findElements('note')) n.getElement('voice')!.innerText: n.getElement('stem')!.innerText};
    expect(stems, {'1': 'up', '2': 'down'});
    // Their dynamics differ: Flute 1's above the staff, Flute 2's below.
    expect({for (final d in bars[3].findElements('direction')) d.findAllElements('dynamics').single.firstElementChild!.name.local: d.getAttribute('placement')},
        {'p': 'above', 'mf': 'below'});
    // Both rest; then Flute 2 alone, marked "2." and moved to voice 1.
    expect(bars[4].findElements('note').every((n) => n.getElement('rest') != null), isTrue);
    expect(labels(bars[5]), ['2.']);
    expect(voices(bars[5]), {'1'});
    expect(bars[5].findAllElements('duration').map((d) => d.innerText), ['6']);
  });

  test('a slur keeps both ends or neither', () {
    final bars = sharedBars(condense(twoFlutes()).doc, 'cond-P1-P2');
    // Flute 1's slur (bar 3 → 4) is whole; Flute 2's starts in a chord bar, where its
    // markings are left out, so its stop in bar 4 goes too.
    final slurs = [for (final bar in bars) ...bar.findAllElements('slur')];
    expect(slurs.map((s) => s.getAttribute('type')), ['start', 'stop']);
    expect(slurs.map((s) => s.getAttribute('number')).toSet(), {null});
    expect(bars.expand((b) => b.descendantElements).where((e) => e.getAttribute('cs-pair') != null), isEmpty);
  });

  test("a text on a shared staff leads back to the player's own", () async {
    final score = await LoadedScore.load(twoFlutes());
    final dolce = score.texts.single;
    expect(score.texts.map((t) => t.partId), ['P1']); // listed once, as Flute 1's
    expect(score.engraving.sourceIds, containsAll([dolce.id, '${Condenser.idPrefix}${dolce.id}']));
    expect(Condenser.sourceTextId('${Condenser.idPrefix}${dolce.id}'), dolce.id);
  });

  test('who can share a staff: the same clefs, transposition and meters, read for what they mean', () {
    const g2 = '<clef><sign>G</sign><line>2</line></clef>';
    String note(int d) => '<note><pitch><step>C</step><octave>5</octave></pitch><duration>$d</duration><voice>1</voice></note>';
    // Two bars of 3/4. [first] opens bar 1 (after divisions and time), [inBar] comes before
    // bar 1's last crotchet (or wherever [at] crotchets in), [second] opens bar 2.
    String part(String id, {int divisions = 1, String first = g2, String second = '', String? inBar, int at = 2}) {
      final q = divisions;
      final bar1 = inBar == null ? note(3 * q) : '${note(at * q)}<attributes>$inBar</attributes>${note((3 - at) * q)}';
      return '<part id="$id"><measure number="1"><attributes><divisions>$divisions</divisions>'
          '<time><beats>3</beats><beat-type>4</beat-type></time>$first</attributes>$bar1</measure>'
          '<measure number="2">${second.isEmpty ? '' : '<attributes>$second</attributes>'}${note(3 * q)}</measure></part>';
    }

    final parts = {
      'plain': part('plain'),
      'noLine': part('noLine', first: '<clef><sign>G</sign></clef>', divisions: 4), // G's line is 2
      'courtesy': part('courtesy', second: g2), // restated: no change
      'viola': part('viola', first: '<clef><sign>C</sign><line>3</line></clef>'),
      'tenor': part('tenor', first: '<clef><sign>G</sign><line>2</line><clef-octave-change>-1</clef-octave-change></clef>'),
      'bassBeat3': part('bassBeat3', inBar: '<clef><sign>F</sign><line>4</line></clef>'),
      'bassBeat3x4': part('bassBeat3x4', divisions: 4, inBar: '<clef><sign>F</sign><line>4</line></clef>'), // the same point
      'bassBeat2': part('bassBeat2', inBar: '<clef><sign>F</sign><line>4</line></clef>', at: 1),
      'clarinet': part('clarinet', first: '$g2<transpose><diatonic>-1</diatonic><chromatic>-2</chromatic></transpose>'),
      'bassOctave': part('bassOctave', first: '$g2<transpose><chromatic>0</chromatic><octave-change>-1</octave-change></transpose>'),
      'bassSteps': part('bassSteps', first: '$g2<transpose><diatonic>-7</diatonic><chromatic>-12</chromatic></transpose>'),
      'doubled': part('doubled', first: '$g2<transpose><chromatic>0</chromatic><double/></transpose>'),
      'untransposed': part('untransposed', second: '<transpose><chromatic>0</chromatic></transpose>'), // says none
      'from2': part('from2', second: '<transpose><diatonic>-1</diatonic><chromatic>-2</chromatic></transpose>'),
    };
    final doc = ScoreMetadata.parse('''<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="4.0"><part-list>${[for (final id in parts.keys) '<score-part id="$id"><part-name>$id</part-name></score-part>'].join()}</part-list>
${parts.values.join()}</score-partwise>''');
    final partners = Condenser.options(doc, ScoreMetadata.fromDocument(doc)).partners;
    expect(partners['plain'], {'noLine', 'courtesy', 'untransposed'});
    expect(partners['bassBeat3'], {'bassBeat3x4'}, reason: 'a clef change at the same point, in other divisions');
    expect(partners['bassOctave'], {'bassSteps'}, reason: 'an octave down, written two ways');
    for (final alone in ['viola', 'tenor', 'bassBeat2', 'clarinet', 'doubled', 'from2']) {
      expect(partners[alone], isEmpty, reason: alone);
    }
  });

  group('any two instruments', () {
    List<({String step, String? alter, String octave, String? accidental})> pitches(XmlElement bar) => [
          for (final n in bar.findElements('note'))
            if (n.getElement('pitch') case final p?)
              (
                step: p.getElement('step')!.innerText,
                alter: p.getElement('alter')?.innerText,
                octave: p.getElement('octave')!.innerText,
                accidental: n.getElement('accidental')?.innerText,
              ),
        ];

    test('instruments in different transpositions never share a staff', () {
      final doc = ScoreMetadata.parse(flutesAndClarinet());
      final options = Condenser.options(doc, ScoreMetadata.fromDocument(doc));
      expect(options.partners['P1'], {'P3', 'P4'});
      expect(options.partners['P2'], isEmpty, reason: 'the clarinet in B♭');
      expect(options.pair('P1', 'P2'), isNull);
      expect(condense(flutesAndClarinet(), pairs: const [PlayerPair('P1', 'P2')]).groups, isEmpty);
    });

    test('a flute and an oboe written in another key: one staff in the flute\'s key', () {
      final (:doc, :groups) = condense(flutesAndClarinet(), pairs: const [PlayerPair('P1', 'P4')]);
      expect(groups.single.id, 'cond-P1-P4');
      final bars = sharedBars(doc, 'cond-P1-P4');
      // The same notes: once, "a2", in the flute's key.
      expect(labels(bars[0]), ['a2']);
      expect(pitches(bars[0]), [(step: 'C', alter: null, octave: '5', accidental: null)]);
      expect(bars[0].findAllElements('fifths').single.innerText, '0');
      // The oboe alone, by its short name, spelled for C major: the F♯ needs its sharp, the C nothing.
      expect(bars[1].findAllElements('words').map((w) => w.innerText), ['Ob.']);
      expect(pitches(bars[1]), [
        (step: 'F', alter: '1', octave: '5', accidental: 'sharp'),
        (step: 'C', alter: null, octave: '5', accidental: null),
      ]);
      // Two voices, one staff: the F♯ is marked where it starts (on both noteheads), not again.
      expect(voices(bars[2]), {'1', '2'});
      expect(pitches(bars[2]).map((p) => (p.step, p.alter, p.accidental)), [
        ('F', '1', 'sharp'), ('F', '1', null), ('F', '1', null), // the flute
        ('F', '1', 'sharp'), // the oboe
      ]);
    });

    test('a player in two voices keeps them, numbered apart from the other player\'s', () {
      final (:doc, :groups) = condense(flutesAndClarinet(), pairs: const [PlayerPair('P1', 'P3')]);
      final bar = sharedBars(doc, groups.single.id).first;
      expect(voices(bar), {'1', '5', '6'});
      final length = <String, int>{};
      for (final note in bar.findElements('note')) {
        final voice = note.getElement('voice')!.innerText;
        length[voice] = (length[voice] ?? 0) + int.parse(note.getElement('duration')!.innerText);
      }
      expect(length.values.toSet(), {3});
    });
  });

  test('names', () {
    expect(CondensedGroup.nameFor('Horn in F 3', 'Horn in F 4'), 'Horn in F 3.4');
    expect(CondensedGroup.nameFor('Flute 1', 'Oboe 1'), 'Flute 1 + Oboe 1');
    expect(CondensedGroup.arePlayers('Violin I', 'Violin II'), isFalse);
    expect(CondensedGroup.arePlayers('Clarinet in B♭ 1', 'Clarinet in B♭ 2'), isTrue);
    expect(Condenser.sourceTextId('cond-cs-dir-4-reh'), 'cs-dir-4-reh');
  });

  group('the demo', () {
    late LoadedScore score;

    // Built-in pairs, and unlikely ones: flute and violin, clarinet and trumpet, bassoon and
    // cello, bassoon and timpani.
    const unlikely = [PlayerPair('P2', 'P17'), PlayerPair('P6', 'P12'), PlayerPair('P8', 'P20'), PlayerPair('P9', 'P14')];
    setUpAll(() async {
      await _font('packages/score_engine/Bravura', ['assets/fonts/Bravura.otf']);
      final academico = Directory('assets/fonts').listSync().whereType<File>().where((f) => f.path.contains('Academico'));
      await _font('packages/score_engine/Academico', [for (final f in academico) f.path]);
      score = await LoadedScore.load(demoScore());
    });

    test('winds and brass pair up, engraved after the 21 staves', () {
      expect([for (final g in score.condensed) g.partIds], [
        for (var p = 2; p <= 12; p += 2) ['P$p', 'P${p + 1}'],
      ]);
      expect(score.condensed.map((g) => g.staffNumber), [22, 23, 24, 25, 26, 27]);
      expect(score.engraving.staves.map((s) => s.n), List.generate(27, (i) => i + 1));
      expect(score.engraving.measures, hasLength(44)); // the bars are unchanged
    });

    test('who can share a staff: the same clefs, keys and transposition, one staff and voice', () {
      final doc = ScoreMetadata.parse(demoScore());
      final options = Condenser.options(doc, ScoreMetadata.fromDocument(doc));
      expect(options.builtIn.map((p) => p.id), [for (var p = 2; p <= 12; p += 2) 'cond-P$p-P${p + 1}']);
      // Any two single-staff instruments in the same clefs and transposition: a flute with a
      // violin, a bassoon with the cello or the timpani; B♭ clarinets with B♭ trumpets; horns
      // in F only with each other; the viola (alto clef), the piccolo and the double bass (an
      // octave from written) with nothing here.
      expect(options.partners['P2'], {'P3', 'P4', 'P5', 'P17', 'P18'});
      expect(options.partners['P8'], containsAll(['P9', 'P14', 'P20']));
      expect(options.partners['P6'], {'P7', 'P12', 'P13'});
      expect(options.partners['P10'], {'P11'});
      expect(options.partners['P1'], isEmpty);
      expect(options.partners['P19'], isEmpty);
      expect(options.partners['P21'], isEmpty);
      expect(options.partners['P16'], isEmpty, reason: 'unpitched percussion: only with its like');
      expect(options.partners['P2'], isNot(contains('P16')));
      expect(options.pair('P4', 'P2'), const PlayerPair('P2', 'P4'), reason: 'in score order');
      expect(options.pair('P2', 'P2'), isNull);

      // The user's pairs come first; a built-in pair loses a player to them and goes.
      final pairs = options.pairs(const [PlayerPair('P2', 'P4'), PlayerPair('P3', 'P5'), PlayerPair('P4', 'P5')]);
      expect(pairs.map((p) => p.id), ['cond-P2-P4', 'cond-P3-P5', 'cond-P6-P7', 'cond-P8-P9', 'cond-P10-P11', 'cond-P12-P13']);
    });

    test("the user's pairs are engraved like the built-in ones", () async {
      final custom = await score.withEdits(pairs: const [PlayerPair('P4', 'P2')]);
      expect(custom.pairs, const [PlayerPair('P4', 'P2')]);
      expect(custom.condensed.map((g) => g.id), ['cond-P2-P4', for (var p = 6; p <= 12; p += 2) 'cond-P$p-P${p + 1}']);
      expect(custom.condensed.first.staffNumber, 22);
      expect(custom.engraving.staves, hasLength(26));
      expect(custom.engraving.measures, hasLength(44));
      expect((await custom.withTextEdits(const {})).pairs, custom.pairs, reason: 'text edits keep them');

      final odd = await score.withEdits(pairs: unlikely);
      expect(odd.condensed.map((g) => g.id), containsAll(unlikely.map((p) => p.id)));
      expect(odd.engraving.measures, hasLength(44));
    });

    test('every shared bar is as long as the bar, in each voice', () {
      final doc = ScoreMetadata.parse(demoScore());
      final groups = Condenser.condense(doc, ScoreMetadata.fromDocument(doc), custom: unlikely);
      expect(groups.map((g) => g.id), containsAll(unlikely.map((p) => p.id)));
      for (final g in groups) {
        for (final (i, bar) in sharedBars(doc, g.id).indexed) {
          final length = <String, int>{};
          for (final note in bar.findElements('note')) {
            if (note.getElement('chord') != null || note.getElement('grace') != null) continue;
            final voice = note.getElement('voice')!.innerText;
            length[voice] = (length[voice] ?? 0) + int.parse(note.getElement('duration')!.innerText);
          }
          expect(length.values.toSet(), {36}, reason: '${g.id} bar ${i + 1}'); // 6/8 in 12ths of a crotchet
        }
      }
    });

    test('the shared staff shows while both flutes do, and swaps with Flute 1 in place', () {
      final scene = CuratedScene(score)..condensed = {'cond-P2-P3'};
      const size = ui.Size(1600, 900);
      final starts = score.timeline.measureStarts;
      final curation = Curation(score.metadata.parts.map((p) => p.id))..transition = 0.4;
      curation.setLane('P2', [Region(0, starts.last)]);
      curation.setLane('P3', [Region(starts[10], starts.last)]); // Flute 2 joins at bar 11
      final join = score.timeline.secondsAtQuarter(starts[10]);
      final shared = score.engraving.staves.indexWhere((s) => s.n == 22);
      final flute1 = score.engraving.staves.indexWhere((s) => s.n == 2);

      Map<int, StaffPlacement> at(double t) => {for (final p in scene.layoutAt(t, curation, size).placements) p.staffIndex: p};
      expect(at(join - 5).keys, [flute1]);
      expect(at(join + 5).keys, [shared]);
      expect(scene.layoutAt(join + 5, curation, size).labels.single.text, 'Flute 1.2');
      // Crossing over: both at once, in the same place, one fading as the other comes.
      final middle = at(join);
      expect(middle.keys.toSet(), {flute1, shared});
      expect(middle[flute1]!.y, closeTo(middle[shared]!.y, 1e-6));

      // Not condensed: the two flutes' own staves, as before.
      scene.condensed = {};
      expect(at(join + 5).keys.toSet(), {flute1, score.engraving.staves.indexWhere((s) => s.n == 3)});
      scene.dispose();
    });


    test('renders (set SNAPSHOT_DIR to save frames)', () async {
      final out = Platform.environment['SNAPSHOT_DIR'];
      if (out == null) return;
      final curation = Curation(score.metadata.parts.map((p) => p.id));
      for (final p in score.metadata.parts.take(13)) {
        curation.setLane(p.id, [Region(0, score.timeline.measureStarts.last)]);
      }
      final scene = CuratedScene(score)..condensed = {for (final g in score.condensed) g.id};
      const size = ui.Size(2400, 1100);
      const dpr = 1.5;
      for (final bar in [3, 9, 17, 25, 33]) {
        final t = score.timeline.secondsAtQuarter(score.timeline.measureStarts[bar - 1]) + 4;
        final recorder = ui.PictureRecorder();
        scene.paint(ui.Canvas(recorder)..scale(dpr), size, time: t, curation: curation, devicePixelRatio: dpr);
        final image = recorder.endRecording().toImageSync((size.width * dpr).round(), (size.height * dpr).round());
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$out/condensed-bar$bar.png').writeAsBytesSync(png!.buffer.asUint8List());
      }
      scene.dispose();
    });
  });

  test('a part with no usable divisions (0, negative) is still read, and still condenses', () async {
    for (final bad in ['0', '-12', '99999999999']) {
      final xml = demoScore().replaceFirst('<divisions>12</divisions>', '<divisions>$bad</divisions>');
      final score = await LoadedScore.load(xml, pairs: const [PlayerPair('P2', 'P3')]);
      expect(score.engraving.measures, hasLength(44), reason: 'divisions $bad');
    }
  });
}
