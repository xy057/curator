import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:score_engine/score_engine.dart';

/// The app's bundled demo project (a .ccs zip); tests run in packages/score_engine/.
final demoProject = File('../../app/assets/demo/WI275 - 01 Intro.ccs');

/// The demo's score, a 44-bar 6/8 orchestral intro for 21 instruments, as MusicXML:
/// transposing clarinets, horns and trumpets, texts ("Vivo", "pizz.", "arco"), no key change.
String demoScore() {
  final archive = ZipDecoder().decodeBytes(demoProject.readAsBytesSync());
  final entry = archive.files.firstWhere((f) => f.isFile && f.name.startsWith('score/'));
  return ScoreFile.decodeMusicXML(entry.content);
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

/// The demo as a Standard MIDI File (format 1, 480 ticks a quarter): a first track with its
/// name, tempo (♩ = 93), 6/8 and key; then a track an instrument with its name and notes as
/// they sound, the timpani and snare drum on the drum channel, each note at a velocity from
/// its place in the bar.
Uint8List demoMidi() {
  const division = 480;
  final xml = demoScore(), parts = ScoreMetadata.read(xml).parts;
  final starts = [for (var bar = 0; bar <= 44; bar++) bar * 3.0];
  List<int> length(int v) => [if (v >= 1 << 21) 0x80 | v >> 21 & 0x7f, if (v >= 1 << 14) 0x80 | v >> 14 & 0x7f, if (v >= 1 << 7) 0x80 | v >> 7 & 0x7f, v & 0x7f];
  List<int> track(List<(int tick, List<int> bytes)> events) {
    final sorted = [...events.indexed]..sort((a, b) => a.$2.$1 != b.$2.$1 ? a.$2.$1.compareTo(b.$2.$1) : a.$1.compareTo(b.$1));
    final body = <int>[];
    var at = 0;
    for (final (_, (tick, bytes)) in sorted) {
      body
        ..addAll(length(tick - at))
        ..addAll(bytes);
      at = tick;
    }
    body.addAll([0, 0xff, 0x2f, 0]);
    return [...'MTrk'.codeUnits, body.length >> 24, body.length >> 16 & 0xff, body.length >> 8 & 0xff, body.length & 0xff, ...body];
  }

  List<int> text(int type, String s) => [0xff, type, ...length(utf8.encode(s).length), ...utf8.encode(s)];
  final micro = (60e6 / 93).round();
  final tracks = [
    track([
      (0, text(0x03, 'Intro')),
      (0, [0xff, 0x51, 3, micro >> 16, micro >> 8 & 0xff, micro & 0xff]),
      (0, [0xff, 0x58, 4, 6, 3, 24, 8]),
      (0, [0xff, 0x59, 2, 0, 0]),
    ]),
  ];
  final notes = soundingNotes(xml, starts, unpitched: true).toList();
  for (final (i, part) in parts.indexed) {
    final drums = part.isUnpitchedPercussion, channel = drums ? 9 : i % 9;
    final events = <(int, List<int>)>[(0, text(0x03, part.name))];
    for (final n in notes.where((n) => n.partId == part.id)) {
      final start = (n.start * division).round(), end = (n.end * division).round();
      // The off first where one ends as the next starts.
      events.add((end, [0x80 | channel, n.midi, 0]));
      events.add((start, [0x90 | channel, n.midi, 50 + (start ~/ 240) % 6 * 12]));
    }
    tracks.add(track(events));
  }
  return Uint8List.fromList([
    ...'MThd'.codeUnits, 0, 0, 0, 6, 0, 1, tracks.length >> 8, tracks.length & 0xff, division >> 8, division & 0xff, //
    for (final t in tracks) ...t,
  ]);
}
