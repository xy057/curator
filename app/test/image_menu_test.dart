import 'dart:io';
import 'dart:ui' as ui;

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/score_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:curated_score/image_patch.dart';

import 'image_patch_test.dart' show png;
import 'test_fonts.dart';

void main() {
  testWidgets('right-click the score: Add Image… and Paste; select, resize, crop', (tester) async {
    await tester.runAsync(loadTestFonts);
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final dir = Platform.environment['SCREENSHOT_DIR'];
    Future<void> shot(String name) async {
      if (dir == null) return;
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.ancestor(of: find.byType(Scaffold), matching: find.byType(RepaintBoundary)).first);
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }

    final settings = AppSettings.memory();
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Try the sample'));
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    for (var i = 0; i < 100 && c.score == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 500));
    final view = tester.getRect(find.byType(ScoreView));
    final spot = view.center + const Offset(150, -60);

    Future<void> rightClick(Offset at) async {
      await tester.tapAt(at, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
    }

    await rightClick(spot);
    expect(find.text('Add Image…'), findsNothing, reason: 'Attach Image is off');

    settings.attachImage = true;
    await tester.pump();
    await rightClick(spot);
    expect(find.text('Add Image…'), findsOneWidget, reason: 'one item for SVG, PNG and JPEG');
    expect(find.text('Paste'), findsOneWidget);
    await shot('image-menu');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // An image where the menu was opened: its top-left corner there.
    final scene = c.scene!;
    final quarter = scene.quarterAtFrameX(spot.dx - view.left, c.playback.time.value, view.size);
    await tester.runAsync(() => c.images.add(ImageKind.raster, png, quarter: quarter, top: (spot.dy - view.top) / scene.style.staffSpace));
    await tester.pump();
    Rect rect() => c.scene!.patchRect(c.scene!.patches.single, c.playback.time.value, view.size).shift(view.topLeft);
    expect(rect().topLeft.dx, closeTo(spot.dx, 0.5));
    expect(rect().topLeft.dy, closeTo(spot.dy, 0.5));
    await shot('image-selected');

    // Drag the bottom-right corner: bigger, same shape.
    final before = c.images.patches.single;
    await tester.dragFrom(rect().bottomRight, const Offset(60, 0));
    await tester.pumpAndSettle();
    final resized = c.images.patches.single;
    expect(resized.width, greaterThan(before.width));
    expect(resized.width / resized.height, closeTo(before.width / before.height, 1e-6));
    expect(resized.quarter, closeTo(before.quarter, 1e-6), reason: 'the top-left corner stays');

    // Right-click it: Crop and Remove. Crop, then drag the left edge in.
    await rightClick(rect().center);
    expect(find.text('Remove'), findsOneWidget);
    await tester.tap(find.text('Crop'));
    await tester.pumpAndSettle();
    expect(c.images.cropping, isTrue);
    final shown = rect();
    await tester.dragFrom(shown.centerLeft, const Offset(40, 0));
    await tester.pumpAndSettle();
    final cropped = c.images.patches.single;
    expect(cropped.crop.left, closeTo(40 / shown.width, 0.005), reason: 'the left edge went in by 40 points');
    expect(rect().left, closeTo(shown.left + 40, 0.5));
    expect(cropped.height, closeTo(resized.height, 1e-6), reason: 'cropping keeps the scale');
    await shot('image-cropping');

    // A click elsewhere deselects; Delete then leaves the image be.
    await tester.tapAt(view.topLeft + const Offset(400, 20));
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.images.selected, isNull);
    await tester.tapAt(rect().center);
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.images.selected, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(c.images.patches, isEmpty);
  });
}
