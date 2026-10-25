
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

  test('one history steps back through every kind of edit, in order, whichever tab is showing; a new edit drops the redo; nothing open, nothing to undo', () async {
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

    // A new edit after Undo drops what could be redone.
    c.undo();
    expect(c.canRedo, isTrue);
    c.setTransition(0.5);
    expect(c.canRedo, isFalse);

    // With nothing open (⌘Z on the start screen), Undo and Redo do nothing.
    await c.close();
    expect(c.canUndo, isFalse);
    c.undo();
    c.redo();
    expect(c.score, isNull);
  });
}
