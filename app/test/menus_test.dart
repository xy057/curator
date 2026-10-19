// File ▸ Save / Save As… are always enabled: before a score is open, after one loads (the
// menu used to stay greyed out then, because it was never rebuilt), and with no changes.
import 'dart:async';

import 'package:curated_score/app_menus.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_project.dart';
import 'window.dart';

void main() {
  testWidgets('Edit greys out what has nothing to do', (tester) async {
    desktopWindow(tester);
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
    unawaited(showDialog<void>(context: tester.element(find.byType(HomePage)), builder: (_) => const Text('dialog')));
    await tester.pump();
    expect(menus().onUndo, isNull);
    expect(menus().onSelectAll, isNull);
  });
}
