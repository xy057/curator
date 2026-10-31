
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

  test('anchors convert to a tempo map and back, one Undo step each; arrows move and retune the change selected', () async {
    const hand = [SyncAnchor(0, 1), SyncAnchor(12, 6), SyncAnchor(24, 10.5), SyncAnchor(36, 16)];
    c.sync!.load(hand, leadIn: 1);
    c.convertToTempoMap();
    expect(c.usesMidiTempo, isTrue);
    for (final a in hand) {
      expect(c.sync!.secondsAtQuarter(a.quarter), closeTo(a.seconds, 1e-9));
    }

    // 6/8: a beat is a dotted quarter. The change at bar 3 (quarter 12, ♩ = 160) a beat on, then
    // 106⅔ beats a minute up to 107.
    c.anchors.selectTempo(1);
    c.anchors.moveTempo(1);
    expect(c.midiTempo!.tempos[1].quarter, 13.5);
    c.anchors.retune(1);
    expect(c.midiTempo!.tempos[1].quartersPerMinute, closeTo(107 * 1.5, 1e-9));
    c.undo();
    c.undo();
    expect(c.midiTempo!.tempos[1].quarter, 12);
    expect(c.midiTempo!.tempos[1].quartersPerMinute, closeTo(160, 1e-9));

    final followed = c.sync!.anchors;
    c.convertToAnchors();
    expect(c.usesMidiTempo, isFalse);
    expect(c.sync!.anchors, followed, reason: 'the anchors it followed, now set by hand');
    c.undo();
    expect(c.usesMidiTempo, isTrue);
    c.undo();
    expect(c.usesMidiTempo, isFalse);
    expect(c.sync!.anchors, hand);
  });

  test('recordings in lanes: one heard at a time, a region drawn takes its stretch from the others; picking one edits its sync and keeps the place; Undo keeps the takes', () async {
    final waveform = await Waveform.analyze(Float32List(100), 100);
    AudioTrack take(String name) => AudioTrack.forTesting(name: name, length: 60, waveform: waveform);
    await c.debugAddTake(take('Karajan.flac'));
    final total = c.sync!.totalQuarters;
    expect(c.takes.single.regions, [Region(0, total)], reason: 'the first is heard throughout');
    c.sync!.addAnchor(const SyncAnchor(0, 1));
    c.sync!.addAnchor(const SyncAnchor(8, 5));
    await c.debugAddTake(take('Bernstein.flac'));
    expect([for (final t in c.takes) t.label], ['Karajan', 'Bernstein']);
    expect((c.focus, c.syncedTake, c.editsSync), ('take-2', 'take-2', true), reason: 'a new one is picked');
    expect(c.takes.last.regions, isEmpty);
    expect(c.sync!.anchors, isEmpty, reason: 'a new recording has a sync of its own');
    c.sync!.addAnchor(const SyncAnchor(0, 2));
    c.sync!.addAnchor(const SyncAnchor(8, 6));

    c.playback.seek(3); // quarter 2 in Bernstein’s
    c.editSyncOf('take-1');
    expect(c.sync!.anchors, const [SyncAnchor(0, 1), SyncAnchor(8, 5)]);
    expect(c.playback.time.value, closeTo(2, 1e-9), reason: 'quarter 2 in Karajan’s');

    // Undo goes back through Bernstein's edits, whichever is picked, and never switches.
    c.undo();
    expect(c.focus, 'take-1');
    expect(c.sync!.anchors, const [SyncAnchor(0, 1), SyncAnchor(8, 5)]);
    expect(c.projectState.edits.take('take-2')!.anchors, const [SyncAnchor(0, 2)]);
    c.redo();

    // None picked: spliced. Bernstein's region in bars 2–3 is cut out of Karajan's lane.
    c.editSyncOf('take-1');
    expect(c.editsSync, isFalse);
    c.setTakeRegions('take-2', [Region(4, 8)]);
    expect(c.takes.first.regions, [Region(0, 4), Region(8, total)]);
    expect(c.timeline.secondsAtQuarter(4), closeTo(3, 1e-9), reason: 'Karajan’s time to bar 2');
    expect(c.timeline.secondsAtQuarter(8), closeTo(5, 1e-9), reason: 'then 2 s at Bernstein’s');
    c.undo();
    expect([for (final t in c.takes) t.regions], [[Region(0, total)], isEmpty]);
    c.redo();

    // Saved and read back: the focus's sync in the sync module, the other's in its take.
    final saved = ProjectModules.toJson(c.projectState);
    final read = ProjectModules.takes.read(JsonReader(saved['takes'], 'takes'), const ProjectState(), (_, {required limit}) => null);
    expect(read.edits.focus, 'take-1');
    expect(read.edits.take('take-2')!.anchors, const [SyncAnchor(0, 2), SyncAnchor(8, 6)]);
    expect(read.edits.take('take-2')!.regions, [Region(4, 8)]);

    // Removing the focus leaves the other, with its anchors, its sync edited again.
    await c.removeTake('take-1');
    expect((c.focus, c.editsSync), ('take-2', true));
    expect(c.sync!.anchors, const [SyncAnchor(0, 2), SyncAnchor(8, 6)]);
  });
}
