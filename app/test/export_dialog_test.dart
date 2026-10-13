// File ▸ Export Video…: greyed out until a score is open; the dialog shows the frame at the
// playhead, exports the whole piece unless bars are typed, and remembers its choices. SCREENSHOT_DIR=/some/dir also saves it as a PNG.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/ui_kit.dart';
import 'package:curated_score/video_export.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_project.dart';
import 'test_fonts.dart';
import 'finders.dart';

void main() {
  testWidgets('Export Video… offers bars, format, ratio, size, frame rate, paper and score size', (tester) async {
    await tester.runAsync(loadTestFonts);
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final settings = AppSettings.memory();
    Future<void> shoot(String name) async {
      final dir = Platform.environment['SCREENSHOT_DIR'];
      if (dir == null) return;
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.ancestor(of: find.byType(Dialog), matching: find.byType(RepaintBoundary)).last);
        final image = await boundary.toImage(pixelRatio: 2);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

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
        tester.widget<TextField>(appField(label)).controller!.text;
    expect((field('From bar'), field('To bar')), ('1', '44'));
    bool canRestore() => tester.widget<IconButton>(find.ancestor(of: find.byTooltip('Whole piece'), matching: find.byType(IconButton))).onPressed != null;
    expect(canRestore(), isFalse);
    String length() => tester.widget<Text>(find.textContaining(' frames')).data!.split(' · ').first;
    final whole = length();

    Future<void> size(String label) async {
      await tester.tap(find.byTooltip('Video size'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    await size('4K');
    await tester.tap(find.text('60'));
    await tester.tap(find.text('Dark'));
    await tester.pump();
    expect((settings.videoResolution, settings.videoFps, settings.videoPaper),
        (VideoResolution.uhd2160, 60, VideoPaper.dark));
    expect(find.textContaining('3840 × 2160'), findsOneWidget);

    // Any format: MP4 unless changed.
    expect(find.text('MP4 (H.264)'), findsOneWidget);
    await tester.tap(find.byTooltip('Video format'));
    await tester.pumpAndSettle();
    expect(find.text('WebM (VP9)'), findsOneWidget);
    expect(find.text('PNG Sequence'), findsOneWidget);
    await tester.tap(find.text('MOV (ProRes)'));
    await tester.pumpAndSettle();
    expect(settings.videoCodec, VideoCodec.prores);
    expect(find.text('MOV (ProRes)'), findsOneWidget);

    // A transparent background where the format keeps one: the still shows it on a checkerboard.
    AppSwitch transparent() =>
        tester.widget<AppSwitch>(find.descendant(of: find.byType(Dialog), matching: find.byType(AppSwitch)));
    expect(transparent().onChanged, isNotNull);
    await tester.tap(find.byType(AppSwitch).last);
    await tester.pump();
    expect(settings.videoTransparent, isTrue);
    expect(settings.videoFormat.hasAlpha, isTrue);
    expect(transparent().value, isTrue);
    await shoot('export-dialog-transparent');

    // Remembered, with a way back to an MP4, 1080p at 30.
    final reset = find.byTooltip('MP4 · 1080p · 30 fps');
    await tester.tap(reset);
    await tester.pump();
    expect((settings.videoCodec, settings.videoResolution, settings.videoFps), (VideoCodec.h264, VideoResolution.hd1080, 30));
    expect((transparent().value, transparent().onChanged), (false, null), reason: 'an MP4 is always on paper');
    expect(find.byTooltip('MOV, WebM or PNG only'), findsOneWidget);
    expect(tester.widget<IconButton>(find.ancestor(of: reset, matching: find.byType(IconButton))).onPressed, isNull,
        reason: 'nothing to reset');
    await size('4K');
    await tester.tap(find.text('60'));
    await tester.pump();

    // From 480p to 8K; 8K H.264 only as wide as about 16:9, so at 21:9 it can't be chosen.
    await size('8K');
    expect(find.textContaining('7680 × 4320'), findsOneWidget);
    settings.videoRatio = const VideoRatio(21, 9);
    await tester.pump();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Export…')).onPressed, isNull,
        reason: 'too many pixels for H.264');
    await tester.tap(find.byTooltip('Video size'));
    await tester.pumpAndSettle();
    expect(tester.widget<PopupMenuItem<VideoResolution>>(find.widgetWithText(PopupMenuItem<VideoResolution>, '8K')).enabled,
        isFalse);
    await tester.tap(find.text('480p').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('1120 × 480'), findsOneWidget);
    settings.videoRatio = VideoRatio.widescreen;
    await size('4K');

    // The ratio is the toolbar's; the dialog says which.
    expect(find.textContaining('16:9 · 3840 × 2160'), findsOneWidget);

    // Bars 5–12: shorter, and the still moves to bar 5; a range backwards can't be exported.
    await tester.enterText(appField('From bar'), '5');
    await tester.enterText(appField('To bar'), '12');
    await tester.pump();
    expect(inDialog('5.1'), findsOneWidget);
    expect(length(), isNot(whole));
    expect(canRestore(), isTrue);
    await tester.enterText(appField('To bar'), '4');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Export…')).onPressed, isNull);
    await tester.tap(find.byTooltip('Whole piece'));
    await tester.pump();
    expect((field('From bar'), field('To bar')), ('1', '44'));
    expect(length(), whole);

    await shoot('export-dialog');

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
