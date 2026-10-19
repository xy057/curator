// Drives Score ▸ Project Settings… with real taps: its Fonts page and Undo through font
// changes, the staff transition, and the project's own engraving options; its Sections page.
// With SCREENSHOT_DIR set, also saves PNGs of the Fonts and Sections pages for visual review.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/menu_kit.dart';
import 'package:curated_score/settings_dialog.dart';
import 'package:curated_score/ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';
import 'test_fonts.dart';
import 'window.dart';

void main() {
  testWidgets('Project Settings ▸ Fonts engraves the score in another music and text font, each an Undo step',
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
    unawaited(showProjectSettingsDialog(tester.element(find.byType(HomePage)), settings, c, page: 'Fonts'));
    await tester.runAsync(TextFonts.installed); // read on another isolate
    await settle();
    expect(find.text('Music'), findsOneWidget);
    expect(find.text('Caption'), findsNothing, reason: 'Captions is off');

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

    await tester.tap(find.byTooltip('Close'));
    await settle();
    expect(find.text('Music'), findsNothing);
  });

  testWidgets('Project Settings ▸ Sections puts an instrument in another section, an Undo step; Reset gives its own back',
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

    final snare = c.score!.metadata.parts.firstWhere((p) => p.name == 'Snare Drum');
    expect(c.sectionOf(snare), isNull, reason: 'the file leaves it out of its brackets');
    unawaited(showProjectSettingsDialog(tester.element(find.byType(HomePage)), settings, c, page: 'Sections'));
    await settle();
    await tester.tap(find.byType(AppSwitch).first); // Group sections, the app's
    await settle();
    expect(settings.groupSections, isTrue);
    expect(c.scene!.sections, isTrue);

    final page = find.ancestor(of: find.byType(SettingsDropdown<String>).first, matching: find.byType(Scrollable)).first;
    final name = find.descendant(of: page, matching: find.text('Snare Drum')); // not its lane behind
    await tester.scrollUntilVisible(name, 200, scrollable: page);
    await settle();
    final row = find.ancestor(of: name, matching: find.byType(Row)).first;
    await tester.tap(find.descendant(of: row, matching: find.byType(SettingsDropdown<String>)));
    await settle();
    await tester.tap(find.text('Percussion').last);
    await settle();
    expect(c.sectionOf(snare), InstrumentFamily.percussion);
    expect(c.scene!.sectionOverrides, {snare.id: InstrumentFamily.percussion});
    final dir = Platform.environment['SCREENSHOT_DIR'];
    if (dir != null) {
      await tester.runAsync(loadTestFonts);
      await settle();
      await tester.runAsync(() async {
        final view = tester.binding.renderViews.first;
        final image = await (view.debugLayer! as OffsetLayer).toImage(Offset.zero & tester.view.physicalSize);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/project-settings-sections.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    await tester.tap(find.descendant(of: row, matching: find.byTooltip('Reset')));
    await settle();
    expect(c.sectionOf(snare), isNull);
    c.undo();
    expect(c.sectionOf(snare), InstrumentFamily.percussion);
    c.undo();
    expect(c.scene!.sectionOverrides, isEmpty);
  });
}
