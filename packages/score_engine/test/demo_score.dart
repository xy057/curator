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
String demoScoreWithKeyChange({required int bar, required int concertFifths}) {
  final doc = XmlDocument.parse(demoScore());
  final names = {
    for (final p in doc.findAllElements('score-part')) p.getAttribute('id'): p.getElement('part-name')!.innerText,
  };
  for (final part in doc.rootElement.findElements('part')) {
    final name = names[part.getAttribute('id')]!;
    if (name == 'Timpani' || name == 'Snare Drum') continue;
    final written = concertFifths + (name.contains('B Flat') ? 2 : name.contains('Horn') ? 1 : 0);
    final measure = part.findElements('measure').elementAt(bar - 1);
    measure.children.insert(0, XmlDocument.parse('<attributes><key><fifths>$written</fifths></key></attributes>').rootElement.copy());
  }
  return doc.toXmlString();
}

/// The demo with its 6/8 written as the additive [beats] (e.g. "2+2+2"), the same bar length.
String demoScoreWithBeats(String beats) => demoScore().replaceAll('<beats>6</beats>', '<beats>$beats</beats>');
