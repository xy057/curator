// Drives Score ▸ Project Settings… with real taps: its Fonts page and Undo through font
// changes, the staff transition, and the project's own engraving options.
// With SCREENSHOT_DIR set, also saves a PNG of the Fonts page for visual review.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';
import 'test_fonts.dart';

void main() {
  testWidgets('Project Settings ▸ Fonts engraves the score in another music and text font, each an Undo step',
      (tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final settings = AppSettings.memory();
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    final state = tester.state(find.byType(HomePage)) as dynamic;
    final c = state.controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScore.path));
    await tester.pump();
    await tester.pump();
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
    }

    expect(c.fonts, ScoreFonts.standard);
    unawaited(showProjectSettingsDialog(tester.element(find.byType(HomePage)), settings, c, page: 'Fonts'));
    await tester.runAsync(TextFonts.installed); // read on another isolate
    await settle();
    expect(find.text('Music'), findsOneWidget);
    expect(find.text('Caption'), findsNothing, reason: 'Captions is off');

    // Music: Leland, from the list.
    await tester.tap(find.byType(DropdownMenu<String>).first);
    await settle();
    await tester.tap(find.text('Leland').last);
    await settle();
    await engraved();
    expect(c.fonts.music, MusicFont.leland);
    expect(c.score!.fonts.music, MusicFont.leland);
    expect(c.scene!.style.musicFontFamily, 'packages/score_engine/Leland');

    // Text: an installed family, typed into the filter.
    await tester.enterText(find.byType(DropdownMenu<String>).last, 'Helvet');
    await settle();
    await tester.tap(find.text('Helvetica').last);
    await settle();
    await engraved();
    expect(c.fonts, const ScoreFonts(music: MusicFont.leland, text: 'Helvetica'));
    expect(c.score!.textFontFamily, 'Curator text Helvetica');
    expect(c.projectState.fonts, c.fonts);
    final dir = Platform.environment['SCREENSHOT_DIR'];
    if (dir != null) {
      await tester.runAsync(loadTestFonts);
      c.setStaffSpace(6); // a new scene, drawn with the fonts just loaded
      await settle();
      await tester.runAsync(() async {
        // The whole window, the dialog included (its layer is in physical pixels).
        final view = tester.binding.renderViews.first;
        final image = await (view.debugLayer! as OffsetLayer).toImage(Offset.zero & tester.view.physicalSize);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/project-settings-fonts.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    // Each was its own Undo step.
    c.undo();
    await engraved();
    expect(c.fonts, const ScoreFonts(music: MusicFont.leland));
    c.undo();
    await engraved();
    expect(c.fonts, ScoreFonts.standard);
    expect(c.score!.fonts, ScoreFonts.standard);
    c.redo();
    await engraved();
    expect(c.score!.fonts.music, MusicFont.leland);

    await tester.tap(find.byTooltip('Close'));
    await settle();
    expect(find.text('Music'), findsNothing);
  });

  testWidgets("Project Settings sets the project's staff transition and engraving options, over the app's",
      (tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final settings = AppSettings.memory();
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScore.path));
    await tester.pump();
    await tester.pump();
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

    final spacing = EngraveOption.byKey('spacingLinear')!;
    settings.engravingOptions = const EngravingOptions().withValue(spacing, 0.9);
    await engraved();
    unawaited(showProjectSettingsDialog(tester.element(find.byType(HomePage)), settings, c, page: 'Animation'));
    await settle();
    expect(find.text(c.fileName!), findsOneWidget, reason: 'the project, under the pages');

    // The staff transition: the project's, not the app's default for new ones.
    final transition = c.curation!.transition;
    await tester.tap(find.text('$transition s'));
    await settle();
    await tester.tap(find.text('0.8 s').last);
    await settle();
    expect(c.curation!.transition, 0.8);
    expect(settings.transition, isNot(0.8));
    c.undo();
    await settle();
    expect(c.curation!.transition, transition);

    // Advanced ▸ Engraving: the project's own options, over the app's.
    await tester.tap(find.text('Advanced'));
    await settle();
    expect(find.text('Over the app’s.'), findsOneWidget);
    await tester.tap(find.text('Engrave Option'));
    await settle();
    await tester.tap(find.text('Continue'));
    await settle();
    final list = find.byType(ListView).last;
    await tester.enterText(find.widgetWithText(TextField, 'Search').last, 'spacingLinear');
    await settle();
    expect(find.descendant(of: list, matching: find.text('0.9')), findsOneWidget, reason: "the app's, until set here");
    await tester.enterText(find.descendant(of: list, matching: find.byType(TextField)), '0.7');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await engraved();
    expect(c.projectEngraving.valueOf(spacing), 0.7);
    expect(settings.engravingOptions.valueOf(spacing), 0.9, reason: "the app's stay as they were");
    expect(c.score!.options.valueOf(spacing), 0.7);

    // Reset: back to the app's, an Undo step.
    await tester.tap(find.byTooltip('Reset'));
    await tester.pump();
    await engraved();
    expect(c.projectEngraving.isEmpty, isTrue);
    expect(c.score!.options.valueOf(spacing), 0.9);
    c.undo();
    await engraved();
    expect(c.score!.options.valueOf(spacing), 0.7);
    await tester.tap(find.byTooltip('Close').last);
    await settle();
    expect(find.text('1 changed.'), findsOneWidget);

    // Closing the project closes its settings.
    await tester.runAsync(c.close);
    await settle();
    expect(find.text('1 changed.'), findsNothing);
  });
}
