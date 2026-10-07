// The dialogs and menus around the lanes and the score, used as a user would: Rename, Edit
// Texts, a lane's ⋯ menu (and Copy lane to…), Tidy, and a double-click on a name in the score.
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/score_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';

void main() {
  late EditorController c;

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CuratedScoreApp(settings: AppSettings.memory()));
    c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScore.path));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  // Not pumpAndSettle: the editor always has something ticking.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
  }

  /// Chooses [item] from the first lane's ⋯ menu.
  Future<void> laneMenu(WidgetTester tester, String item) async {
    await tester.tap(find.byTooltip('Lane options').first);
    await settle(tester);
    await tester.tap(find.text(item).last);
    await settle(tester);
  }

  testWidgets('Rename: from the lane menu, with ♭ inserted; a double-click on the lane\'s name; back to the file\'s name',
      (tester) async {
    await open(tester);
    final piccolo = c.score!.metadata.parts.first;
    await laneMenu(tester, 'Rename…');
    expect(find.text('Rename instrument'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Flute in B');
    await tester.tap(find.widgetWithText(ActionChip, '♭'));
    await tester.enterText(find.widgetWithText(TextField, 'Short name'), 'Fl.');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await settle(tester);
    expect(c.partName(piccolo), 'Flute in B♭');
    expect(c.canUndo, isTrue);

    // Double-click the lane's name; take the file's name again.
    final name = tester.getCenter(find.text('Flute in B♭').first);
    await tester.tapAt(name);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(name);
    await settle(tester);
    expect(find.text('Rename instrument'), findsOneWidget);
    await tester.tap(find.text('Use name from file'));
    await settle(tester);
    expect(c.partName(piccolo), 'Piccolo');
  });

  testWidgets('a double-click on an instrument\'s name in the score renames it', (tester) async {
    await open(tester);
    final view = tester.getRect(find.byType(ScoreView));
    final label = c.scene!.layoutAt(c.playback.time.value, c.curation!, view.size).labels.firstWhere((l) => l.opacity > 0.9);
    final at = view.topLeft + Offset(c.scene!.style.headerWidth / 2, label.centerY);
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(at);
    await settle(tester);
    expect(find.text('Rename instrument'), findsOneWidget);
    final part = c.score!.metadata.parts.firstWhere((p) => p.id == label.partId);
    expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Name')).controller!.text, c.partName(part));
    await tester.tap(find.text('Cancel'));
    await settle(tester);
  });

  testWidgets("a lane's menu: select, clear, show throughout, auto-curate, copy, move, score order", (tester) async {
    await open(tester);
    final parts = c.score!.metadata.parts;
    final end = c.score!.timeline.measureStarts.last;

    await laneMenu(tester, 'Clear lane');
    expect(c.curation!.lane('P1'), isEmpty);
    await laneMenu(tester, 'Show throughout');
    expect(c.curation!.lane('P1'), [Region(0, end)]);
    await laneMenu(tester, 'Auto-curate this lane');
    expect(c.curation!.lane('P1'), isNot([Region(0, end)]), reason: 'only where it plays');
    expect(c.curation!.lane('P1'), isNotEmpty);
    await laneMenu(tester, 'Select all in lane');
    expect(c.lanes.selectedPartIds, {'P1'});
    expect(c.lanes.selected, hasLength(c.curation!.lane('P1').length));

    // Copy lane to…: Flute 1.
    await laneMenu(tester, 'Copy lane to…');
    expect(find.text('Copy ${c.laneName(parts.first)} to…'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Copy')).onPressed, isNull, reason: 'none chosen');
    await tester.tap(find.widgetWithText(CheckboxListTile, c.laneName(parts[1])));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Copy'));
    await settle(tester);
    expect(c.curation!.lane('P2'), c.curation!.lane('P1'));

    await laneMenu(tester, 'Move to bottom');
    expect(c.laneParts.last.id, 'P1');
    expect(c.isScoreOrder, isFalse);
    await laneMenu(tester, 'Move to top'); // Flute 1, now first
    expect(c.laneParts.first.id, 'P2');
    await laneMenu(tester, 'Restore score order');
    expect(c.isScoreOrder, isTrue);
  });

  testWidgets('Tidy fills short rests and removes short regions, in every lane or the selected ones', (tester) async {
    await open(tester);
    final starts = c.score!.timeline.measureStarts;
    c.curation!.setLane('P17', [
      Region(0, starts[2]),
      Region(starts[3], starts[5]), // after a rest of a bar
      Region(starts[10], starts[10] + 1.5), // half a bar, after five
    ]);
    await settle(tester);

    Future<void> tidy(String item) async {
      await tester.tap(find.byTooltip('Tidy all lanes'));
      await settle(tester);
      await tester.tap(find.text(item));
      await settle(tester);
    }

    await tidy('Keep shown through rests of up to 2 bars');
    expect(c.curation!.lane('P17'), [Region(0, starts[5]), Region(starts[10], starts[10] + 1.5)]);
    await tidy('Remove regions shorter than 1 bar');
    expect(c.curation!.lane('P17'), [Region(0, starts[5])]);
    c.undo();
    expect(c.curation!.lane('P17'), hasLength(2));
  });
}
