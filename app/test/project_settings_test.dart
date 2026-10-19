// Drives File ▸ Project Settings… with real taps: its fonts and Undo through font
// changes, the staff transition, and the project's own engraving options; its Sections page.
// With SCREENSHOT_DIR set, also saves PNGs of the Fonts and Sections pages for visual review.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/menu_kit.dart';
import 'package:curated_score/sections_editor.dart';
import 'package:curated_score/settings_dialog.dart';
import 'package:curated_score/ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';
import 'test_fonts.dart';
import 'window.dart';

void main() {
  testWidgets('Project Settings ▸ Engraving: the fonts engrave the score in another music and text font, each an Undo step',
      (tester) async {
    desktopWindow(tester);
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
    unawaited(showProjectSettingsDialog(tester.element(find.byType(HomePage)), settings, c, page: 'Engraving'));
    await tester.runAsync(TextFonts.installed); // read on another isolate
    await settle();
    expect(find.text('Music font'), findsOneWidget);
    expect(find.text('Caption font'), findsNothing, reason: 'Captions is off');

    // Music: Leland, from the list.
    await tester.tap(find.byType(AppDropdown<String>).first);
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
    expect(c.projectState.edits.fonts, c.fonts);
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

    // Save as default: the fonts for new projects.
    await tester.scrollUntilVisible(find.text('Save'), 300,
        scrollable: find.descendant(of: find.byType(ListView).last, matching: find.byType(Scrollable)).first);
    await settle();
    await tester.tap(find.text('Save'));
    await settle();
    expect(settings.musicFont, MusicFont.leland.name);
    expect(find.text('Same as default.'), findsOneWidget);

    await tester.tap(find.byTooltip('Close'));
    await settle();
    expect(find.text('Music font'), findsNothing);
  });

  testWidgets('Project Settings ▸ Sections: a bracket dragged over another instrument, shown as it moves; two selected bracketed; each an Undo step',
      (tester) async {
    desktopWindow(tester);
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

    unawaited(showProjectSettingsDialog(tester.element(find.byType(HomePage)), settings, c, page: 'Sections'));
    await settle();
    await tester.tap(find.byType(AppSwitch).first); // Group sections, the project's
    await settle();
    expect((c.groupSections, c.scene!.sections, c.projectState.edits.groupSections), (true, true, true));

    // Rows 36 points high, staves 16 points high in their middle; brackets left of the staves at 174.
    final paint = find.descendant(of: find.byType(SectionsEditor), matching: find.byType(CustomPaint)).last;
    Offset at(double x, int row, {double dy = 18}) => tester.getTopLeft(paint) + Offset(x, row * 36 + dy);
    final list = tester.state<ScrollableState>(find.ancestor(of: paint, matching: find.byType(Scrollable)).first).position;
    Future<void> scrollTo(int row) async {
      list.jumpTo(math.min(row * 36.0, list.maxScrollExtent));
      await settle();
    }
    final parts = c.score!.metadata.parts;
    final horn = parts.firstWhere((p) => p.id == 'P10');
    expect(c.sectionOf(horn), 'brass');

    // The woodwinds' bracket ends at Bassoon 2 (row 8): its end dragged down over Horn 1.
    await scrollTo(6);
    final drag = await tester.startGesture(at(162, 8, dy: 28));
    await drag.moveBy(const Offset(0, 20));
    await tester.pump();
    await drag.moveBy(const Offset(0, 20));
    await tester.pump();
    expect(c.scene!.sectionOverrides, {'P10': 'woodwinds'}, reason: 'the score shows it while it moves');
    expect(c.sectionOf(horn), 'brass', reason: 'not an edit yet');
    await drag.up();
    await settle();
    expect(c.sectionOf(horn), 'woodwinds');

    // The trumpets (rows 11 and 12) selected and bracketed on their own.
    await scrollTo(10);
    await tester.tapAt(at(60, 11));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tapAt(at(60, 12));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await settle();
    await tester.tap(find.text('Bracket'));
    await settle();
    expect(c.scene!.sectionOverrides, {'P10': 'woodwinds', 'P12': 'bracket-1', 'P13': 'bracket-1'});
    final dir = Platform.environment['SCREENSHOT_DIR'];
    if (dir != null) {
      await tester.runAsync(loadTestFonts);
      await scrollTo(4);
      await tester.runAsync(() async {
        final view = tester.binding.renderViews.first;
        final image = await (view.debugLayer! as OffsetLayer).toImage(Offset.zero & tester.view.physicalSize);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/project-settings-sections.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    // Horn 2 (row 10), alone, bracketed on its own.
    await tester.tapAt(at(60, 10));
    await settle();
    await tester.tap(find.text('Bracket'));
    await settle();
    expect(c.scene!.sectionOverrides['P11'], 'bracket-2');
    c.undo();

    c.undo();
    expect(c.scene!.sectionOverrides, {'P10': 'woodwinds'});
    await tester.tap(find.text('Reset'));
    await settle();
    expect(c.scene!.sectionOverrides, isEmpty);
    c.undo();
    expect(c.sectionOf(horn), 'woodwinds');
  });
}
