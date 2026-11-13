// Settings ▸ About in each style and theme, and its Licenses window: Curator's own first, then
// every package's. With SCREENSHOT_DIR set, each is saved as a PNG.
// Run: SCREENSHOT_DIR=/some/dir flutter test test/about_page_test.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:curated_score/app_colors.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/licenses_dialog.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/settings_dialog.dart';
import 'package:curated_score/updater.dart';
import 'package:flutter/foundation.dart' show LicenseRegistry;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';
import 'window.dart' show screenshotDir;

void main() {
  test('the licence the app carries is the repository’s', () {
    expect(File('assets/LICENSE.txt').readAsStringSync(), File('../LICENSE').readAsStringSync());
  });

  testWidgets('About draws in every style and theme; Licenses lists Curator first, then the rest', (tester) async {
    tester.view
      ..physicalSize = const Size(1800, 1200)
      ..devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.runAsync(loadTestFonts);
    LicenseRegistry.addLicense(bundledLicenses); // as main() does
    addTearDown(LicenseRegistry.reset);
    final settings = AppSettings.memory();
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    await tester.pump(const Duration(seconds: 1));

    // Real time for what is read or decoded off the fake clock (the icon, the licences), then frames.
    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    // The whole window, the settings over it: the outermost boundary over [inside].
    Future<void> shot(String name, Finder inside) async {
      final dir = screenshotDir;
      if (dir == null) return;
      RenderRepaintBoundary? whole;
      for (RenderObject? o = tester.renderObject(inside.first); o != null; o = o.parent) {
        if (o is RenderRepaintBoundary) whole = o;
      }
      await tester.runAsync(() async {
        final png = await (await whole!.toImage(pixelRatio: 2)).toByteData(format: ui.ImageByteFormat.png);
        File('$dir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    Future<void> openAbout(Updater updater) async {
      unawaited(showSettingsDialog(tester.element(find.byType(Scaffold).first), settings, updater: updater, page: 'About'));
      await settle();
    }

    Future<void> close() async {
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await settle();
    }

    for (final style in UiStyle.values) {
      for (final theme in [ThemeMode.light, ThemeMode.dark]) {
        settings
          ..uiStyle = style
          ..themeMode = theme;
        await tester.pump(const Duration(milliseconds: 500));
        await openAbout(Updater());
        expect(tester.takeException(), isNull);
        for (final tile in ['Website', 'Changelog', 'Source code', 'Licenses']) {
          expect(find.text(tile), findsOneWidget, reason: tile);
        }
        await shot('about-${style.name}-${theme.name}', find.text('Licenses'));
        await close();
      }
    }

    // The mascot, its credit at the foot; nothing is pushed off the page.
    settings
      ..uiStyle = UiStyle.refined
      ..themeMode = ThemeMode.light
      ..mascotIcon = true;
    await openAbout(Updater());
    expect(find.text('Created using EmoteLab'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await shot('about-mascot', find.text('Licenses'));
    await close();
    settings.mascotIcon = false;

    // Licenses: Curator's GPL first; another package's text once it is chosen.
    await openAbout(Updater());
    await tester.tap(find.text('Licenses'));
    await settle();
    final packages = await tester.runAsync(() => packageLicenses);
    await settle();
    expect(packages!.first.$1, 'Curator');
    expect(packages.map((p) => p.$1), containsAll(['PDFium', 'Verovio', 'Bravura', 'Basic Pitch']));
    expect(find.textContaining('GNU GENERAL PUBLIC LICENSE'), findsWidgets);
    await shot('licenses', find.text('Done'));
    await tester.tap(find.text('PDFium'));
    await settle();
    expect(find.textContaining('GNU GENERAL PUBLIC LICENSE'), findsNothing);
    expect(tester.takeException(), isNull);
    await shot('licenses-pdfium', find.text('Done'));
    await tester.tap(find.text('Done'));
    await settle();
    await close();
  });
}
