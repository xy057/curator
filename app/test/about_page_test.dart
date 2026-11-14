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

    // How far About's page scrolls: 0 when all of it shows.
    double scrolls() => tester
        .stateList<ScrollableState>(find.descendant(of: find.byType(SingleChildScrollView), matching: find.byType(Scrollable)))
        .where((s) => find.descendant(of: find.byWidget(s.widget), matching: find.text('Licenses')).evaluate().isNotEmpty)
        .map((s) => s.position.maxScrollExtent)
        .reduce((a, b) => a > b ? a : b);

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
        expect(scrolls(), 0, reason: 'all of About shows in the window at its largest');
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
    expect(scrolls(), 0, reason: 'the credit pushes nothing off the page');
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

    // The channel: Pre-release is kept, and is the one the updater asks on from then.
    final updater = Updater();
    await openAbout(updater);
    expect(find.text('Update channel'), findsOneWidget);
    await tester.tap(find.text('Pre-release'));
    await settle();
    expect((settings.updateChannel, updater.channel), (UpdateChannel.prerelease, UpdateChannel.prerelease));
    expect(tester.takeException(), isNull);
    await shot('about-prerelease', find.text('Licenses'));
    await close();

    // The update window: the version (marked a pre-release), what its description says is new,
    // its download and its page.
    final release = Release(
      version: const Version(9, 0, 0),
      pageUrl: '$repositoryUrl/releases/tag/v9.0.0',
      download: Uri.parse('https://github.com/xy057/curator/releases/download/v9.0.0/Curator-9.0.0-macos.zip'),
      platform: 'macos',
      prerelease: true,
      published: DateTime.utc(2026, 11, 13, 12),
      notes: '## New\n\n- **Update channels**: Release or Pre-release, in Settings ▸ About\n- Release notes in a window of their own\n'
          '  - with `code`, *emphasis* and [links](https://curator.0x57.cc/)\n\n## Fixed\n\n1. A first thing\n2. A second by @someone in '
          'https://github.com/xy057/curator/pull/12\n\n> Pre-releases may be rough.\n\n```\nmake check\n```\n\n'
          '**Full Changelog**: https://github.com/xy057/curator/compare/v0.8.0...v9.0.0',
    );
    for (final style in UiStyle.values) {
      for (final theme in [ThemeMode.light, ThemeMode.dark]) {
        settings
          ..uiStyle = style
          ..themeMode = theme;
        await tester.pump(const Duration(milliseconds: 500));
        unawaited(showUpdate(tester.element(find.byType(Scaffold).first), Updater(), release));
        await settle();
        expect(find.text('Curator 9.0.0'), findsOneWidget);
        for (final text in ['Pre-release', 'New', 'Fixed', 'Download 9.0.0', 'Open Release Page', 'Close']) {
          expect(find.text(text), findsOneWidget, reason: text);
        }
        expect(tester.takeException(), isNull);
        await shot('update-${style.name}-${theme.name}', find.text('Close'));
        await close();
      }
    }

    // A release that says nothing, and has no download for this system: its page is the way.
    unawaited(showUpdate(tester.element(find.byType(Scaffold).first), Updater(), Release(version: const Version(9, 0, 0), pageUrl: '$repositoryUrl/releases')));
    await settle();
    expect(find.text('No release notes.'), findsOneWidget);
    expect(find.text('Pre-release'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Open Release Page'), findsOneWidget);
    expect(find.text('Download 9.0.0'), findsNothing);
    await close();
  });
}
