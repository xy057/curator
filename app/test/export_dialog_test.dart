// File ▸ Export Video…: greyed out until a score is open; the dialog shows the frame at the
// playhead and remembers its choices. SCREENSHOT_DIR=/some/dir also saves it as a PNG.
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
  testWidgets('Export Video… offers ratio, size, frame rate, paper and score size', (tester) async {
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
    expect(find.text('At the playhead (1:10)'), findsOneWidget);
    expect(find.textContaining('1920 × 1080'), findsOneWidget);
    expect(find.text('No recording: the video will be silent.'), findsOneWidget);

    await tester.tap(find.text('4K'));
    await tester.tap(find.text('60'));
    await tester.tap(find.text('Dark'));
    await tester.pump();
    expect((settings.videoResolution, settings.videoFps, settings.videoPaper),
        (VideoResolution.uhd2160, 60, VideoPaper.dark));
    expect(find.textContaining('3840 × 2160'), findsOneWidget);

    // Any ratio: a preset, or one typed; a bad entry keeps the last good one.
    await tester.tap(find.text('9:16'));
    await tester.pump();
    expect(settings.videoRatio, const VideoRatio(9, 16));
    expect(find.textContaining('2160 × 3840'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '2.39:1');
    await tester.pump();
    expect(settings.videoRatio, const VideoRatio(2.39, 1));
    expect(find.textContaining('5162 × 2160'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '9:1');
    await tester.pump();
    expect(settings.videoRatio, const VideoRatio(2.39, 1), reason: 'wider than 4:1');
    await tester.enterText(find.byType(TextField), '1920x1080');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(settings.videoRatio, VideoRatio.widescreen);
    expect(find.widgetWithText(TextField, '16:9'), findsOneWidget, reason: 'tidied to the ratio it means');

    final dir = Platform.environment['SCREENSHOT_DIR'];
    if (dir != null) {
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(find.ancestor(of: find.byType(AlertDialog), matching: find.byType(RepaintBoundary)).last);
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
