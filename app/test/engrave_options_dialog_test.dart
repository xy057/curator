// Settings ▸ Engraving ▸ Engraving options with a score open: the preview beside the list shows
// the score engraved again after each change. With SCREENSHOT_DIR set, saves PNGs.
import 'dart:async';

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/engrave_options_dialog.dart';
import 'package:curated_score/engraving_settings.dart';
import 'package:curated_score/settings_dialog.dart';
import 'package:curated_score/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';
import 'test_fonts.dart';
import 'window.dart';

void main() {
  testWidgets('the preview shows the open score, engraved again with each change', (tester) async {
    if (screenshotDir != null) await tester.runAsync(loadTestFonts);
    desktopWindow(tester);
    final settings = AppSettings.memory();
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    final state = tester.state(find.byType(HomePage)) as dynamic;
    final c = state.controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScore.path));
    await tester.pump();
    c.playback.time.value = 20; // somewhere with music on every staff
    await tester.pump();

    // Not pumpAndSettle: the editor always has something ticking.
    Future<void> settle() async {
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
    }

    Future<void> engraved() async {
      while (c.isReengraving) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      await settle();
    }

    unawaited(showEngraveOptionsDialog(tester.element(find.byType(HomePage)), settings, controller: c));
    await settle();
    final preview = find.descendant(of: find.byType(Dialog), matching: find.byType(Slider));
    expect(preview, findsOneWidget, reason: 'a preview, scrubbed with its own slider');
    CustomPainter painter() => tester
        .widgetList<CustomPaint>(find.descendant(of: find.byType(Dialog), matching: find.byType(CustomPaint)))
        .map((p) => p.painter)
        .firstWhere((p) => p.runtimeType.toString() == '_PreviewPainter')!;
    final before = painter();
    final width = c.score!.engraving.width;
    await screenshot(tester, 'engrave-preview', inside: find.byType(Dialog), pixelRatio: 1);

    await tester.enterText(find.widgetWithText(TextField, 'Search').last, 'spacingLinear');
    await settle();
    await tester.enterText(find.descendant(of: find.byType(ListView).last, matching: find.byType(TextField)), '0.95');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(c.isReengraving, isTrue);
    await engraved();
    expect(c.score!.engraving.width, greaterThan(width));
    expect(painter().shouldRepaint(before), isTrue, reason: 'the preview draws the new engraving');
    await screenshot(tester, 'engrave-preview-changed', inside: find.byType(Dialog), pixelRatio: 1);

    // Scrubbing moves only the preview.
    await tester.drag(preview, const Offset(200, 0));
    await settle();
    expect(c.playback.time.value, 20);
    expect(settings.engravingOptions.valueOf(EngraveOption.byKey('spacingLinear')!), 0.95);
    Navigator.pop(tester.element(find.byType(Dialog)));
    await settle();

    // Settings ▸ Engraving shows the same preview above its sliders.
    unawaited(showSettingsDialog(tester.element(find.byType(HomePage)), settings, controller: c, page: 'Engraving'));
    await settle();
    final pagePreview = find.descendant(of: find.byType(EngravingPreview), matching: find.byType(CustomPaint));
    expect(pagePreview, findsWidgets);
    await screenshot(tester, 'settings-engraving-preview', inside: find.byType(EngravingPreview), outermost: true, pixelRatio: 1);
  });

  testWidgets('with nothing open, the Engraving page previews the demo, engraved with the app\'s options',
      (tester) async {
    if (screenshotDir != null) await tester.runAsync(loadTestFonts);
    desktopWindow(tester);
    final settings = AppSettings.memory();
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    expect(c.score, isNull);

    unawaited(showSettingsDialog(tester.element(find.byType(HomePage)), settings, controller: c, page: 'Engraving'));
    EditorController demo() => tester.widget<EngravingPreview>(find.byType(EngravingPreview)).controller;
    for (var i = 0; i < 200 && find.byType(EngravingPreview).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.byType(EngravingPreview), findsOneWidget, reason: 'the demo, engraved');
    expect(demo(), isNot(c));
    expect(c.score, isNull, reason: 'nothing opened in the window');
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 150)); // the window's fade
    }
    await screenshot(tester, 'settings-engraving-demo', inside: find.byType(EngravingPreview), outermost: true, pixelRatio: 1);

    final width = demo().score!.engraving.width;
    settings.engravingOptions = const EngravingOptions().withValue(EngraveOption.byKey('spacingLinear')!, 0.95);
    await tester.pump();
    while (demo().isReengraving) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(demo().score!.engraving.width, greaterThan(width));
    expect(demo().projectEngraving.isEmpty, isTrue, reason: "the app's options, not an edit");

    // A score opened meanwhile (the menu bar works) is previewed instead; closed, the demo again.
    await tester.runAsync(() => c.openFile(demoScore.path));
    await tester.pump();
    expect(demo(), c);
    await tester.runAsync(c.close);
    await tester.pump();
    for (var i = 0; i < 200 && (find.byType(EngravingPreview).evaluate().isEmpty || demo() == c); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(demo(), isNot(c), reason: 'the demo again');

    Navigator.pop(tester.element(find.byType(EngravingPreview)));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(find.byType(EngravingPreview), findsNothing);
  });
}
