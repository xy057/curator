import 'package:curated_score/editor_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late EditorController c;
  late SyncMap sync;

  setUp(() async {
    c = EditorController(vsync: const TestVSync());
    await c.openFile(demoScore.path); // 6/8: a bar is three crotchets
    c.tab = BottomTab.audio;
    sync = c.sync!;
    for (var bar = 0; bar < 6; bar++) {
      sync.addAnchor(SyncAnchor(bar * 3.0, 1.0 + bar * 2)); // bars 1–6, one every 2 s
    }
  });

  tearDown(() => c.dispose());

  test('click, ⇧-click range and ⌘-click toggle', () {
    c.anchors.select(1);
    c.anchors.select(4, extend: true);
    expect(c.anchors.selected, {1, 2, 3, 4});
    c.anchors.select(2, toggle: true);
    expect(c.anchors.selected, {1, 3, 4});
    c.anchors.select(5);
    expect(c.anchors.selected, {5});
  });

  test('box selection, optionally adding to the selection', () {
    c.anchors.selectBetween(2.5, 7.5);
    expect(c.anchors.selected, {1, 2, 3});
    c.anchors.selectBetween(10.5, 11.5, keep: c.anchors.selected);
    expect(c.anchors.selected, {1, 2, 3, 5});
  });

  test('the selection nudges and re-points together, then deletes', () {
    c.anchors.selectBetween(2.5, 7.5); // bars 2–4
    c.anchors.nudge(0.25);
    expect(sync.anchors.map((a) => a.seconds), [1.0, 3.25, 5.25, 7.25, 9.0, 11.0]);

    sync.removeAnchors({4}); // make room after bar 4
    c.anchors.selectBetween(2.5, 7.5);
    c.anchors.shift(1); // "these were all one bar late in the score"
    expect(sync.anchors.map((a) => a.quarter), [0, 6, 9, 12, 15]);

    c.deleteSelection();
    expect(sync.anchors.map((a) => a.quarter), [0, 15]);
    c.undo();
    expect(sync.anchors, hasLength(5));
  });

  test('⌘A selects every anchor', () {
    c.anchors.selectAll();
    expect(c.anchors.selected, {0, 1, 2, 3, 4, 5});
  });

  test('a warp added at the repeat is one step, re-points the taps after it, and the preview jumps', () {
    // Tapped straight through bars 1–6, but the music went back to bar 1 after bar 3.
    final before = [...sync.anchors];
    final x = c.scene!.scrollMap.xAt;
    final bar2 = x(3), bar4 = x(7 - 1e-6);
    expect(c.anchors.addWarp(7, 9, 0), isTrue); // at 7 s: bar 4 → bar 1
    expect(sync.anchors.map((a) => (a.quarter, a.jumpTo)), [(0, null), (3, null), (6, null), (9, 0), (3, null), (6, null)]);
    expect(c.anchors.selected, {3});
    expect(c.scene!.scrollMap.xAt(7 - 1e-6), closeTo(bar4, 0.5));
    expect(c.scene!.scrollMap.xAt(9), closeTo(bar2, 0.5)); // bar 2 again
    expect(c.playback.duration, greaterThan(c.score!.timeline.measureStarts.last / 3 * 2 + 7));

    c.undo();
    expect(sync.anchors, before);
  });

  test('a warp can be edited and made a plain anchor again', () {
    expect(c.anchors.setAnchor(3, 9, jumpTo: 0), isTrue); // the bar 4 anchor is really the repeat
    expect(sync.anchors.map((a) => a.quarter), [0, 3, 6, 9, 3, 6]);
    expect(c.anchors.setAnchor(3, 9, jumpTo: 3), isTrue); // …to bar 2
    expect(sync.anchors.map((a) => a.quarter), [0, 3, 6, 9, 6, 9]);
    expect(c.anchors.setAnchor(3, 9), isTrue);
    expect(sync.anchors.map((a) => a.quarter), [0, 3, 6, 9, 12, 15]);
    expect(c.anchors.addWarp(12, 18, 200), isFalse, reason: 'past the end of the score');
    expect(sync.anchors, hasLength(6));
  });
}
