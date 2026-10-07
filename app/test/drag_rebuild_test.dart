// A drag in the lanes changes the selection at every move: the window around the lanes
// (the page, the toolbar, the score, the lanes' names) doesn't rebuild for it.
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/editor_toolbar.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/score_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart' show SyncAnchor;

import 'demo_project.dart';

void main() {
  testWidgets('selecting another region in the same lane rebuilds only what shows it', (tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CuratedScoreApp(settings: AppSettings.memory()));
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScore.path));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    final part = c.laneParts.firstWhere((p) => c.curation!.lane(p.id).length >= 2).id;
    final regions = c.curation!.lane(part);
    c.lanes.select(part, regions[0]);
    await tester.pumpAndSettle();

    Widget only(Finder f) => tester.widget(f.first);
    final names = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_LaneHeader');
    final before = (
      page: only(find.byType(Scaffold)),
      toolbar: only(find.descendant(of: find.byType(EditorToolbar), matching: find.byType(Container))),
      score: only(find.descendant(of: find.byType(ScoreView), matching: find.byType(LayoutBuilder))),
      name: only(names),
    );
    c.lanes.select(part, regions[1]);
    await tester.pump();
    expect(only(find.byType(Scaffold)), same(before.page));
    expect(only(find.descendant(of: find.byType(EditorToolbar), matching: find.byType(Container))), same(before.toolbar));
    expect(only(find.descendant(of: find.byType(ScoreView), matching: find.byType(LayoutBuilder))), same(before.score));
    expect(only(names), same(before.name));
    expect(c.lanes.isSelected(part, regions[1]), isTrue);
  });

  testWidgets('a dragged anchor re-plans the scroll once a frame, not at every move', (tester) async {
    await tester.pumpWidget(CuratedScoreApp(settings: AppSettings.memory()));
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScore.path));
    await tester.pump(const Duration(milliseconds: 200));
    final starts = c.timeline.measureStarts;
    for (final bar in [2, 6]) {
      c.anchors.add(SyncAnchor(starts[bar], c.timeline.secondsAtQuarter(starts[bar])));
    }
    c.anchors.select(1);
    final from = c.sync!.anchors, scroll = c.scene!.scrollMap;
    c.beginEdit();
    for (final d in [0.01, 0.02, 0.03]) {
      c.anchors.drag(d, from: from);
    }
    c.endEdit();
    final followed = c.scene!.scrollMap; // asked once: follows the sync as it is now
    expect(followed, isNot(same(scroll)));
    expect(c.scene!.timeline, same(c.sync));
    expect(c.scene!.scrollMap, same(followed), reason: 'nothing changed since');
  });
}
