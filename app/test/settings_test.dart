import 'dart:io';
import 'dart:ui' as ui;

import 'package:curated_score/app_colors.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

    expect(find.text('Animation'), findsNothing, reason: "the project's, in Project Settings");

    expect(find.text('Extensions'), findsNothing, reason: "the project's, in Project Settings");
  });

  test("an extension's own switch, from before defaults went by id, is its default", () async {
    SharedPreferences.setMockInitialValues({'captions': true, 'attachImage': false});
    final old = await AppSettings.load();
    expect(old.extensionDefaults, {'captions': true, 'attachImage': false});
    old.setExtensionDefault('com.example.later', true); // any id: none is known by name here
    expect((await AppSettings.load()).extensionDefaults, {'captions': true, 'attachImage': false, 'com.example.later': true});
  });
}
