
import 'dart:typed_data';

import 'package:curated_score/audio_track.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/project_modules.dart';
import 'package:curated_score/project_state.dart';
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

  test('each recording keeps its own anchors; switching goes on at the same place in the score and is no Undo step', () async {
    final waveform = await Waveform.analyze(Float32List(100), 100);
    AudioTrack take(String name) => AudioTrack.forTesting(name: name, length: 60, waveform: waveform);
    await c.debugAddTake(take('Karajan.flac'));
    c.sync!.addAnchor(const SyncAnchor(0, 1));
    c.sync!.addAnchor(const SyncAnchor(8, 5));
    await c.debugAddTake(take('Bernstein.flac'));
    expect([for (final t in c.takes) t.label], ['Karajan', 'Bernstein']);
    expect(c.heard, 'take-2');
    expect(c.sync!.anchors, isEmpty, reason: 'a new recording has a sync of its own');
    c.sync!.addAnchor(const SyncAnchor(0, 2));
    c.sync!.addAnchor(const SyncAnchor(8, 6));

    c.playback.seek(3); // quarter 2 in Bernstein’s
    c.hearTake('take-1');
    expect(c.sync!.anchors, const [SyncAnchor(0, 1), SyncAnchor(8, 5)]);
    expect(c.playback.time.value, closeTo(2, 1e-9), reason: 'quarter 2 in Karajan’s');

    // Undo goes back through Bernstein's edits, whichever is heard, and never switches.
    c.undo();
    expect(c.heard, 'take-1');
    expect(c.sync!.anchors, const [SyncAnchor(0, 1), SyncAnchor(8, 5)]);
    expect(c.projectState.edits.take('take-2')!.anchors, const [SyncAnchor(0, 2)]);
    c.redo();

    // Saved and read back: the one heard in the sync module, the other in its take.
    final saved = ProjectModules.toJson(c.projectState);
    final read = ProjectModules.takes.read(JsonReader(saved['takes'], 'takes'), const ProjectState(), (_, {required limit}) => null);
    expect(read.edits.heard, 'take-1');
    expect(read.edits.take('take-2')!.anchors, const [SyncAnchor(0, 2), SyncAnchor(8, 6)]);

    // Removing the one heard hears the other, with its anchors.
    await c.removeTake('take-1');
    expect(c.heard, 'take-2');
    expect(c.sync!.anchors, const [SyncAnchor(0, 2), SyncAnchor(8, 6)]);
    c.undo();
    expect(c.sync!.anchors, const [SyncAnchor(0, 2)]);
  });
}
