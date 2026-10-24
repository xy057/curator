// Project Settings ▸ Advanced Engraving with a score open: every other engraving option by plain
// name, the score engraved again after each change; and Hide Preview on every engraving page.
// With SCREENSHOT_DIR set, saves PNGs.
import 'dart:async';

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/engraving_settings.dart';
import 'package:curated_score/settings_dialog.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/motion_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';
import 'test_fonts.dart';
import 'window.dart';

void main() {
  testWidgets('Advanced Engraving re-engraves the score; each engraving page hides its preview', (tester) async {
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

    // Every option is on one page or the other, once.
    final keys = [for (final s in [...EngravingSetting.all, ...EngravingSetting.advanced]) s.key];
    expect(keys..sort(), [for (final o in EngraveOption.all) o.key]..sort());

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

    unawaited(showProjectSettingsDialog(tester.element(find.byType(HomePage)), settings, c, page: 'Advanced Engraving'));
    await settle();
    final preview = find.byType(EngravingPreview);
    expect(preview, findsOneWidget);
    CustomPainter painter() => tester
        .widgetList<CustomPaint>(find.descendant(of: preview, matching: find.byType(CustomPaint)))
        .map((p) => p.painter)
        .firstWhere((p) => p.runtimeType.toString() == '_PreviewPainter')!;
    final before = painter();
    final width = c.score!.engraving.width;
    expect(find.text('Notes and rests'), findsOneWidget);
    await screenshot(tester, 'advanced-engraving', inside: preview, outermost: true, pixelRatio: 1);

    // Found by its code name too; a slider, set when let go, and Reset after.
    await tester.enterText(find.widgetWithText(TextField, 'Search'), 'leftMarginNote');
    await settle();
    expect(find.text('Notes · Space before'), findsOneWidget);
    expect(find.byTooltip('Reset'), findsNothing);
    await tester.drag(find.byType(Slider).last, const Offset(120, 0)); // not the editor's, behind
    await tester.pump();
    expect(c.isReengraving, isTrue);
    await engraved();
    expect(c.score!.engraving.width, greaterThan(width));
    expect(c.projectEngraving.valueOf(EngraveOption.byKey('leftMarginNote')!), greaterThan(1));
    expect(find.byTooltip('Reset'), findsOneWidget);

    // Its number typed over: set on Return, kept in range; Escape puts it back.
    final margin = EngraveOption.byKey('leftMarginNote')!;
    final field = find.descendant(of: find.byType(SliderValueField), matching: find.byType(TextField));
    Future<void> type(String text, {bool escape = false}) async {
      await tester.enterText(field, text);
      if (escape) {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      } else {
        await tester.testTextInput.receiveAction(TextInputAction.done);
      }
      await tester.pump();
      await engraved();
    }

    await type('1.25');
    expect(c.projectEngraving.valueOf(margin), 1.25);
    expect(find.descendant(of: field, matching: find.text('1.25')), findsOneWidget);
    await type('999');
    expect(c.projectEngraving.valueOf(margin), margin.max);
    await type('1', escape: true);
    expect(c.projectEngraving.valueOf(margin), margin.max);
    expect(find.text('Notes · Space before'), findsOneWidget, reason: 'Escape leaves the field, not the window');

    // A choice is a menu, by name.
    await tester.enterText(find.widgetWithText(TextField, 'Search'), 'multiRestStyle');
    await settle();
    expect(find.text('Automatic'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Search'), '');
    await settle();
    expect(painter().shouldRepaint(before), isTrue, reason: 'the preview draws the new engraving');

    // Hidden on one engraving page, hidden on all, and remembered; shown again likewise.
    await tester.tap(find.byTooltip('Hide Preview'));
    await settle();
    expect(preview, findsNothing);
    expect(settings.engravingPreview, isFalse);
    for (final page in ['Engraving', 'Typography']) {
      await tester.tap(find.text(page).first);
      await settle();
      expect(preview, findsNothing, reason: page);
      expect(find.byTooltip('Show Preview'), findsOneWidget, reason: page);
    }
    // A percent typed as one.
    await tester.enterText(field.first, '150');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle();
    expect(find.descendant(of: field.first, matching: find.text('150%')), findsOneWidget);
    await screenshot(tester, 'typography-no-preview', inside: find.byTooltip('Show Preview'), outermost: true, pixelRatio: 1);
    await tester.tap(find.byTooltip('Show Preview'));
    await settle();
    expect(preview, findsOneWidget);
    expect(settings.engravingPreview, isTrue);
    await tester.tap(find.text('Animation').first);
    await settle();
    expect(find.byTooltip('Hide Preview'), findsNothing, reason: 'not an engraving page');
  });
}
