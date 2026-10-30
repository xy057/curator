import 'dart:io';

import 'package:archive/archive.dart';
import 'package:score_engine/score_engine.dart';
import 'package:xml/xml.dart';

/// The app's bundled demo project (a .ccs zip); tests run in packages/score_engine/.
final demoProject = File('../../app/assets/demo/WI275 - 01 Intro.ccs');

/// The demo's score, a 44-bar 6/8 orchestral intro for 21 instruments, as MusicXML:
/// transposing clarinets, horns and trumpets, texts ("Vivo", "pizz.", "arco"), no key change.
String demoScore() {
  final archive = ZipDecoder().decodeBytes(demoProject.readAsBytesSync());
  final entry = archive.files.firstWhere((f) => f.isFile && f.name.startsWith('score/'));
  return ScoreFile.decodeMusicXML(entry.content);
}

/// The demo with a key change at bar [bar] (1-based) to concert [concertFifths], written in
/// each part's own key: B♭ instruments two sharps higher, horns in F one. Timpani and snare
/// drum keep none.
String demoScoreWithKeyChange({required int bar, required int concertFifths}) => demoScoreWithKeyChanges({bar: concertFifths});

/// The demo with key changes at each bar (1-based) of [concertFifths], as [demoScoreWithKeyChange].
String demoScoreWithKeyChanges(Map<int, int> concertFifths) {
  final doc = XmlDocument.parse(demoScore());
  final names = {
    for (final p in doc.findAllElements('score-part')) p.getAttribute('id'): p.getElement('part-name')!.innerText,
  };
  for (final part in doc.rootElement.findElements('part')) {
    final name = names[part.getAttribute('id')]!;
    if (name == 'Timpani' || name == 'Snare Drum') continue;
    concertFifths.forEach((bar, fifths) {
      final written = fifths + (name.contains('B Flat') ? 2 : name.contains('Horn') ? 1 : 0);
      final measure = part.findElements('measure').elementAt(bar - 1);
      measure.children.insert(0, XmlDocument.parse('<attributes><key><fifths>$written</fifths></key></attributes>').rootElement.copy());
    });
  }
  return doc.toXmlString();
}

/// A flute and a two-staff piano, two bars; in the second the right hand crosses down to the
/// left hand's staff for a low G (cross-staff).
const flutePianoScore = '''<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="4.0">
  <part-list><score-part id="P1"><part-name>Flute</part-name></score-part><score-part id="P2"><part-name>Piano</part-name></score-part></part-list>
  <part id="P1">
    <measure number="1"><attributes><divisions>2</divisions><key><fifths>0</fifths></key><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>
      <note><pitch><step>C</step><octave>5</octave></pitch><duration>8</duration><type>whole</type></note></measure>
    <measure number="2"><note><pitch><step>D</step><octave>5</octave></pitch><duration>8</duration><type>whole</type></note></measure>
  </part>
  <part id="P2">
    <measure number="1"><attributes><divisions>2</divisions><key><fifths>0</fifths></key><time><beats>4</beats><beat-type>4</beat-type></time><staves>2</staves>
        <clef number="1"><sign>G</sign><line>2</line></clef><clef number="2"><sign>F</sign><line>4</line></clef></attributes>
      <note><pitch><step>E</step><octave>4</octave></pitch><duration>8</duration><voice>1</voice><type>whole</type><staff>1</staff></note>
      <backup><duration>8</duration></backup>
      <note><pitch><step>C</step><octave>3</octave></pitch><duration>8</duration><voice>5</voice><type>whole</type><staff>2</staff></note></measure>
    <measure number="2">
      <note><pitch><step>F</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><type>eighth</type><staff>1</staff><beam number="1">begin</beam></note>
      <note><pitch><step>G</step><octave>2</octave></pitch><duration>1</duration><voice>1</voice><type>eighth</type><staff>2</staff><beam number="1">end</beam></note>
      <note><rest/><duration>6</duration><voice>1</voice><type>half</type><dot/><staff>1</staff></note>
      <backup><duration>8</duration></backup>
      <note><pitch><step>D</step><octave>3</octave></pitch><duration>8</duration><voice>5</voice><type>whole</type><staff>2</staff></note></measure>
  </part>
</score-partwise>''';

/// A two-staff piano bar of cross-staff triplets under beams between the staves: top, bottom,
/// top, then bottom, top, bottom with a high chord on ledger lines in the middle.
String crossStaffTripletsScore() {
  String chord(String pitches, int staff, String beam, [String? tuplet]) {
    final notes = pitches.split(' ');
    return [
      for (var i = 0; i < notes.length; i++)
        '<note>${i > 0 ? '<chord/>' : ''}<pitch><step>${notes[i][0]}</step><octave>${notes[i][1]}</octave></pitch>'
            '<duration>2</duration><voice>1</voice><type>eighth</type>'
            '<time-modification><actual-notes>3</actual-notes><normal-notes>2</normal-notes></time-modification>'
            '<stem>${staff == 1 ? 'down' : 'up'}</stem><staff>$staff</staff>'
            '${i == 0 ? '<beam number="1">$beam</beam>' : ''}'
            '${i == 0 && tuplet != null ? '<notations><tuplet type="$tuplet" bracket="yes"/></notations>' : ''}</note>',
    ].join();
  }

  String rest(int duration, String type, int staff, int voice) =>
      '<note><rest/><duration>$duration</duration><voice>$voice</voice><type>$type</type><staff>$staff</staff></note>';
  return '<?xml version="1.0" encoding="UTF-8"?><score-partwise version="4.0">'
      '<part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list><part id="P1"><measure number="1">'
      '<attributes><divisions>6</divisions><key><fifths>0</fifths></key><time><beats>4</beats><beat-type>4</beat-type></time>'
      '<staves>2</staves><clef number="1"><sign>G</sign><line>2</line></clef><clef number="2"><sign>G</sign><line>2</line></clef></attributes>'
      '${rest(6, 'quarter', 1, 1)}'
      '${chord('E5 G5 B5 C6', 1, 'begin', 'start')}${chord('F4 A4 B4', 2, 'continue')}${chord('E5 G5 B5 C6', 1, 'end', 'stop')}'
      '${chord('D4 F4 A4 C5', 2, 'begin', 'start')}${chord('G5 C6 E6 G6 A6', 1, 'continue')}${chord('D4 F4 A4 C5', 2, 'end', 'stop')}'
      '${rest(6, 'quarter', 1, 1)}<backup><duration>24</duration></backup>${rest(24, 'whole', 2, 5)}'
      '</measure></part></score-partwise>';
}
