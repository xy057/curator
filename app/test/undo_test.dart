import 'package:curated_score/editor_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late EditorController c;

  setUp(() async {
    c = EditorController(vsync: const TestVSync());
    await c.openFile(demoScore.path);
  });
  tearDown(() => c.dispose());

  test('one history steps back through every kind of edit, in order, whichever tab is showing', () async {
    expect(c.canUndo, isFalse, reason: 'opening is not an edit');
    final part = c.score!.metadata.parts.first;
    final lanes = c.curation!.lanes;
    final vivo = c.score!.texts.firstWhere((t) => t.text == 'Vivo');

    c.curation!.clearAll(); // lanes
    c.sync!.addAnchor(const SyncAnchor(0, 1.5)); // sync
    c.renamePart(part, name: 'Solo Piccolo', abbreviation: 'Picc.'); // names
    await c.editText(vivo.id, 'Presto'); // texts
    c.setTransition(0.8); // the staff transition
    c.setStaffSpace(6); // the view: not an Undo step

    c.tab = BottomTab.audio; // the tab doesn't decide what Undo undoes
    c.undo();
    expect(c.curation!.transition, 0.3);
    c.undo();
    expect(c.textById(vivo.id)!.current, 'Vivo');
    c.undo();
    expect(c.partName(part), 'Piccolo');
    c.undo();
    expect(c.sync!.anchors, isEmpty);
    c.undo();
    expect(c.curation!.lanes, lanes);
    expect(c.canUndo, isFalse);
    expect(c.staffSpace, 6);

    for (var i = 0; i < 5; i++) {
      c.redo();
    }
    expect(c.curation!.transition, 0.8);
    expect(c.partName(part), 'Solo Piccolo');
    expect(c.textById(vivo.id)!.current, 'Presto');
    expect(c.canRedo, isFalse);
  });

  test('condensing a pair is one step, and only pairs that can condense are kept', () {
    expect(c.condensable.map((g) => g.id), contains('cond-P2-P3'));
    expect(c.condensed, isEmpty, reason: 'off until asked for, as in Dorico');
    c.setCondensed(['cond-P2-P3', 'cond-P17-P18'], on: true); // violins are sections: no pair
    expect(c.condensed, {'cond-P2-P3'});
    expect(c.scene!.condensed, {'cond-P2-P3'});
    expect(c.condensingGroupOf('P3')!.id, 'cond-P2-P3');
    expect(c.condensingGroupOf('P1'), isNull);
    c.undo();
    expect(c.condensed, isEmpty);
    expect(c.scene!.condensed, isEmpty);
    c.redo();
    expect(c.condensed, {'cond-P2-P3'});
  });

  test("the user's pairs: each made or removed in one step, engraved, and first over built-in ones", () async {
    Future<void> engraved() async {
      while (c.isReengraving) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    final starts = c.timeline.measureStarts;
    c.curation!.setLanes({'P2': [Region(0, starts[4])], 'P4': [Region(starts[8], starts[12])]}); // Flute 1, Oboe 1
    c.setCondensed(['cond-P2-P3'], on: true);
    expect(c.partnersOf('P2'), contains('P4'));

    await c.addPair('P4', 'P2');
    expect(c.pairs, const [PlayerPair('P2', 'P4')]);
    expect(c.condensable.map((g) => g.id), ['cond-P2-P4', for (var p = 6; p <= 12; p += 2) 'cond-P$p-P${p + 1}']);
    expect(c.condensed, contains('cond-P2-P4'), reason: 'made to be condensed');
    expect(c.score!.condensed.map((g) => g.id), contains('cond-P2-P4'));
    expect(c.scene!.score, same(c.score));
    expect(c.laneParts.map((p) => p.id), containsAll(['P2', 'P3']));
    expect(c.laneParts.map((p) => p.id), isNot(contains('P4')));
    expect(c.curation!.lane('P4'), c.curation!.lane('P2'));
    expect(c.laneName(c.score!.metadata.parts[1]), 'Flute 1 + Oboe 1');

    c.undo();
    await engraved();
    expect(c.pairs, isEmpty);
    expect(c.condensed, {'cond-P2-P3'});
    expect(c.score!.condensed.map((g) => g.id), isNot(contains('cond-P2-P4')));
    expect(c.curation!.lane('P4'), [Region(starts[8], starts[12])]);
    c.redo();
    await engraved();
    expect(c.score!.condensed.map((g) => g.id), contains('cond-P2-P4'));

    await c.removePair(const PlayerPair('P2', 'P4'));
    expect(c.pairs, isEmpty);
    expect(c.condensed, contains('cond-P2-P3'), reason: 'the built-in pair comes back as it was');
    expect(c.score!.condensed.map((g) => g.id), contains('cond-P2-P3'));
  });

  test('a gesture is one step, however many changes it makes', () {
    final id = c.score!.metadata.parts.first.id;
    c.curation!.clearAll();
    c.beginEdit();
    for (var end = 3.0; end <= 12; end += 3) {
      c.curation!.updateLanes({id: [Region(0, end), const Region(6, 9)]}); // overlapping while dragging
    }
    c.endEdit();
    expect(c.curation!.lane(id), [const Region(0, 12)], reason: 'merged when the drag ends');
    c.undo();
    expect(c.curation!.lane(id), isEmpty);
  });

  test('a new edit after Undo drops what could be redone', () {
    final id = c.score!.metadata.parts.first.id;
    c.curation!.setLane(id, const [Region(0, 3)]);
    c.undo();
    expect(c.canRedo, isTrue);
    c.curation!.setLane(id, const [Region(3, 6)]);
    expect(c.canRedo, isFalse);
  });
}
