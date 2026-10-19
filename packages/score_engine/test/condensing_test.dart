import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';
import 'package:xml/xml.dart';

import 'demo_score.dart';

/// Two flutes in 3/4, a bar of each kind: Flute 1 alone, both the same, the same rhythm a
/// third apart, different rhythms, both resting, Flute 2 alone. Flute 2 counts in halves of
/// Flute 1's divisions, and slurs across bars 3–4 (a chord bar, then two voices). Flute 1
/// plays dolce; Flute 2 alone plays mp in bar 2, both f in bar 3, and they differ in bar 4.
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
        dynamic('f') + note('G', 5, q, 'quarter', extra: '<notations><slur type="start"/></notations>') + note('G', 5, q, 'quarter') * 2,
        '${dynamic('p')}${note('A', 5, 3 * q, 'half', extra: '<dot/><notations><slur type="stop"/></notations>')}',
        rest(3 * q),
        rest(3 * q),
      ])}
${part('P2', h, [
        rest(3 * h),
        note('E', 5, h, 'quarter') + dynamic('mp') + note('E', 5, h, 'quarter') * 2,
        dynamic('f') + note('E', 5, h, 'quarter', extra: '<notations><slur type="start"/></notations>') + note('E', 5, h, 'quarter') * 2,
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
  test('each bar is written the simplest way that shows both players', () {
    final bars = sharedBars(condense(twoFlutes()).doc, 'cond-P1-P2');
    expect(bars, hasLength(6));

    // Flute 1 alone: its notes, marked "1.".
    expect(labels(bars[0]), ['1.']);
    expect(bars[0].findAllElements('step').map((s) => s.innerText), ['C']);
    // The same notes: once, marked "a2".
    expect(labels(bars[1]), ['a2']);
    expect(bars[1].findElements('note'), hasLength(3));
    // Flute 2's own dynamic stays, below the staff, before its second note.
    final mp = bars[1].childElements.toList().indexWhere((e) => e.findAllElements('mp').isNotEmpty);
    expect(bars[1].childElements.elementAt(mp).getAttribute('placement'), 'below');
    expect(bars[1].childElements.take(mp).where((e) => e.name.local == 'note'), hasLength(1));
    // The same rhythm a third apart: one voice of chords, stems left to Verovio.
    expect(labels(bars[2]), isEmpty);
    expect(bars[2].findElements('note').where((n) => n.getElement('chord') != null), hasLength(3));
    expect(voices(bars[2]), {'1'});
    expect(bars[2].findAllElements('stem'), isEmpty);
    // The same dynamic in both: once.
    expect(bars[2].findAllElements('f'), hasLength(1));
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

  group('the demo', () {
    late LoadedScore score;

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
  });
}
