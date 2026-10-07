import 'dart:io';
import 'dart:ui' as ui;

import 'package:curated_score/app_colors.dart';
import 'package:curated_score/app_extensions.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart' show CaptionCountdown, CaptionPosition, EngraveOption;

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
    expect(find.text('Attach Image  1.0'), findsOneWidget, reason: 'its version after its name');
    expect(find.text(AppExtension.attachImage.summary), findsOneWidget);
    expect(find.text('Captions  1.0'), findsOneWidget);
    final gears = tester.widgetList<IconButton>(find.widgetWithIcon(IconButton, Icons.settings_outlined)).toList();
    expect(gears.first.onPressed, isNull, reason: 'Attach Image has no settings of its own yet');
    expect(gears.last.onPressed, isNotNull, reason: 'Captions has');
    expect(settings.attachImage, isFalse, reason: 'extensions start off');
    expect(settings.captions, isFalse);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(settings.attachImage, isTrue);
    expect(settings.captions, isFalse, reason: 'each its own switch');
    await shot(tester, 'settings-extension');

    // Captions' own settings: how captions look.
    await tester.tap(find.widgetWithIcon(IconButton, Icons.settings_outlined).last);
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

  testWidgets('the window\'s outline cross-fades with the theme, in step with the other lines', (tester) async {
    await open(tester);
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();
    final window = tester.getRect(find.byType(Material).at(2));
    final theme = tester.getRect(find.byType(SegmentedButton<ThemeMode>));
    Future<(int, int)> outlines() async => (await tester.runAsync(() async {
          // At the view's 2× pixels: the window's left edge, and the theme switch's top edge.
          final image = await tester.renderObject<RenderRepaintBoundary>(find.byType(RepaintBoundary).first).toImage(pixelRatio: 2);
          final data = (await image.toByteData())!;
          int at(double x, double y) => data.getUint32(((y * 2).floor() * image.width + (x * 2).floor()) * 4);
          return (at(window.left, window.center.dy), at(theme.left + 30, theme.top + 4));
        }))!;
    final (lightWindow, lightSwitch) = await outlines();
    expect(lightWindow, lightSwitch);

    await tester.tap(find.text('Dark'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100)); // halfway through the theme's cross-fade
    final (midWindow, midSwitch) = await outlines();
    expect(midSwitch, isNot(lightSwitch));
    expect(midWindow, midSwitch);
  });

  testWidgets('a popup menu\'s outline cross-fades with the theme, in step with the other lines', (tester) async {
    final mode = ValueNotifier(ThemeMode.light);
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ValueListenableBuilder(
      valueListenable: mode,
      builder: (context, themeMode, _) => MaterialApp(
        theme: AppColors.theme(),
        darkTheme: AppColors.theme(brightness: Brightness.dark),
        themeMode: themeMode,
        builder: (context, child) => RepaintBoundary(child: child),
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(children: [
              Container(key: const Key('line'), width: 100, height: 40, decoration: BoxDecoration(border: Border.all(color: context.colors.line))),
              PopupMenuButton<int>(itemBuilder: (_) => const [PopupMenuItem(value: 1, child: Text('One'))]),
            ]),
          ),
        ),
      ),
    ));
    await tester.tap(find.byType(PopupMenuButton<int>));
    await tester.pumpAndSettle();
    final menu = tester.getRect(find.ancestor(of: find.text('One'), matching: find.byType(Material)).first);
    final line = tester.getRect(find.byKey(const Key('line')));
    Future<(int, int)> outlines() async => (await tester.runAsync(() async {
          final image = await tester.renderObject<RenderRepaintBoundary>(find.byType(RepaintBoundary).first).toImage(pixelRatio: 2);
          final data = (await image.toByteData())!;
          int at(double x, double y) => data.getUint32(((y * 2).floor() * image.width + (x * 2).floor()) * 4);
          return (at(menu.left, menu.center.dy), at(line.left, line.center.dy));
        }))!;
    final (lightMenu, lightLine) = await outlines();
    expect(lightMenu, lightLine);

    // A Material starts its own shape tween over at each new frame of the theme, at its last
    // outline, so the menu's is a frame behind: in step, not finishing on its own time.
    mode.value = ThemeMode.dark;
    await tester.pump();
    var previousLine = lightLine;
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final (menuNow, lineNow) = await outlines();
      expect(lineNow, isNot(previousLine));
      expect(menuNow, previousLine);
      previousLine = lineNow;
    }
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
