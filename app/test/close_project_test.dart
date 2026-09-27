// File ▸ Close goes back to the start screen, asking first when there are unsaved changes;
// a project can then be opened again from a clean slate. The demo can't be saved, so it
// never asks.
import 'dart:io';

import 'package:curated_score/app_menus.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/home_screen.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/project_document.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_project.dart';

void main() {
  testWidgets('Close returns to the start screen', (tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const CuratedScoreApp());
    await tester.pump(const Duration(seconds: 1));
    final state = tester.state(find.byType(HomePage)) as dynamic;
    final c = state.controller as EditorController;
    final document = state.document as ProjectDocument;

    Future<void> openSample() async {
      await tester.tap(find.text('Try the sample'));

      for (var i = 0; i < 300 && c.score == null; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 600));
      // Tests have no audio plugin: the sample's recording can't load (just after the score),
      // which the app reports.
      for (var i = 0; i < 20 && find.text('OK').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      if (find.text('OK').evaluate().isNotEmpty) {
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
      }
    }

    Future<void> close() async {
      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, 'Close'));
      await tester.pump();
    }

    AppMenus menus() => tester.widget<AppMenus>(find.byType(AppMenus));

    await openSample();
    expect(find.byType(HomeScreen), findsNothing);

    // The demo: Save and Save As are off, and an edit leaves nothing unsaved, so Close asks nothing.
    expect(document.isSample, isTrue);
    expect(menus().onSave, isNull);
    expect(menus().onSaveAs, isNull);
    c.curation!.clearAll();
    await tester.pump();
    expect(document.isDirty, isFalse);
    await expectLater(document.save('${Directory.systemTemp.path}/demo.ccs'), throwsStateError);
    await close();
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('Save changes'), findsNothing);
    expect(c.score, isNull);
    expect(document.isSample, isFalse);

    // A project of one's own (a score imported): an edit, then Close: asked whether to save.
    await tester.runAsync(() => document.importScore(demoScore.path));
    await tester.pump(const Duration(milliseconds: 600));
    expect(menus().onSave, isNotNull);
    c.curation!.clearAll();
    await tester.pump();
    expect(document.isDirty, isTrue);
    await close();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Save changes'), findsOneWidget);
    await tester.tap(find.text('Don’t Save'));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(c.score, isNull);
    expect(document.isDirty, isFalse);
    expect(document.path, isNull);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Nothing open: Close is greyed out, and the sample opens again cleanly.
    await tester.pumpAndSettle();
    expect(menus().onClose, isNull);
    await openSample();
    expect(c.score, isNotNull);
    expect(c.score!.metadata.parts.any((p) => c.curation!.lane(p.id).isNotEmpty), isTrue); // the saved curation, not the cleared one
  });
}
