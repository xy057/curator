// File ▸ Save / Save As… are always enabled: before a score is open, after one loads (the
// menu used to stay greyed out then, because it was never rebuilt), and with no changes.
import 'dart:io';

import 'package:curated_score/app_menus.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/project_document.dart';
import 'package:curated_score/updater.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart' show EngraveOption, EngravingOptions;

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

  testWidgets('Edit greys out what has nothing to do', (tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const CuratedScoreApp());
    final state = tester.state(find.byType(HomePage)) as dynamic;
    final c = state.controller as EditorController;

    AppMenus menus() => tester.widget<AppMenus>(find.byType(AppMenus));

    // Nothing open: nothing to edit.
    expect(menus().onUndo, isNull);
    expect(menus().onRedo, isNull);
    expect(menus().onPaste, isNull);
    expect(menus().onDelete, isNull);
    expect(menus().onSelectAll, isNull);

    await tester.runAsync(() => c.openFile(demoScore.path));
    await tester.pump();
    expect(menus().onUndo, isNull);
    expect(menus().onRedo, isNull);
    expect(menus().onDelete, isNull);
    expect(menus().onSelectAll, isNotNull);

    // Through the menu bar: Select All, Delete, then Undo and Redo.
    Future<void> choose(String label) async {
      await tester.tap(find.text('Edit'));
      await tester.pump();
      final item = tester.widget<MenuItemButton>(find.widgetWithText(MenuItemButton, label));
      expect(item.onPressed, isNotNull, reason: label);
      await tester.tap(find.widgetWithText(MenuItemButton, label));
      await tester.pump(); // the menu closes, then the item runs
      await tester.pump();
    }

    await choose('Select All');
    expect(menus().onDelete, isNotNull);
    await choose('Delete');
    expect(menus().onUndo, isNotNull);
    expect(menus().onRedo, isNull);
    await choose('Undo');
    expect(menus().onUndo, isNull);
    expect(menus().onRedo, isNotNull);
    await choose('Redo');
    expect(menus().onRedo, isNull);

    // Cut and Copy take selected regions; Paste then puts them back in.
    expect(menus().onCopy, isNull);
    expect(menus().onCut, isNull);
    expect(menus().onPaste, isNull);
    await choose('Undo'); // the regions deleted above
    await choose('Select All');
    expect(menus().onCopy, isNotNull);
    await choose('Cut');
    expect(c.curation!.partIds.every((id) => c.curation!.lane(id).isEmpty), isTrue);
    expect(menus().onCopy, isNull, reason: 'nothing selected after a cut');
    await choose('Paste');
    expect(c.curation!.partIds.any((id) => c.curation!.lane(id).isNotEmpty), isTrue);
    c.tab = BottomTab.audio;
    await tester.pump();
    expect(menus().onPaste, isNull, reason: 'regions go only into the Instruments tab');
    expect(menus().onCopy, isNull);

    // Elsewhere Paste follows Attach Image's switch.
    c.images.enabled = true;
    await tester.pump();
    expect(menus().onPaste, isNotNull);

    // A dialog over the page has the keyboard: Edit is off under it.
    showDialog<void>(context: tester.element(find.byType(HomePage)), builder: (_) => const Text('dialog'));
    await tester.pump();
    expect(menus().onUndo, isNull);
    expect(menus().onSelectAll, isNull);
  });

  testWidgets('About Curator opens Settings ▸ About', (tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const CuratedScoreApp());

    await tester.tap(find.text('Help'));
    await tester.pump();
    await tester.tap(find.widgetWithText(MenuItemButton, 'About Curator'));
    await tester.pumpAndSettle();
    expect(find.text('Version $appVersion'), findsOneWidget);
    expect(find.textContaining('Verovio'), findsOneWidget);
  });

  testWidgets('Score ▸ Project Settings… opens the project\'s settings, greyed out with nothing open; File has the app\'s', (tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const CuratedScoreApp());
    Finder item() => find.widgetWithText(MenuItemButton, 'Project Settings…');

    await tester.tap(find.text('Score'));
    await tester.pump();
    expect(item(), findsNWidgets(1));
    expect(tester.widget<MenuItemButton>(item()).onPressed, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(item(), findsNothing);

    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScore.path));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150)); // the cross-fade into the editor
    }
    await tester.tap(find.text('Score'));
    await tester.pump();
    await tester.tap(item());
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(find.text('Staff transition'), findsOneWidget);
    expect(find.text('Engraving'), findsNothing, reason: 'the first page, not Advanced');
    await tester.tap(find.byTooltip('Close'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }

    await tester.tap(find.text('File'));
    await tester.pump();
    expect(item(), findsNothing, reason: 'Project Settings… is in the Score menu only');
    await tester.tap(find.widgetWithText(MenuItemButton, 'Settings…'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(find.text('Appearance'), findsOneWidget, reason: "the app's settings");
  });

  testWidgets('Export Video is greyed out in the menu while the score is engraved again, as the toolbar button is', (tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const CuratedScoreApp());
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScore.path));
    await tester.pump();
    AppMenus menus() => tester.widget<AppMenus>(find.byType(AppMenus));
    expect(menus().onExportVideo, isNotNull);

    // Started in real time, so the engraving runs on.
    await tester.runAsync(() {
      c.engravingOptions = const EngravingOptions().withValue(EngraveOption.byKey('spacingLinear')!, 0.9);
      return Future<void>.value();
    });
    await tester.pump();
    expect(c.isReengraving, isTrue);
    expect(menus().onExportVideo, isNull);
    await tester.runAsync(() async {
      while (c.isReengraving) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(menus().onExportVideo, isNotNull);
  });
}

