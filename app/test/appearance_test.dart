import 'dart:async';

import 'package:curated_score/app_colors.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/settings_dialog.dart';
import 'package:curated_score/ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_project.dart';
import 'window.dart';

void main() {
  testWidgets('a click on Theme chooses at once; the still it fades from holds no tint where it started', (tester) async {
    tester.view.physicalSize = const Size(2000, 1400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final settings = AppSettings.memory()..themeMode = ThemeMode.light;
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    await tester.pumpAndSettle();
    unawaited(showSettingsDialog(tester.element(find.byType(HomePage)), settings, page: 'Appearance'));
    await tester.pumpAndSettle();
    final segment = find.descendant(of: find.byType(AppSegmented<ThemeMode>), matching: find.byType(InkWell));
    final (auto, light) = (tester.getRect(segment.at(0)), tester.getRect(segment.at(1)));
    final images = find.byType(RawImage).evaluate().length;

    await tester.tap(find.text('Dark'));
    await tester.pump();
    expect(settings.themeMode, ThemeMode.dark, reason: 'at the click');
    final still = tester.widgetList<RawImage>(find.byType(RawImage)).elementAt(images).image!;
    final (onAuto, onLight) = (await tester.runAsync(() async {
      final data = (await still.toByteData())!;
      // At the view's 2× pixels, a little in from each segment's left edge: no label there.
      int at(Offset p) => data.getUint32(((p.dy * 2).floor() * still.width + (p.dx * 2).floor()) * 4);
      return (at(auto.centerLeft + const Offset(5, 0)), at(light.centerLeft + const Offset(5, 0)));
    }))!;
    expect(onAuto, onLight, reason: 'Auto, where the tint was, bare as Light is');
    await tester.pumpAndSettle();
  });

  testWidgets('a change of accent cross-fades the chosen segment\'s tint, as the rest of the window', (tester) async {
    tester.view.physicalSize = const Size(2000, 1400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final settings = AppSettings.memory()..themeMode = ThemeMode.light;
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    await tester.pumpAndSettle();
    unawaited(showSettingsDialog(tester.element(find.byType(HomePage)), settings, page: 'Appearance'));
    await tester.pumpAndSettle();
    final segment = find.descendant(of: find.byType(AppSegmented<ThemeMode>), matching: find.byType(InkWell));
    final (auto, light) = (tester.getRect(segment.at(0)), tester.getRect(segment.at(1)));
    final images = find.byType(RawImage).evaluate().length;

    await tester.tap(find.byTooltip('Rose'));
    await tester.pump();
    expect(settings.accent, AccentColor.rose);
    final still = tester.widgetList<RawImage>(find.byType(RawImage)).elementAt(images).image!;
    final (onAuto, onLight) = (await tester.runAsync(() async {
      final data = (await still.toByteData())!;
      int at(Offset p) => data.getUint32(((p.dy * 2).floor() * still.width + (p.dx * 2).floor()) * 4);
      return (at(auto.centerLeft + const Offset(5, 0)), at(light.centerLeft + const Offset(5, 0)));
    }))!;
    expect(onLight, isNot(onAuto), reason: 'Light, chosen, keeps its tint in the still: it fades from the old accent, not from nothing');
    await tester.pumpAndSettle();
  });

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
    settings.uiStyle = UiStyle.carbon;
    await tester.pump();
    expect(find.byType(RawImage), findsNWidgets(images + 1), reason: 'a style cross-fades too');
    expect(theme().extension<AppStyle>()!.style, UiStyle.carbon);
    expect(theme().extension<CarbonColors>(), isNotNull);
    expect(theme().splashFactory, NoSplash.splashFactory, reason: 'Carbon shows state by fills, not ripples');
    await tester.pumpAndSettle();

    final before = theme();
    settings.undoSteps = AppSettings.undoStepChoices.last;
    await tester.pump();
    expect(find.byType(RawImage), findsNWidgets(images), reason: 'other settings leave the window be');
    expect(theme(), same(before), reason: 'the same theme, so nothing that reads it rebuilds');
  });

  testWidgets('a setting the page doesn\'t show (a slider in Settings, dragged) rebuilds nothing', (tester) async {
    desktopWindow(tester);
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
    desktopWindow(tester);
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

  test('Refined sets a desktop theme over Material', () {
    for (final brightness in Brightness.values) {
      final refined = AppColors.theme(brightness: brightness);
      expect(refined.textTheme.bodyMedium!.letterSpacing, 0);
      expect(refined.materialTapTargetSize, MaterialTapTargetSize.shrinkWrap);
      expect(refined.sliderTheme.overlayColor, Colors.transparent, reason: 'no halo');
      expect(refined.filledButtonTheme.style!.shape!.resolve({}), isA<RoundedRectangleBorder>());
      expect(refined.inputDecorationTheme.isDense, isTrue);
      final r = refined.extension<AppColors>()!;
      expect(r.chrome, isNot(r.surface), reason: 'toolbars a step off the work area');
      expect(r.line, AppColors.of(AccentColor.rose, brightness, UiStyle.refined).line, reason: 'greys without the accent');
    }
  });

  test("Carbon sets IBM's tokens: White or Gray 100, Plex, square sm buttons, filled fields", () {
    for (final (brightness, background, layer, text) in [
      (Brightness.light, const Color(0xFFFFFFFF), const Color(0xFFF4F4F4), const Color(0xFF161616)),
      (Brightness.dark, const Color(0xFF161616), const Color(0xFF262626), const Color(0xFFF4F4F4)),
    ]) {
      final carbon = AppColors.theme(brightness: brightness, style: UiStyle.carbon);
      final c = carbon.extension<AppColors>()!;
      expect(c.surface, background, reason: r'$background');
      expect(c.chrome, layer, reason: r'$layer-01');
      expect(c.text, text, reason: r'$text-primary');
      expect(c.accentFill, const Color(0xFF0F62FE), reason: r'$button-primary, Blue 60, in both');
      expect(carbon.textTheme.bodyMedium!.fontFamily, AppColors.carbonFont);
      expect(carbon.textTheme.bodyMedium!.fontSize, 14, reason: 'body-compact-01');
      expect(carbon.textTheme.bodyMedium!.letterSpacing, 0.16);
      expect(carbon.textTheme.bodySmall!.fontSize, 12, reason: 'label-01');
      final button = carbon.filledButtonTheme.style!;
      expect(button.shape!.resolve({}), const RoundedRectangleBorder(), reason: 'square');
      expect(button.shape!.resolve({WidgetState.focused}), isA<CarbonFocusBorder>());
      expect(button.minimumSize!.resolve({})!.height, 32, reason: 'sm');
      expect(button.alignment, Alignment.centerLeft, reason: 'its label at the left');
      expect(button.backgroundColor!.resolve({WidgetState.hovered}), const Color(0xFF0050E6), reason: r'$button-primary-hover');
      expect(carbon.dialogTheme.shape, const RoundedRectangleBorder());
      expect(carbon.dialogTheme.backgroundColor, layer, reason: r'a modal on $layer-01');
      expect(carbon.inputDecorationTheme.filled, isTrue);
      expect(carbon.inputDecorationTheme.border, isA<UnderlineInputBorder>());
      expect(carbon.checkboxTheme.fillColor!.resolve({WidgetState.selected}), text, reason: r'$icon-primary, not the accent');
      expect(carbon.sliderTheme.trackHeight, 2);
      expect(carbon.extension<AppStyle>()!.radius(8), BorderRadius.zero);
    }
    expect(AppColors.of(AccentColor.rose, Brightness.light, UiStyle.carbon).accent, const Color(0xFFD02670), reason: 'Magenta 60');
  });

  test('a saved Classic style, which is gone, opens as Refined', () {
    expect(UiStyle.named('classic'), UiStyle.refined);
    expect(UiStyle.named('refined'), UiStyle.refined);
    expect(UiStyle.named('carbon'), UiStyle.carbon);
    expect(UiStyle.named(null), isNull);
  });
}
