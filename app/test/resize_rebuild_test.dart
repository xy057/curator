// Resizing the window lays the editor out again at every step of the drag: the toolbar, the
// timeline's toolbar, ruler and lanes don't rebuild for it, so the window follows smoothly.
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/editor_toolbar.dart';
import 'package:curated_score/lanes_common.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/timeline_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_project.dart';
import 'window.dart';

void main() {
  testWidgets('resizing the window rebuilds nothing around the score', (tester) async {
    desktopWindow(tester);
    await tester.pumpWidget(CuratedScoreApp(settings: AppSettings.memory()));
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScore.path));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pumpAndSettle();

    Widget only(Finder f) => tester.widget(f.first);
    final names = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_LaneHeader');
    final toolbar = find.descendant(of: find.byType(EditorToolbar), matching: find.byType(Container));
    final before = (
      toolbar: only(toolbar),
      ruler: only(find.byType(BarRuler)),
      lanes: only(find.byType(InstrumentLanes)),
      name: only(names),
    );
    final width = c.viewport.pxPerSec;
    for (final size in const [Size(2600, 1600), Size(2400, 1700), Size(2300, 1500)]) {
      tester.view.physicalSize = size;
      await tester.pump();
      expect(only(toolbar), same(before.toolbar));
      expect(only(find.byType(BarRuler)), same(before.ruler));
      expect(only(find.byType(InstrumentLanes)), same(before.lanes));
      expect(only(names), same(before.name));
    }
    expect(c.viewport.pxPerSec, lessThan(width), reason: 'the fitted timeline still follows the width');
  });
}
