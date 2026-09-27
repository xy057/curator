// File ▸ Save / Save As… are always enabled: before a score is open, after one loads (the
// menu used to stay greyed out then, because it was never rebuilt), and with no changes.
import 'dart:io';

import 'package:curated_score/app_menus.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/project_document.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_project.dart';

void main() {
  testWidgets('Save and Save As stay enabled whatever is open or edited', (tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const CuratedScoreApp());
    final state = tester.state(find.byType(HomePage)) as dynamic;
    final c = state.controller as EditorController;
    final document = state.document as ProjectDocument;

    Future<MenuItemButton> item(String label) async {
      if (find.widgetWithText(MenuItemButton, label).evaluate().isEmpty) {
        await tester.tap(find.text('File'));
        await tester.pump();
      }
      return tester.widget<MenuItemButton>(find.widgetWithText(MenuItemButton, label));
    }

    Future<void> closeMenu() async {
      await tester.tapAt(const Offset(700, 600));
      await tester.pump();
    }

    // Nothing open: enabled, and Save explains there is nothing to save.
    expect((await item('Save')).onPressed, isNotNull);
    expect((await item('Save As…')).onPressed, isNotNull);
    await tester.tap(find.widgetWithText(MenuItemButton, 'Save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('Nothing to save yet'), findsOneWidget);

    // A score loaded without anything rebuilding the page around the menus.
    await tester.runAsync(() => c.openFile(demoScore.path));
    await tester.pump();
    expect(tester.widget<AppMenus>(find.byType(AppMenus)).onSave, isNotNull);
    expect((await item('Save')).onPressed, isNotNull);
    expect((await item('Save As…')).onPressed, isNotNull);
    await closeMenu();

    // Saved and unchanged: Save still writes the file.
    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('menus-test'));
    addTearDown(() => dir!.deleteSync(recursive: true));
    final file = File('${dir!.path}/theme.ccs');
    await tester.runAsync(() => document.save(file.path));
    expect(document.isDirty, isFalse);
    file.deleteSync();
    final save = await item('Save');
    expect(save.onPressed, isNotNull);
    await tester.runAsync(() async {
      save.onPressed!();
      while (!file.existsSync() || document.isSaving) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    expect(file.existsSync(), isTrue);
  });
}
