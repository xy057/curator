// File ▸ Export Video…: greyed out until a score is open; the dialog shows the frame at the
// playhead over a trimmer of the piece, exports the whole piece unless bars are typed or dragged,
// and remembers its choices. SCREENSHOT_DIR=/some/dir also saves it as PNGs.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/ui_kit.dart';
import 'package:curated_score/video_export.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_project.dart';
import 'test_fonts.dart';
import 'finders.dart';

void main() {
  testWidgets('Export Video…: a still over a trimmer, and a sidebar of the video and its picture', (tester) async {
    await tester.runAsync(loadTestFonts);
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final settings = AppSettings.memory();
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    final state = tester.state(find.byType(HomePage)) as dynamic;
    final c = state.controller as EditorController;

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
    expect(find.textContaining('1920 × 1080 · 30 fps'), findsOneWidget);
    expect(find.text('Silent'), findsOneWidget);
    await shoot('export-dialog');

    // The whole piece unless changed.
    String field(String label) => tester.widget<TextField>(appField(label)).controller!.text;
    expect((field('From bar'), field('To bar')), ('1', '44'));
    bool canRestore() =>
        tester.widget<IconButton>(find.ancestor(of: find.byTooltip('Whole piece'), matching: find.byType(IconButton))).onPressed !=
        null;
    expect(canRestore(), isFalse);
    String length() => tester.widget<Text>(find.textContaining(' frames')).data!.split(' · ').first;
    final whole = length();

    /// Opens the select showing [shown] and picks [choice].
    Future<void> choose(String shown, String choice) async {
      await tester.tap(inDialog(shown).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(choice).last);
      await tester.pumpAndSettle();
    }

    // Format, size and frame rate: menus, remembered.
    await choose('MP4 (H.264)', 'MOV (ProRes)');
    await choose('1080p', '4K');
    await choose('30', '60');
    await tester.tap(find.text('Dark'));
    await tester.pump();
    expect((settings.videoCodec, settings.videoResolution, settings.videoFps, settings.videoPaper),
        (VideoCodec.prores, VideoResolution.uhd2160, 60, VideoPaper.dark));
    expect(find.textContaining('16:9 · 3840 × 2160 · 60 fps'), findsOneWidget);

    // Any frame rate, typed: Custom… turns the select into a field.
    await choose('60', 'Custom…');
    final rate = find.descendant(of: find.byType(Dialog), matching: find.byType(TextField)).last;
    await tester.enterText(rate, '23.976');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(settings.videoFps, 24000 / 1001);
    expect(find.textContaining('23.976 fps'), findsOneWidget);
    await choose('23.976', 'Custom…');
    await tester.enterText(find.descendant(of: find.byType(Dialog), matching: find.byType(TextField)).last, '500');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(settings.videoFps, 24000 / 1001, reason: 'out of range: kept as it was');
    await tester.tapAt(const Offset(10, 10)); // away: the field goes back to the select
    await tester.pumpAndSettle();
    expect(inDialog('23.976'), findsOneWidget);

    // A transparent background where the format keeps one.
    AppSwitch transparent() =>
        tester.widget<AppSwitch>(find.descendant(of: find.byType(Dialog), matching: find.byType(AppSwitch)));
    await tester.tap(find.byType(AppSwitch).last);
    await tester.pump();
    expect((settings.videoTransparent, settings.videoFormat.hasAlpha, transparent().value), (true, true, true));
    await shoot('export-dialog-transparent');

    // Back to an MP4, 1080p at 30, where it can't be transparent.
    final reset = find.byTooltip('MP4 · 1080p · 30 fps');
    await tester.tap(reset);
    await tester.pump();
    expect((settings.videoCodec, settings.videoResolution, settings.videoFps), (VideoCodec.h264, VideoResolution.hd1080, 30));
    expect(tester.widget<IconButton>(find.ancestor(of: reset, matching: find.byType(IconButton))).onPressed, isNull,
        reason: 'nothing to reset');
    expect((transparent().value, transparent().onChanged), (false, null), reason: 'an MP4 is always on paper');
    // Why, on hovering anywhere along the row: its label too, not only the switch.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.descendant(of: find.byType(Dialog), matching: find.text('Transparent'))));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Not supported in MP4'), findsOneWidget);
    await mouse.moveTo(Offset.zero);
    await tester.pump(const Duration(seconds: 1));

    // From 480p to 8K; 8K H.264 only as wide as about 16:9, so at 21:9 it can't be chosen.
    await choose('1080p', '8K');
    expect(find.textContaining('7680 × 4320'), findsOneWidget);
    await choose('16:9', '21:9');
    expect(settings.videoRatio, const VideoRatio(21, 9));
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Export…')).onPressed, isNull,
        reason: 'too many pixels for H.264');
    await tester.tap(inDialog('8K').first);
    await tester.pumpAndSettle();
    expect(tester.widget<MenuItemButton>(find.widgetWithText(MenuItemButton, '8K')).onPressed, isNull);
    await tester.tap(find.text('480p').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('1120 × 480'), findsOneWidget);
    await choose('21:9', '16:9');

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

    // Or dragged on the trimmer: the first handle to bar 9 types it, and the still goes there.
    final export = VideoExport.of(c);
    addTearDown(export.dispose);
    final trimmer = tester.getRect(find.bySemanticsLabel('Bars and still'));
    double xOf(double t) => trimmer.left + t / export.duration * trimmer.width;
    final gesture = await tester.startGesture(Offset(trimmer.left + 1, trimmer.center.dy));
    await gesture.moveBy(const Offset(20, 0));
    await gesture.moveTo(Offset(xOf(export.barStarts[8]), trimmer.center.dy));
    await gesture.up();
    await tester.pump();
    expect((field('From bar'), field('To bar')), ('9', '44'));
    expect(inDialog('9.1'), findsOneWidget);
    // Anywhere else moves the still, inside the bars.
    await tester.tapAt(Offset(xOf(export.barStarts[20]), trimmer.center.dy));
    await tester.pump();
    expect(inDialog('21.1'), findsOneWidget);
    await tester.tapAt(Offset(trimmer.left + 2, trimmer.center.dy));
    await tester.pump();
    expect(inDialog('9.1'), findsOneWidget, reason: 'kept inside the bars');

    // The score size is the project's: the editor follows it.
    final before = c.staffSpace;
    await tester.drag(find.byType(Slider).last, const Offset(-120, 0));
    await tester.pump();
    expect(c.staffSpace, lessThan(before));

    await tester.pump(const Duration(seconds: 1)); // the slider's value bubble fades
    await tester.tap(find.byTooltip('Close'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Export Video'), findsNothing);
  });
}
