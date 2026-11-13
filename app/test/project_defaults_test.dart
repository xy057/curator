// Project Settings: a page's Reset to Default goes back to the saved defaults; once those are
// other than the system's (the app's own), it asks which, each greyed out while the page is
// already so, and either is one Undo step that leaves the saved defaults as they are. With
// SCREENSHOT_DIR set, the button and its menu are saved as PNGs.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/engraving_settings.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/settings_dialog.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';
import 'test_fonts.dart';
import 'window.dart' show screenshotDir;

void main() {
  testWidgets('Reset to Default: the saved defaults, or once they differ, the system’s', (tester) async {
    tester.view
      ..physicalSize = const Size(2000, 1240)
      ..devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.runAsync(loadTestFonts);
    final settings = AppSettings.memory()..addRecent(demoProject.absolute.path);
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Open Sample'));
    await tester.pump(); // its tab
    final c = (tester.state(find.byType(ProjectPage)) as dynamic).controller as EditorController;
    // Engraving runs outside the fake clock: give it real time, then frames.
    Future<void> settle() async {
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    for (var i = 0; i < 100 && c.score == null; i++) {
      await settle();
    }
    expect(c.score, isNotNull);
    await settle();

    Future<void> open(String page) async {
      unawaited(showProjectSettingsDialog(tester.element(find.byType(ProjectPage)), settings, c, page: page));
      await settle();
    }

    Future<void> close() async {
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await settle();
    }

    // The whole window, the settings and a menu over it too: the outermost boundary over [inside].
    Future<void> shot(String name, Finder inside) async {
      final dir = screenshotDir;
      if (dir == null) return;
      RenderRepaintBoundary? whole;
      for (RenderObject? o = tester.renderObject(inside.first); o != null; o = o.parent) {
        if (o is RenderRepaintBoundary) whole = o;
      }
      await tester.runAsync(() async {
        final png = await (await whole!.toImage(pixelRatio: 1)).toByteData(format: ui.ImageByteFormat.png);
        File('$dir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    final reset = find.text('Reset to Default');
    bool offered(String which) =>
        tester.widget<PopupMenuItem<Object?>>(find.ancestor(of: find.text(which), matching: find.byWidgetPredicate((w) => w is PopupMenuItem))).enabled;
    // Reset to Default's menu: which of its two can be chosen; then [pick] chosen. [name] names
    // a screenshot of it open.
    Future<(bool, bool)> menu([String? pick, String? name]) async {
      await tester.tap(reset);
      await settle();
      if (name != null) await shot(name, find.text('System Default'));
      final choices = (offered('Saved Default'), offered('System Default'));
      if (pick != null) {
        await tester.tap(find.text(pick));
      } else {
        await tester.tapAt(Offset.zero); // shut, nothing chosen
      }
      await settle();
      return choices;
    }

    // Animation, nothing saved: the saved defaults are the system's, one button, no menu.
    final key = ScoreMotion.ranges.keys.first;
    final moved = ScoreMotion.standard.withValue(key, ScoreMotion.ranges[key]!.max);
    expect(moved, isNot(ScoreMotion.standard));
    c.setMotion(moved);
    await open('Animation');
    await shot('reset-plain', reset);
    await tester.tap(reset);
    await settle();
    expect(find.text('System Default'), findsNothing);
    expect(c.motion, ScoreMotion.standard);
    expect(reset, findsNothing, reason: 'the page is the default now');

    // Other defaults saved: the menu, Saved Default and System Default each while the page differs.
    c.setMotion(moved);
    await settle();
    await tester.tap(find.text('Save as Default'));
    await settle();
    expect(settings.motion, moved);
    expect(await menu(), (false, true));
    c.setMotion(ScoreMotion.standard.withValue(key, ScoreMotion.ranges[key]!.min));
    await settle();
    expect(await menu('Saved Default', 'reset-menu'), (true, true));
    expect(c.motion, moved);
    expect(await menu('System Default'), (false, true));
    expect((c.motion, settings.motion), (ScoreMotion.standard, moved), reason: 'the saved defaults kept');
    expect(reset, findsOneWidget, reason: 'the saved defaults still offered');
    c.undo();
    await settle();
    expect(c.motion, moved, reason: 'one Undo step');
    await close();

    // Display: the staff transition and the scroll.
    settings
      ..transition = 0.8
      ..scrollFollow = 0.9;
    c
      ..setTransition(0.8)
      ..setScrollFollow(0.9);
    await open('Display');
    expect(await menu('System Default'), (false, true));
    expect((c.curation!.transition, c.scrollFollow), (AppSettings.defaultTransition, AppSettings.defaultScrollFollow));
    await close();

    // Flags.
    settings
      ..textDynamics = false
      ..rehearsalInRow = false
      ..centeredLyrics = true;
    await tester.runAsync(() => c.setFlags(textDynamics: false, rehearsalInRow: false, centeredLyrics: true));
    await open('Flags');
    expect(await menu('System Default'), (false, true));
    expect((c.textDynamics, c.rehearsalInRow, c.centeredLyrics),
        (AppSettings.defaultTextDynamics, AppSettings.defaultRehearsalInRow, AppSettings.defaultCenteredLyrics));
    expect((settings.textDynamics, settings.rehearsalInRow, settings.centeredLyrics), (false, false, true));
    await close();

    // Engraving ▸ Typography.
    final size = '${TextKind.values.first.name}.size';
    final bigger = ScoreTypography.standard.withValue(size, 1.6);
    settings.typography = bigger;
    await tester.runAsync(() => c.setTypography(bigger));
    await open('Engraving');
    await tester.tap(find.text('Typography').last);
    await settle();
    expect(await menu('System Default'), (false, true));
    expect((c.typography, settings.typography), (ScoreTypography.standard, bigger));

    // Engraving ▸ Engraving: the fonts and every option back to the house style's, the saved
    // option set back over it.
    final toggle = EngraveOption.all.firstWhere((o) => o.kind == EngraveOptionKind.toggle);
    settings.engravingOptions = const EngravingOptions().withValue(toggle, !(toggle.defaultValue as bool));
    await tester.runAsync(() => c.setProjectEngraving(const EngravingOptions()));
    await tester.tap(find.text('Engraving').last);
    await settle();
    final target = EngravingTarget(settings, c);
    expect(target.valueOf(toggle), !(toggle.defaultValue as bool), reason: 'the saved option, the project setting none');
    expect((await menu('System Default', 'reset-menu-engraving')).$2, isTrue);
    expect(target.valueOf(toggle), toggle.defaultValue);
    expect((c.fonts.music.name, c.fonts.text, c.embedFont), (ScoreFonts.standard.music.name, ScoreFonts.standard.text, true));
    expect(settings.engravingOptions.isChanged(toggle), isTrue);
    await close();
  });
}
