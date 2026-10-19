import 'dart:io';
import 'dart:ui' as ui;

import 'package:curated_score/app_colors.dart';
import 'package:curated_score/app_extensions.dart';
import 'package:curated_score/app_icons.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/engraving_settings.dart';
import 'package:curated_score/settings_dialog.dart';
import 'package:curated_score/ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:curated_score/video_export.dart' show VideoResolution;
import 'package:score_engine/score_engine.dart' show CaptionCountdown, CaptionPosition, EngraveOption;
import 'package:shared_preferences/shared_preferences.dart';

import 'test_fonts.dart';

void main() {
  test('a video size no longer offered (4K, 8K) comes back as 1080p', () async {
    for (final gone in ['uhd2160', 'uhd4320']) {
      SharedPreferences.setMockInitialValues({'videoResolution': gone});
      expect((await AppSettings.load()).videoResolution, VideoResolution.hd1080, reason: gone);
    }
    SharedPreferences.setMockInitialValues({'videoResolution': 'qhd1440'});
    expect((await AppSettings.load()).videoResolution, VideoResolution.qhd1440);
  });

  test('the mascot icon is off until turned on, and is saved', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load();
    expect(settings.mascotIcon, isFalse);
    settings.mascotIcon = true;
    expect((await AppSettings.load()).mascotIcon, isTrue);
  });

  test('the Classic style, which is gone, opens as Refined and is saved so', () async {
    SharedPreferences.setMockInitialValues({'uiStyle': 'classic'});
    expect((await AppSettings.load()).uiStyle, UiStyle.refined);
    expect((await SharedPreferences.getInstance()).getString('uiStyle'), 'refined');
    SharedPreferences.setMockInitialValues({'uiStyle': 'carbon'});
    expect((await AppSettings.load()).uiStyle, UiStyle.carbon);
  });

  Future<AppSettings> open(WidgetTester tester) async {
    final settings = AppSettings.memory();
    if (Platform.environment['SCREENSHOT_DIR'] != null) await tester.runAsync(loadTestFonts);
    tester.view.physicalSize = const Size(2000, 1400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ListenableBuilder(
      listenable: settings,
      builder: (context, _) => MaterialApp(
        theme: AppColors.theme(accent: settings.accent),
        darkTheme: AppColors.theme(accent: settings.accent, brightness: Brightness.dark),
        themeMode: settings.themeMode,
        themeAnimationDuration: Duration.zero, // as the app: the window cross-fades over a still instead
        builder: (context, child) => RepaintBoundary(child: child),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(onPressed: () => showSettingsDialog(context, settings), child: const Text('open')),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return settings;
  }

  Future<void> shot(WidgetTester tester, String name) async {
    final dir = Platform.environment['SCREENSHOT_DIR'];
    if (dir == null) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byType(RepaintBoundary).first);
      final image = await boundary.toImage(pixelRatio: 2);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$dir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  testWidgets('settings are pages of items, picked from a sidebar', (tester) async {
    final settings = await open(tester);
    expect(find.text('Autosave'), findsOneWidget);
    await shot(tester, 'settings-general');

    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();
    expect(find.text('Autosave'), findsNothing);
    await tester.tap(find.text('Dark'));
    await tester.tap(find.byTooltip('Rose'));
    await tester.pumpAndSettle();
    expect(settings.themeMode, ThemeMode.dark);
    expect(settings.accent, AccentColor.rose);
    await shot(tester, 'settings-appearance-dark');
    await tester.tap(find.text('Carbon'));
    await tester.pumpAndSettle();
    expect(settings.uiStyle, UiStyle.carbon);
    await shot(tester, 'settings-appearance-carbon');
    await tester.tap(find.text('Refined'));
    await tester.pumpAndSettle();
    expect(settings.uiStyle, UiStyle.refined);

    await tester.tap(find.text('Animation'));
    await tester.pumpAndSettle();
    expect(find.text('Staff transition'), findsOneWidget);
    expect(find.text('For new projects.'), findsOneWidget, reason: "a project's own is in Project Settings");
    await tester.tap(find.text('0.3 s'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('0.8 s').last);
    await tester.pumpAndSettle();
    expect(settings.transition, 0.8);

    await tester.tap(find.text('Extensions'));
    await tester.pumpAndSettle();
    expect(find.text('Attach Image  1.0'), findsOneWidget, reason: 'its version after its name');
    expect(find.text(AppExtension.attachImage.summary), findsOneWidget);
    expect(find.text('Captions  1.0'), findsOneWidget);
    final gears = tester.widgetList<IconButton>(find.widgetWithIcon(IconButton, AppIcon.settings.refined)).toList();
    expect(gears.first.onPressed, isNull, reason: 'Attach Image has no settings of its own yet');
    expect(gears.last.onPressed, isNotNull, reason: 'Captions has');
    expect(settings.attachImage, isFalse, reason: 'extensions start off');
    expect(settings.captions, isFalse);
    await tester.tap(find.byType(AppSwitch).first);
    await tester.pumpAndSettle();
    expect(settings.attachImage, isTrue);
    expect(settings.captions, isFalse, reason: 'each its own switch');
    await shot(tester, 'settings-extension');

    // Captions' own settings: how captions look.
    await tester.tap(find.widgetWithIcon(IconButton, AppIcon.settings.refined).last);
    await tester.pumpAndSettle();
    expect(find.text('Countdown'), findsOneWidget);
    await tester.tap(find.text('Ring'));
    await tester.tap(find.text('Top'));
    await tester.pumpAndSettle();
    expect(settings.captionCountdown, CaptionCountdown.ring);
    expect(settings.captionPosition, CaptionPosition.top);
    await shot(tester, 'settings-captions');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
  });

  testWidgets('Flags: dynamics typed as text, on until switched off', (tester) async {
    final settings = await open(tester);
    await tester.tap(find.text('Flags'));
    await tester.pumpAndSettle();
    expect(find.text('Dynamics typed as text'), findsOneWidget);
    expect(settings.textDynamics, isTrue);
    await shot(tester, 'settings-flags');
    await tester.tap(find.byType(AppSwitch));
    await tester.pumpAndSettle();
    expect(settings.textDynamics, isFalse);

    await tester.enterText(find.byType(TextField), 'maestro');
    await tester.pumpAndSettle();
    expect(find.text('Dynamics typed as text'), findsOneWidget, reason: 'found by search');
  });

  testWidgets('search finds items on every page', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'link');
    await tester.pumpAndSettle();
    expect(find.text('Save the recording'), findsOneWidget);
    expect(find.text('Autosave'), findsNothing);
    await tester.enterText(find.byType(TextField), 'e');
    await tester.pumpAndSettle();
    await shot(tester, 'settings-search');
    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('No matching settings'), findsOneWidget);
  });

  testWidgets('Engraving sets the common options by plain name, a slider or switch each', (tester) async {
    final settings = await open(tester);
    await tester.tap(find.text('Engraving').first);
    await tester.pumpAndSettle();
    await shot(tester, 'settings-engraving');
    expect(find.text('Spacing'), findsOneWidget);
    expect(find.text('Line thickness'), findsOneWidget);
    expect(find.text('Note spacing'), findsOneWidget);
    expect(find.text('spacingLinear'), findsNothing, reason: 'code names only in Engraving options');

    // A slider sets its option once let go: one change, snapped to its step.
    final spacing = EngraveOption.byKey('spacingLinear')!;
    final row = find.ancestor(of: find.text('Note spacing'), matching: find.byType(Row)).first;
    final slider = find.descendant(of: row, matching: find.byType(Slider));
    await tester.drag(slider, const Offset(40, 0));
    await tester.pumpAndSettle();
    final value = settings.engravingOptions.valueOf(spacing) as double;
    expect(value, greaterThan(0.62));
    expect((value * 100).roundToDouble() / 100, value, reason: 'a step of 0.01');
    expect(find.descendant(of: row, matching: find.text(formatOptionValue(value))), findsOneWidget);
    await shot(tester, 'settings-engraving-changed');

    await tester.tap(find.descendant(of: row, matching: find.byTooltip('Reset')));
    await tester.pumpAndSettle();
    expect(settings.engravingOptions.isEmpty, isTrue);

    // A switch.
    final even = EngraveOption.byKey('evenNoteSpacing')!;
    final evenRow = find.ancestor(of: find.text('Even spacing'), matching: find.byType(Row)).first;
    await tester.tap(find.descendant(of: evenRow, matching: find.byType(AppSwitch)));
    await tester.pumpAndSettle();
    expect(settings.engravingOptions.valueOf(even), isTrue);

    // The search finds them by plain or code name.
    await tester.enterText(find.byType(TextField), 'stemThickness');
    await tester.pumpAndSettle();
    expect(find.text('Stems'), findsOneWidget);
  });

  testWidgets('Engraving ▸ Engraving options lists every safe option by code name, sorted, and changes them', (tester) async {
    final settings = await open(tester);
    await tester.tap(find.text('Engraving').first);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Open…'), 100, scrollable: find.byType(Scrollable).last);
    await tester.ensureVisible(find.text('Open…'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open…'));
    await tester.pumpAndSettle();
    await shot(tester, 'engrave-warning');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await shot(tester, 'engrave-options');

    // Every option is there, once, A–Z by code name: scroll through the whole list.
    final list = find.descendant(of: find.byType(ListView).last, matching: find.byType(Scrollable)).first;
    final keys = EngraveOption.all.map((o) => o.key).toSet();
    final seen = <String>[];
    for (var i = 0; i < 100; i++) {
      for (final t in tester.widgetList<Text>(find.descendant(of: list, matching: find.byType(Text)))) {
        if (keys.contains(t.data) && !seen.contains(t.data)) seen.add(t.data!);
      }
      await tester.drag(list, const Offset(0, -150), warnIfMissed: false);
      await tester.pumpAndSettle();
    }
    expect(seen.toSet(), keys);
    expect(seen, orderedEquals([...seen]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()))));

    // Search, then type a value: it is saved at once, clamped into range.
    await tester.enterText(find.widgetWithText(TextField, 'Search').last, 'slurcurve');
    await tester.pumpAndSettle();
    expect(find.text('slurCurveFactor'), findsOneWidget);
    expect(find.text('slurSymmetry'), findsNothing);
    final curve = EngraveOption.byKey('slurCurveFactor')!;
    final field = find.descendant(of: find.byType(ListView).last, matching: find.byType(TextField));
    await tester.enterText(field, '9');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(settings.engravingOptions.valueOf(curve), 5.0);
    await shot(tester, 'engrave-options-changed');

    await tester.tap(find.byTooltip('Reset').last);
    await tester.pumpAndSettle();
    expect(settings.engravingOptions.isEmpty, isTrue);
    expect(find.text('Engrave Options'), findsNothing, reason: 'no title, no help: code names only');
  });

  testWidgets('Engraving ▸ Engraving options warns first; Cancel leaves the options closed', (tester) async {
    await open(tester);
    await tester.tap(find.text('Engraving').first);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Open…'), 100, scrollable: find.byType(Scrollable).last);
    await tester.ensureVisible(find.text('Open…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open…'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Some values can break the layout'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Search'), findsOneWidget, reason: 'only the settings search is open');

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Editing these values'), findsNothing);
    expect(find.widgetWithText(TextField, 'Search'), findsOneWidget, reason: 'no engraving list opened');
    expect(find.text('Engraving options'), findsOneWidget, reason: 'back on the Engraving page');
  });

  testWidgets("a click on About's icon toggles the mascot in its place, saved; another turns it off", (tester) async {
    final settings = await open(tester);
    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();
    bool showing(String asset) => tester
        .widgetList<Image>(find.byType(Image))
        .any((i) => i.image is AssetImage && (i.image as AssetImage).assetName == 'assets/icon/$asset.png');
    expect(showing('app_icon'), isTrue);
    expect(showing('mascot'), isFalse);
    await tester.tap(find.byWidgetPredicate((w) => w is Image && w.image is AssetImage));
    await tester.pumpAndSettle();
    expect(settings.mascotIcon, isTrue);
    expect(showing('mascot'), isTrue);
    expect(showing('app_icon'), isFalse);
    await tester.tap(find.byWidgetPredicate((w) => w is Image && w.image is AssetImage));
    await tester.pumpAndSettle();
    expect(settings.mascotIcon, isFalse);
    expect(showing('app_icon'), isTrue);
    expect(File('assets/icon/mascot.png').existsSync(), isTrue);
  });
}
