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
    // The divider above the timeline: an AnimatedContainer in the surface colour.
    final handle = find.descendant(
        of: find.byWidgetPredicate((w) => w.runtimeType.toString() == '_ResizeHandle'), matching: find.byType(DecoratedBox));
    Color? color() => (tester.widget<DecoratedBox>(handle.first).decoration as BoxDecoration).color;
    expect(color(), AppColors.of(settings.accent, Brightness.light).surface);

    settings.themeMode = ThemeMode.dark;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(color(), AppColors.of(settings.accent, Brightness.dark).surface);
    await tester.pumpAndSettle();
  });
}

