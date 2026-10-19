// Project Info ▸ Replace Score: another score file under the open project's edits. Instruments are
// matched by name when their ids move, positions by bar, texts by where they are; what differs
// is listed in a warning before anything changes.
import 'dart:io';

import 'package:curated_score/editor_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';

/// The demo's score with a Celesta (a copy of the Piccolo) added on top, every other part's id
/// one higher, its last bar gone and its first tempo 120.
String _variant() {
  var xml = demoScore
      .readAsStringSync()
      .replaceAllMapped(RegExp(r'id="P(\d+)'), (m) => 'id="P${int.parse(m[1]!) + 1}')
      .replaceFirst('<sound tempo="93"/>', '<sound tempo="120"/>')
      .replaceAll(RegExp(r'<measure number="44".*?</measure>\s*', dotAll: true), '');
  final scorePart = RegExp(r'<score-part id="P2">.*?</score-part>', dotAll: true).firstMatch(xml)![0]!;
  final part = RegExp(r'<part id="P2">.*?</part>', dotAll: true).firstMatch(xml)![0]!;
  xml = xml
      .replaceFirst(scorePart, '${scorePart.replaceAll('"P2', '"P1').replaceAll('Piccolo', 'Celesta')}\n$scorePart')
      .replaceFirst(part, '${part.replaceFirst('<part id="P2">', '<part id="P1">')}\n$part');
  return xml;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EditorController', () {
    late EditorController c;
    late Directory temp;

    setUp(() async {
      c = EditorController(vsync: const TestVSync());
      temp = Directory.systemTemp.createTempSync('replace-score');
      await c.openFile(demoScore.path);
    });
    tearDown(() {
      c.dispose();
      temp.deleteSync(recursive: true);
    });

    test('another version keeps the edits, by instrument and bar, and lists what differs', () async {
      final piccolo = c.score!.metadata.parts.first;
      final flute = c.score!.metadata.parts[1];
      c.renamePart(piccolo, name: 'Ottavino', abbreviation: 'Ott.');
      final vivo = c.score!.texts.firstWhere((t) => t.text == 'Vivo');
      await c.editText(vivo.id, 'Presto');
      c.sync!.load(const [SyncAnchor(0, 1), SyncAnchor(12, 9)], leadIn: 1);
      c.captions.enabled = true;
      c.captions.replaceAll(const [Caption(3, 9, 'Exposition')]);
      final fluteLane = c.curation!.lane(flute.id);
      final revision = c.editRevision.value;
      expect(c.canUndo, isTrue);

      final file = File('${temp.path}/Intro v2.musicxml')..writeAsStringSync(_variant());
      final replacement = await c.prepareReplacement(file.path);
      expect(c.source!.name, isNot('Intro v2.musicxml'), reason: 'nothing changes before replacing');
      expect(
        replacement.differences,
        containsAllInOrder(['Added: Celesta', 'Bars: 44 → 43', 'Tempo: ♩ = 93 → ♩ = 120']),
      );
      expect(replacement.differences.where((d) => d.startsWith('Text edits')), isEmpty);

      await c.replaceScore(replacement);
      expect(c.source!.name, 'Intro v2.musicxml');
      expect(c.score!.metadata.parts.map((p) => p.name).take(3), ['Celesta', 'Piccolo', 'Flute 1']);
      expect(c.partNameOf('P2'), 'Ottavino');
      final end = c.sync!.totalQuarters;
      expect(c.curation!.lane('P3'), [
        for (final r in fluteLane)
          if (r.start < end) r.withBounds(r.start, r.end < end ? r.end : end),
      ]);
      expect(c.curation!.lane('P1'), isNotEmpty, reason: 'the new part is curated');
      final presto = c.score!.texts.where((t) => t.text == 'Vivo' && t.partId == 'P2').single;
      expect(c.textById(presto.id)!.current, 'Presto');
      expect(c.sync!.anchors, const [SyncAnchor(0, 1), SyncAnchor(12, 9)]);
      expect(c.captions.captions, const [Caption(3, 9, 'Exposition')]);
      expect(c.canUndo, isFalse, reason: 'Undo starts again from here');
      expect(c.editRevision.value, greaterThan(revision), reason: 'unsaved');
    });
  });

}
