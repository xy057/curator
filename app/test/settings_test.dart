import 'dart:io';
import 'dart:ui' as ui;

import 'package:curated_score/app_colors.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart' show EngraveOption;

import 'test_fonts.dart';

void main() {
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

    await tester.tap(find.text('Animation'));
    await tester.pumpAndSettle();
    expect(find.text('Staff transition'), findsOneWidget);
    expect(find.textContaining('Open a project'), findsOneWidget, reason: 'the project\'s own needs a project');
    await tester.tap(find.text('0.3 s')); // For new projects
    await tester.pumpAndSettle();
    await tester.tap(find.text('0.8 s').last);
    await tester.pumpAndSettle();
    expect(settings.transition, 0.8);

    await tester.tap(find.text('Extension'));
    await tester.pumpAndSettle();
    expect(find.text('Attach Image'), findsOneWidget);
    expect(settings.attachImage, isFalse, reason: 'extensions start off');
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(settings.attachImage, isTrue);
    await shot(tester, 'settings-extension');
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

  testWidgets('Advanced ▸ Engrave Option lists every safe option by code name, sorted, and changes them', (tester) async {
    final settings = await open(tester);
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    await shot(tester, 'settings-advanced');

    await tester.tap(find.text('Engrave Option'));
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

    await tester.tap(find.byTooltip('Reset'));
    await tester.pumpAndSettle();
    expect(settings.engravingOptions.isEmpty, isTrue);
    expect(find.text('Engrave Options'), findsNothing, reason: 'no title, no help: code names only');
  });

  testWidgets('Advanced ▸ Engrave Option warns first; Cancel leaves the options closed', (tester) async {
    await open(tester);
    if (find.text('Engrave Option').evaluate().isEmpty) {
      await tester.tap(find.text('Advanced')); // the dialog reopens on the page it was left on
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Engrave Option'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Editing these values might generate unintended results and errors'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Search'), findsOneWidget, reason: 'only the settings search is open');

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Editing these values'), findsNothing);
    expect(find.widgetWithText(TextField, 'Search'), findsOneWidget, reason: 'no engraving list opened');
    expect(find.text('Engrave Option'), findsOneWidget, reason: 'back on the Advanced page');
  });
}
