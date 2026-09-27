import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_project.dart';


void main() {
  testWidgets('Recent files open from the home screen; missing ones say so', (tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final settings = AppSettings.memory()
      ..addRecent('/nowhere/Gone.ccs')
      ..addRecent(demoScore.absolute.path);
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    await tester.pumpAndSettle();

    // One Open for projects and scores, and the recent files, newest first.
    expect(find.text('Open…'), findsOneWidget);
    expect(find.textContaining('Import'), findsNothing);
    expect(find.text('WI275 - 01 Intro.musicxml'), findsWidgets);
    expect(find.textContaining('Not found'), findsOneWidget);

    // Open Recent is in the File menu too.
    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open Recent'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(MenuItemButton, 'Gone.ccs'), findsOneWidget);
    await tester.tapAt(const Offset(700, 700));
    await tester.pumpAndSettle();

    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    await tester.tap(find.text('WI275 - 01 Intro.musicxml').last);
    for (var i = 0; i < 100 && c.score == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(c.score, isNotNull);
    expect(settings.recentFiles.first, demoScore.absolute.path);
  });
}
