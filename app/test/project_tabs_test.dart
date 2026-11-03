// Projects in tabs: Home is a tab of its own, so a project stays open while Home shows; another
// project opens beside it; Close takes only the tab it is in, asking first about unsaved changes.
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/editor_toolbar.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/project_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_project.dart';
import 'test_fonts.dart';
import 'window.dart';

void main() {
  testWidgets('projects open in tabs beside Home, which leaves them open', (tester) async {
    await tester.runAsync(loadTestFonts);
    desktopWindow(tester);
    final settings = AppSettings.memory()..addRecent(demoProject.absolute.path);
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ProjectTabs), findsNothing, reason: 'Home alone has no tabs');

    final pages = find.byType(ProjectPage, skipOffstage: false);
    List<EditorController> controllers() =>
        [for (final e in pages.evaluate()) ((e as StatefulElement).state as dynamic).controller as EditorController];
    Future<void> settle() async {
      for (var i = 0; i < 100 && controllers().any((c) => c.score == null || c.isLoading); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
      }
      // A closed tab's document lets go, then its page goes.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    Future<void> keys(LogicalKeyboardKey key, {bool shift = false}) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(key);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle();
    }

    final homeShows = find.text('Open Sample');
    final homeTab = find.descendant(of: find.byType(ProjectTabs), matching: find.byType(Icon)).first;

    await tester.tap(homeShows);
    await tester.pump();
    await settle();
    expect(pages, findsOneWidget);
    final sample = controllers().single;
    expect(sample.score, isNotNull);
    expect(find.byType(ProjectTabs), findsOneWidget);
    expect(homeShows, findsNothing);

    // Home's tab shows Home; the sample stays open behind it, and opening it again shows its
    // tab rather than another.
    await tester.tap(homeTab);
    await settle();
    expect(homeShows, findsOneWidget);
    expect(sample.score, isNotNull);
    await tester.tap(homeShows);
    await settle();
    expect(pages, findsOneWidget);
    expect(homeShows, findsNothing);

    // A second project from Home's tab: the recent demo, beside the sample, which stops playing.
    sample.playback.play();
    await tester.tap(homeTab);
    await settle();
    expect(sample.playback.isPlaying, isFalse, reason: 'heard only while its tab shows');
    await tester.tap(find.text(demoProject.uri.pathSegments.last));
    await tester.pump();
    await settle();
    expect(pages, findsNWidgets(2));
    final demo = controllers().last;
    expect(demo, isNot(same(sample)));
    expect(demo.score, isNotNull);

    // An unsaved change: Close asks first, and takes only its own tab; the one before shows.
    demo.setColorNames(!demo.colorNames);
    await settle();
    await keys(LogicalKeyboardKey.keyW);
    expect(find.text('Don’t Save'), findsOneWidget);
    await tester.tap(find.text('Don’t Save'));
    await settle();
    expect(pages, findsOneWidget);
    expect(sample.score, isNotNull);
    expect(find.byType(EditorToolbar), findsOneWidget);

    // ⌃Tab goes round the tabs, Home among them.
    await keys(LogicalKeyboardKey.tab);
    expect(homeShows, findsOneWidget);
    await keys(LogicalKeyboardKey.tab);
    expect(homeShows, findsNothing);
    await keys(LogicalKeyboardKey.tab, shift: true);
    expect(homeShows, findsOneWidget);

    // The last tab closed by its ×: Home alone again.
    await keys(LogicalKeyboardKey.tab);
    await tester.tap(find.descendant(of: find.byType(ProjectTabs), matching: find.byType(IconButton)));
    await settle();
    expect(pages, findsNothing);
    expect(find.byType(ProjectTabs), findsNothing);
    expect(homeShows, findsOneWidget);
  });
}
