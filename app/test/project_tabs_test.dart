// Projects in tabs: Home is a tab of its own, so a project stays open while Home shows; another
// project opens beside it; Close takes only the tab it is in, asking first about unsaved changes.
import 'dart:ui' as ui;

import 'package:curated_score/app_colors.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/editor_toolbar.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/project_tabs.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

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
    // The strip, as tall as it shows (it folds away, kept in the tree).
    double bar() => tester.getSize(find.ancestor(of: find.byType(ProjectTabs), matching: find.byType(ClipRect)).first).height;
    expect(bar(), 0, reason: 'Home alone has no tabs');

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
    expect(bar(), greaterThan(0));
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

    // Hide Tab Bar (⇧⌘T): the toolbar has a button that shows it again; so does Show All Tabs (⇧⌘\).
    await keys(LogicalKeyboardKey.tab);
    final showBar = find.descendant(of: find.byType(EditorToolbar), matching: find.byTooltip('Show tab bar (Ctrl+Shift+T)'));
    expect(showBar, findsNothing);
    await keys(LogicalKeyboardKey.keyT, shift: true);
    expect(settings.tabBar, isFalse);
    expect(bar(), 0);
    await tester.tap(showBar);
    await settle();
    expect(settings.tabBar, isTrue);
    expect(bar(), greaterThan(0));
    expect(showBar, findsNothing);
    expect(sample.score, isNotNull);
    await keys(LogicalKeyboardKey.keyT, shift: true);
    expect(bar(), 0);
    await keys(LogicalKeyboardKey.backslash, shift: true);
    expect(settings.tabBar, isTrue);
    expect(bar(), greaterThan(0));

    // The last tab closed by its ×: Home alone again.
    await tester.tap(find.descendant(of: find.byType(ProjectTabs), matching: find.byType(IconButton)));
    await settle();
    expect(pages, findsNothing);
    expect(bar(), 0);
    expect(homeShows, findsOneWidget);
  });

  // Its place once left empty as it shrank: the window's black backing showed through.
  testWidgets('hiding and showing the tab bar paints every pixel of every frame', (tester) async {
    await tester.runAsync(loadTestFonts);
    desktopWindow(tester);
    final settings = AppSettings.memory();
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Open Sample'));
    await tester.pump();
    final c = (tester.state(find.byType(ProjectPage)) as dynamic).controller as EditorController;
    for (var i = 0; i < 100 && c.score == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await tester.pump(const Duration(seconds: 1));
    Future<int> unpainted() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.ancestor(of: find.byType(ProjectPage), matching: find.byType(RepaintBoundary)).last);
      return (await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        var n = 0;
        for (var y = 0; y < 120; y++) {
          for (var x = 0; x < image.width; x += 4) {
            if (bytes.getUint8((y * image.width + x) * 4 + 3) < 250) n++;
          }
        }
        return n;
      }))!;
    }

    final counts = <String>[];
    for (final on in [false, true]) {
      settings.tabBar = on;
      for (var f = 0; f < 16; f++) {
        await tester.pump(const Duration(milliseconds: 16));
        counts.add('${on ? 'show' : 'hide'} $f: ${await unpainted()}');
      }
    }
    expect(counts.where((c) => !c.endsWith(': 0')), isEmpty, reason: 'unpainted pixels show the window\'s black');
  });

  testWidgets('a mouse wheel scrolls the tabs past the window\'s width', (tester) async {
    final labels = [
      for (var i = 0; i < 12; i++) ValueNotifier<ProjectTabLabel>((name: 'Project $i', edited: false, path: null)),
    ];
    await tester.pumpWidget(MaterialApp(
      theme: AppColors.theme(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 600,
            child: ProjectTabs(labels: labels, shown: 0, onShow: (_) {}, onClose: (_) {}),
          ),
        ),
      ),
    ));
    final position = tester.state<ScrollableState>(find.byType(Scrollable)).position;
    expect(position.maxScrollExtent, greaterThan(0));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(tester.getCenter(find.text('Project 1'))));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120))); // down: on to the right
    await tester.pump();
    expect(position.pixels, 120);
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -500))); // up, past the start
    await tester.pump();
    expect(position.pixels, 0);
  });
}
