import 'dart:math';

import 'package:curated_score/app_colors.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_project.dart';

void main() {
  testWidgets('an appearance change switches the theme at once, under a still of the window that fades out', (tester) async {
    tester.view.physicalSize = const Size(2000, 1400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final settings = AppSettings.memory();
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    await tester.pumpAndSettle();
    ThemeData theme() => Theme.of(tester.element(find.byType(HomePage)));
    final images = find.byType(RawImage).evaluate().length;

    settings.themeMode = ThemeMode.dark;
    await tester.pump();
    expect(theme().brightness, Brightness.dark);
    expect(find.byType(RawImage), findsNWidgets(images + 1), reason: 'the window as it was, over it');

    // The theme isn't lerped: halfway through the fade it is already the dark one.
    final dark = theme();
    await tester.pump(const Duration(milliseconds: 140));
    expect(theme(), dark);
    expect(find.byType(RawImage), findsNWidgets(images + 1));
    await tester.pumpAndSettle();
    expect(find.byType(RawImage), findsNWidgets(images));

    settings.accent = AccentColor.rose;
    await tester.pump();
    expect(find.byType(RawImage), findsNWidgets(images + 1), reason: 'an accent cross-fades too');
    await tester.pumpAndSettle();

    expect(theme().extension<AppStyle>()!.style, UiStyle.refined, reason: 'the default');
    expect(theme().splashFactory, NoSplash.splashFactory, reason: 'a press tints, no ripple');
    settings.uiStyle = UiStyle.classic;
    await tester.pump();
    expect(find.byType(RawImage), findsNWidgets(images + 1), reason: 'a style cross-fades too');
    expect(theme().extension<AppStyle>()!.style, UiStyle.classic);
    expect(theme().splashFactory, InkSparkle.splashFactory, reason: 'Material, as it was');
    await tester.pumpAndSettle();

    final before = theme();
    settings.undoSteps = AppSettings.undoStepChoices.last;
    await tester.pump();
    expect(find.byType(RawImage), findsNWidgets(images), reason: 'other settings leave the window be');
    expect(theme(), same(before), reason: 'the same theme, so nothing that reads it rebuilds');
  });

  testWidgets('a setting the page doesn\'t show (a slider in Settings, dragged) rebuilds nothing', (tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final settings = AppSettings.memory();
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScore.path));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    final scaffold = find.byType(Scaffold).first;
    final built = tester.widget(scaffold);
    for (final follow in [0.1, 0.5, 0.9]) {
      settings.scrollFollow = follow;
      await tester.pump();
    }
    expect(tester.widget(scaffold), same(built));
    settings.previewVideoFrame = !settings.previewVideoFrame; // one it shows does
    await tester.pump();
    expect(tester.widget(scaffold), isNot(same(built)));
  });

  testWidgets("a widget's own colour animations take the new theme at once, under the window's cross-fade", (tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final settings = AppSettings.memory()..themeMode = ThemeMode.light;
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScore.path));
    await tester.pumpAndSettle();
    // The divider above the timeline: an AnimatedContainer in the chrome colour.
    final handle = find.descendant(
        of: find.byWidgetPredicate((w) => w.runtimeType.toString() == '_ResizeHandle'), matching: find.byType(DecoratedBox));
    Color? color() => (tester.widget<DecoratedBox>(handle.first).decoration as BoxDecoration).color;
    expect(color(), AppColors.of(settings.accent, Brightness.light, settings.uiStyle).chrome);

    settings.themeMode = ThemeMode.dark;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(color(), AppColors.of(settings.accent, Brightness.dark, settings.uiStyle).chrome);
    await tester.pumpAndSettle();
  });

  test("a solid accent is its swatch's colour in Settings ▸ Appearance, its text readable on it", () {
    double contrast(Color a, Color b) {
      final (x, y) = (a.computeLuminance(), b.computeLuminance());
      return (max(x, y) + 0.05) / (min(x, y) + 0.05);
    }

    for (final accent in AccentColor.values) {
      for (final brightness in Brightness.values) {
        for (final style in UiStyle.values) {
          final c = AppColors.of(accent, brightness, style);
          expect(c.accentFill, accent.shade(brightness), reason: '$accent $brightness $style');
          expect(contrast(c.onAccentFill, c.accentFill), greaterThanOrEqualTo(3), reason: '$accent $brightness');
        }
      }
      final filled = AppColors.theme(accent: accent).filledButtonTheme.style!;
      expect(filled.backgroundColor!.resolve({}), accent.shade(Brightness.light));
    }
  });

  test('Refined: a held-down button is a clear grey, a step past hovered, and a selected one its accent', () {
    for (final brightness in Brightness.values) {
      final theme = AppColors.theme(brightness: brightness);
      final c = theme.extension<AppColors>()!;
      expect(c.pressTint.a, greaterThanOrEqualTo(c.hoverTint.a * 3), reason: '$brightness');
      for (final style in [
        theme.textButtonTheme.style!,
        theme.outlinedButtonTheme.style!,
        theme.iconButtonTheme.style!,
        theme.segmentedButtonTheme.style!,
      ]) {
        expect(style.overlayColor!.resolve({WidgetState.pressed}), c.pressTint);
        expect(style.overlayColor!.resolve({WidgetState.hovered}), c.hoverTint);
      }
      expect(theme.highlightColor, c.pressTint, reason: 'an InkWell held down');
      expect(c.selectedTint.withValues(alpha: 1), c.accentFill, reason: "selected: the swatch's colour, not grey");
    }
  });

  test('Refined sets a desktop theme over Classic, which stays Material as it was', () {
    for (final brightness in Brightness.values) {
      final refined = AppColors.theme(brightness: brightness);
      final classic = AppColors.theme(brightness: brightness, style: UiStyle.classic);
      expect(refined.textTheme.bodyMedium!.letterSpacing, 0);
      expect(classic.textTheme.bodyMedium!.letterSpacing, isNot(0));
      expect(refined.materialTapTargetSize, MaterialTapTargetSize.shrinkWrap);
      expect(classic.materialTapTargetSize, MaterialTapTargetSize.padded);
      expect(refined.sliderTheme.overlayColor, Colors.transparent, reason: 'no halo');
      expect(classic.sliderTheme.overlayColor, isNull);
      expect(refined.filledButtonTheme.style!.shape!.resolve({}), isA<RoundedRectangleBorder>());
      expect(classic.filledButtonTheme.style, isNull);
      expect(refined.inputDecorationTheme.isDense, isTrue);
      final r = refined.extension<AppColors>()!, cl = classic.extension<AppColors>()!;
      expect(r.chrome, isNot(r.surface), reason: 'toolbars a step off the work area');
      expect(cl.chrome, cl.surface);
      expect(r.line, AppColors.of(AccentColor.rose, brightness, UiStyle.refined).line, reason: 'greys without the accent');
      expect(cl.line, isNot(AppColors.of(AccentColor.rose, brightness).line));
      expect(classic.inputDecorationTheme.isDense, isFalse);
    }
  });
}
