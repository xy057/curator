// Score ▸ Replace Score…: another score file under the open project's edits. Instruments are
// matched by name when their ids move, positions by bar, texts by where they are; what differs
// is listed in a warning before anything changes.
import 'dart:io';

import 'package:curated_score/app_menus.dart';
import 'package:curated_score/edit_dialogs.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/project_state.dart';
import 'package:curated_score/score_replacement.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';

ScorePart _part(String id, String name) =>
    ScorePart(id: id, name: name, abbreviation: '', sound: null, staffNumbers: const [1]);

ScoreMetadata _score(List<ScorePart> parts, {double? tempo = 100, List<Meter?> meters = const []}) => ScoreMetadata(
  title: '',
  parts: parts,
  tempo: tempo,
  activeMeasures: {
    for (final p in parts) p.id: const [true, true, false, true],
  },
  meters: meters,
);

ScoreSwap _swap(
  ScoreMetadata before,
  ScoreMetadata after, {
  List<ScoreText> textsBefore = const [],
  List<ScoreText> textsAfter = const [],
}) => ScoreSwap(before: before, after: after, textsBefore: textsBefore, textsAfter: textsAfter);

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

  group('ScoreSwap', () {
    test('instruments are matched by id and name, then name, then id', () {
      final before = _score([_part('P1', 'Flute'), _part('P2', 'Oboe'), _part('P3', 'Viola')]);
      // A Horn added on top renumbers the rest; the Viola has gone, and its id is the Oboe's now.
      final after = _score([_part('P1', 'Horn'), _part('P2', 'Flute'), _part('P3', 'Oboe')]);
      final swap = _swap(before, after);
      expect(swap.parts, {'P1': 'P2', 'P2': 'P3'});
      expect([for (final p in swap.added) p.name], ['Horn']);
      expect([for (final p in swap.removed) p.name], ['Viola']);
      expect(swap.renamed, isEmpty);

      // Same id, another name, and no name to match: renamed.
      final renamed = _swap(before, _score([_part('P1', 'Flute 1'), _part('P2', 'Oboe'), _part('P3', 'Viola')]));
      expect(renamed.parts, {'P1': 'P1', 'P2': 'P2', 'P3': 'P3'});
      expect([for (final (a, b) in renamed.renamed) '${a.name}→${b.name}'], ['Flute→Flute 1']);
    });

    test('a position keeps its bar and its distance into it', () {
      const before = <double>[0, 3, 6, 9]; // three bars of 3/4
      const after = <double>[0, 3, 5, 8, 11]; // bar 2 is now 2/4, and there is a fourth
      double? at(double q) => ScoreSwap.quarterAt(q, before, after);
      expect(at(0), 0);
      expect(at(1.5), 1.5);
      expect(at(3), 3, reason: 'a barline is the same barline');
      expect(at(5.5), 5, reason: 'no further than the bar’s end');
      expect(at(7), 6);
      expect(at(9), 8, reason: 'the old end is the same barline, not the new end');
      expect(ScoreSwap.quarterAt(7, before, const <double>[0, 3.0, 6.0]), isNull, reason: 'past the last bar');
      expect(ScoreSwap.quarterAt(9, before, const <double>[0, 3.0, 6.0]), isNull);
    });

    test('the project is carried over by part and bar; what is past the end is counted', () {
      final before = _score([_part('P1', 'Flute'), _part('P2', 'Oboe')]);
      final after = _score([_part('P1', 'Horn'), _part('P2', 'Flute'), _part('P3', 'Oboe')]);
      const measuresBefore = <double>[0, 3, 6, 9, 12], measuresAfter = <double>[0, 3, 6, 9];
      final project = ProjectState(
        edits: EditState(
          lanes: {
            'P1': [const Region(0, 4, transitionIn: 1), const Region(10, 11)],
            'P2': [const Region(4, 12)],
          },
          anchors: const [SyncAnchor(3, 2), SyncAnchor(6, 4, jumpTo: 0), SyncAnchor(10, 9)],
          partNames: const {'P2': (name: 'Hautbois', abbreviation: 'Hb.')},
          partOrder: const ['P2', 'P1'],
          pairs: const [PlayerPair('P1', 'P2')],
          condensed: {const PlayerPair('P1', 'P2').id},
          captions: const [Caption(1, 4, 'A'), Caption(8, 12, 'B'), Caption(10, 11, 'C')],
          transition: 0.8,
          leadIn: 1.5,
          captionFont: 'Helvetica',
        ),
      );
      final swap = _swap(before, after);
      final (:state, :lost) = swap.carry(
        project,
        condensable: const [PlayerPair('P1', 'P2')],
        measuresBefore: measuresBefore,
        measuresAfter: measuresAfter,
      );

      expect(state.edits.lanes!['P2'], [const Region(0, 4, transitionIn: 1)]);
      expect(state.edits.lanes!['P3'], [const Region(4, 9)], reason: 'cut at the new end');
      expect(
        state.edits.lanes!['P1'],
        Curation.autoCuratedLanes(['P1'], after.activeMeasures, measuresAfter)['P1'],
        reason: 'a new instrument is curated as on import',
      );
      expect(state.edits.anchors, const [SyncAnchor(3, 2), SyncAnchor(6, 4, jumpTo: 0)]);
      expect(state.edits.partNames, {'P3': (name: 'Hautbois', abbreviation: 'Hb.')});
      expect(state.edits.partOrder, ['P3', 'P2']);
      expect(state.edits.pairs, const [PlayerPair('P2', 'P3')]);
      expect(state.edits.condensed, {const PlayerPair('P2', 'P3').id});
      expect(state.edits.captions, const [Caption(1, 4, 'A'), Caption(8, 9, 'B')]);
      expect(lost, (regions: 1, anchors: 1, captions: 1, images: 0));
      // What has no part id or position stays as it was.
      expect((state.edits.transition, state.edits.leadIn, state.edits.captionFont), (0.8, 1.5, 'Helvetica'));

      expect(
        swap.differences(measuresBefore: measuresBefore, measuresAfter: measuresAfter, edits: const {}, lost: lost),
        ['Added: Horn', 'Bars: 4 → 3', 'Lost past bar 3: 1 region, 1 anchor, 1 caption'],
      );
    });

    test('a text edit follows its text when the ids the app gave it shift', () {
      final parts = [_part('P1', 'Flute')];
      ScoreText text(String id, int measure, String words) =>
          ScoreText(id: id, partId: 'P1', measure: measure, text: words, kind: ScoreTextKind.direction);
      final swap = _swap(
        _score(parts),
        _score(parts),
        textsBefore: [text('cs-dir-0', 0, 'dolce'), text('cs-dir-1', 2, 'cresc.')],
        textsAfter: [text('cs-dir-0', 0, 'pp'), text('cs-dir-1', 0, 'dolce'), text('cs-dir-2', 3, 'cresc.')],
      );
      expect(swap.textEdits({'cs-dir-0': 'dolciss.', 'cs-dir-1': 'cresc. molto'}), {'cs-dir-1': 'dolciss.'});
      expect(
        swap.differences(
          measuresBefore: const <double>[0, 3.0],
          measuresAfter: const <double>[0, 3.0],
          edits: {'cs-dir-0': 'x', 'cs-dir-1': 'y'},
        ),
        ['Text edits lost: 1'],
        reason: 'cresc. moved to another bar',
      );
    });

    test('meters, bar lengths and tempo are compared', () {
      final parts = [_part('P1', 'Flute')];
      const waltz = Meter([1, 1, 1], '3/4'), march = Meter([2, 2], '2/2');
      final swap = _swap(
        _score(parts, meters: const [waltz, waltz, waltz]),
        _score(parts, tempo: 72.5, meters: const [waltz, march, march]),
      );
      expect(
        swap.differences(
          measuresBefore: const <double>[0, 3.0, 6.0, 9.0],
          measuresAfter: const <double>[0, 3.0, 7.0, 11.0],
          edits: const {},
        ),
        ['Time signature differs from bar 2', 'Tempo: ♩ = 100 → ♩ = 72.5'],
      );
      expect(
        _swap(
          _score(parts),
          _score(parts),
        ).differences(measuresBefore: const <double>[0, 1.0, 4.0], measuresAfter: const <double>[0, 3.0, 6.0], edits: const {}),
        ['Bar length differs from bar 1'],
        reason: 'an upbeat made a whole bar',
      );
      expect(
        _swap(
          _score(parts),
          _score(parts),
        ).differences(measuresBefore: const <double>[0, 3.0], measuresAfter: const <double>[0, 3.0], edits: const {}),
        isEmpty,
      );
    });
  });

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

    test('the same file again changes nothing and warns of nothing', () async {
      final lanes = c.curation!.lanes;
      final replacement = await c.prepareReplacement(demoScore.path);
      expect(replacement.differences, isEmpty);
      await c.replaceScore(replacement);
      expect(c.curation!.lanes, lanes);
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

    test('a file that isn’t a score changes nothing', () async {
      final file = File('${temp.path}/notes.musicxml')..writeAsStringSync('not a score');
      final source = c.source;
      await expectLater(c.prepareReplacement(file.path), throwsA(anything));
      expect(c.source, source);
    });
  });

  testWidgets('the warning lists the differences; Cancel keeps the score', (tester) async {
    await tester.pumpWidget(const CuratedScoreApp());
    expect(tester.widget<AppMenus>(find.byType(AppMenus)).onReplaceScore, isNull, reason: 'greyed out with nothing open');
    final context = tester.element(find.byType(HomePage));
    late Future<bool> answer;
    answer = confirmReplaceScore(context, 'Intro v2.musicxml', const ['Added: Celesta', 'Bars: 44 → 43']);
    await tester.pumpAndSettle();
    expect(find.text('Replace with “Intro v2.musicxml”?'), findsOneWidget);
    expect(find.text('Bars: 44 → 43'), findsOneWidget);
    expect(find.text('Can’t be undone.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await answer, isFalse);

    answer = confirmReplaceScore(context, 'x.musicxml', const ['Removed: Viola']);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Replace'));
    await tester.pumpAndSettle();
    expect(await answer, isTrue);
  });
}
