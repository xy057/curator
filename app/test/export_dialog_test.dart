// File ▸ Export Video…: greyed out until a score is open; the dialog shows the frame at the
// playhead, exports the whole piece unless bars are typed, and remembers its choices. SCREENSHOT_DIR=/some/dir also saves it as a PNG.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/video_export.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_project.dart';
import 'test_fonts.dart';

void main() {
  testWidgets('Export Video… offers bars, ratio, size, frame rate, paper and score size', (tester) async {
    await tester.runAsync(loadTestFonts);
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final settings = AppSettings.memory();
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    final state = tester.state(find.byType(HomePage)) as dynamic;
    final c = state.controller as EditorController;

    Future<MenuItemButton> item() async {
      await tester.tap(find.text('File'));
      await tester.pump();
      return tester.widget<MenuItemButton>(find.widgetWithText(MenuItemButton, 'Export Video…'));
    }

    expect((await item()).onPressed, isNull, reason: 'nothing to export yet');
    await tester.tapAt(const Offset(700, 600));
    await tester.pump();

    await tester.runAsync(() => c.openFile(demoScore.path));
    await tester.pump();
    c.playback.seek(70); // bar 37
    await tester.pump();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Export Video…').hitTestable().evaluate().isEmpty
        ? find.byWidget(await item())
        : find.widgetWithText(MenuItemButton, 'Export Video…'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Export Video'), findsOneWidget);
    Finder inDialog(String text) => find.descendant(of: find.byType(Dialog), matching: find.text(text));
    expect(inDialog('1:10'), findsOneWidget, reason: 'the still is at the playhead');
    expect(inDialog('37.1'), findsOneWidget);
    expect(find.textContaining('1920 × 1080'), findsOneWidget);
    expect(find.text('Silent'), findsOneWidget);

    // The whole piece unless changed.
    String field(String label) =>
        tester.widget<TextField>(find.widgetWithText(TextField, label)).controller!.text;
    expect((field('From bar'), field('To bar')), ('1', '44'));
    bool canRestore() => tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.restart_alt_rounded)).onPressed != null;
    expect(canRestore(), isFalse);
    String length() => tester.widget<Text>(find.textContaining(' frames')).data!.split(' · ').first;
    final whole = length();

    await tester.tap(find.text('4K'));
    await tester.tap(find.text('60'));
    await tester.tap(find.text('Dark'));
    await tester.pump();
    expect((settings.videoResolution, settings.videoFps, settings.videoPaper),
        (VideoResolution.uhd2160, 60, VideoPaper.dark));
    expect(find.textContaining('3840 × 2160'), findsOneWidget);

    // The ratio is the toolbar's; the dialog says which.
    expect(find.textContaining('16:9 · 3840 × 2160'), findsOneWidget);

    // Bars 5–12: shorter, and the still moves to bar 5; a range backwards can't be exported.
    await tester.enterText(find.widgetWithText(TextField, 'From bar'), '5');
    await tester.enterText(find.widgetWithText(TextField, 'To bar'), '12');
    await tester.pump();
    expect(inDialog('5.1'), findsOneWidget);
    expect(length(), isNot(whole));
    expect(canRestore(), isTrue);
    await tester.enterText(find.widgetWithText(TextField, 'To bar'), '4');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Export…')).onPressed, isNull);
    await tester.tap(find.byTooltip('Whole piece'));
    await tester.pump();
    expect((field('From bar'), field('To bar')), ('1', '44'));
    expect(length(), whole);

    final dir = Platform.environment['SCREENSHOT_DIR'];
    if (dir != null) {
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(find.ancestor(of: find.byType(Dialog), matching: find.byType(RepaintBoundary)).last);
        final image = await boundary.toImage(pixelRatio: 2);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/export-dialog.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    // The score size is the project's: the editor follows it.
    final before = c.staffSpace;
    await tester.drag(find.byType(Slider).last, const Offset(-120, 0));
    await tester.pump();
    expect(c.staffSpace, lessThan(before));

    await tester.pump(const Duration(seconds: 1)); // the slider's value bubble fades
    await tester.tap(find.text('Cancel'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Export Video'), findsNothing);
  });
}
