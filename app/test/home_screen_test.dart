import 'package:curated_score/app_colors.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_project.dart';
import 'window.dart';

void main() {
  testWidgets('Recent files open from the home screen; missing ones say so', (tester) async {
    desktopWindow(tester);
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

    // A hover fades the row's wash in from none, never through grey (as from transparent black),
    // and repaints that row alone.
    final row = find.ancestor(of: find.text('WI275 - 01 Intro.musicxml').last, matching: find.byType(AnimatedContainer)).first;
    Color fill() => (tester.widget<DecoratedBox>(find.descendant(of: row, matching: find.byType(DecoratedBox)).first).decoration as BoxDecoration).color!;
    final wash = tester.element(row).colors.accentWash;
    final painted = <String>{};
    debugOnProfilePaint = (r) => r is RenderParagraph ? painted.add(r.text.toPlainText()) : null;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(row));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(fill().a, inExclusiveRange(0, 1));
    expect(fill().withValues(alpha: 1), isSameColorAs(wash));
    await tester.pumpAndSettle();
    debugOnProfilePaint = null;
    expect(fill(), wash);
    expect(painted, isNot(contains('Gone.ccs')));
    await mouse.removePointer();

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
