import 'dart:io';
import 'dart:ui' as ui;

import 'package:curated_score/app_colors.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/settings_dialog.dart';
import 'package:flutter/gestures.dart';
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
        theme: AppColors.theme(accent: settings.accent, style: settings.uiStyle),
        darkTheme: AppColors.theme(accent: settings.accent, brightness: Brightness.dark, style: settings.uiStyle),
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
    await tester.tap(find.byTooltip('Custom…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '#EC7393'), '#2a9d8f');
    await tester.pump();
    await shot(tester, 'settings-custom-color');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(settings.accent, AccentColor.custom(const Color(0xFF2A9D8F)));
    expect(settings.customAccent, const Color(0xFF2A9D8F));
    await tester.tap(find.text('Carbon'));
    await tester.pumpAndSettle();
    expect(settings.uiStyle, UiStyle.carbon);
    await shot(tester, 'settings-appearance-carbon');
    // A hover fades a segment's shade in from none, never through the text colour (white here).
    final segment = find.ancestor(of: find.text('Refined'), matching: find.byType(AnimatedContainer)).first;
    final shade = find.descendant(of: segment, matching: find.byType(DecoratedBox)).first;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(segment));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final fill = (tester.widget<DecoratedBox>(shade).decoration as BoxDecoration).color!;
    expect(fill.a, inExclusiveRange(0, 1));
    expect(fill.withValues(alpha: 1), isSameColorAs(CarbonColors.maybeOf(tester.element(segment))!.layerHover));
    await mouse.removePointer();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refined'));
    await tester.pumpAndSettle();
    expect(settings.uiStyle, UiStyle.refined);

    expect(find.text('Animation'), findsNothing, reason: "the project's, in Project Settings");

    expect(find.text('Extensions'), findsNothing, reason: "the project's, in Project Settings");
  });

  test("the app's old extension switches are still read, for projects saved before they kept their own", () async {
    SharedPreferences.setMockInitialValues({'captions': true, 'attachImage': false}); // until build 69
    expect((await AppSettings.load()).legacyExtensions, {'captions': true, 'attachImage': false});
    SharedPreferences.setMockInitialValues({'extensionDefaults': '{"captions": false, "com.example.later": true}'}); // builds 69–70
    expect((await AppSettings.load()).legacyExtensions, {'captions': false, 'com.example.later': true});
  });
}
