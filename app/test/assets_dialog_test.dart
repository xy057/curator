import 'dart:io';
import 'dart:ui' as ui;

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/assets_dialog.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/image_patch.dart';
import 'package:curated_score/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'image_patch_test.dart' show png, svg;
import 'test_fonts.dart';

void main() {
  testWidgets('Manage assets lists the images kept, locates each use, removes an image everywhere and purges unused ones', (tester) async {
    await tester.runAsync(loadTestFonts);
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
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

    final dir = Platform.environment['SCREENSHOT_DIR'];
    Future<void> shot(String name) async {
      if (dir == null) return;
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.ancestor(of: find.byType(AssetsDialog), matching: find.byType(RepaintBoundary)).last);
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }

    final button = find.byTooltip('Manage assets…');
    expect(button, findsNothing, reason: 'Attach Image is off');
    settings.attachImage = true;
    await tester.pump();
    expect(button, findsOneWidget);

    // The same SVG twice is one image used twice; the PNG is another.
    await tester.runAsync(() async {
      await c.images.add(ImageKind.vector, svg, quarter: 12, top: 3, extension: 'svg');
      await c.images.add(ImageKind.raster, png, quarter: 3, top: 3, extension: 'png');
      await c.images.add(ImageKind.vector, svg, quarter: 30, top: 3, extension: 'svg');
    });
    await tester.pump();
    expect(c.images.stored, hasLength(2));

    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byType(AssetsDialog), findsOneWidget);
    expect(find.textContaining('SVG · '), findsOneWidget);
    expect(find.textContaining('PNG · 4 × 2 · '), findsOneWidget);
    // 6/8: two dotted crotchets a bar, three quarters.
    for (final bar in ['Bar 5', 'Bar 11', 'Bar 2']) {
      expect(find.text(bar), findsOneWidget);
    }
    await shot('assets-dialog');

    // A use's bar: the playhead goes where it reaches the pointer, and it is selected.
    await tester.tap(find.text('Bar 11'));
    await tester.pumpAndSettle();
    expect(find.byType(AssetsDialog), findsNothing);
    expect(c.images.selected, 2);
    expect(c.playback.time.value, closeTo(c.timeline.secondsAtQuarter(30), 1e-6));

    // Remove: the SVG goes from both places, as one Undo step.
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove').first);
    await tester.pumpAndSettle();
    expect(c.images.patches.single.image, endsWith('.png'));
    expect(find.text('Bar 5'), findsNothing);
    expect(find.text('Bar 2'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    c.undo();
    expect(c.images.patches, hasLength(3));
    expect(c.images.stored, hasLength(2));

    // Removed, the SVG is unused: listed under Unused (kept for Undo) until purged.
    final svgId = c.images.stored.firstWhere((i) => i.id.endsWith('.svg')).id;
    c.images.removeImage(svgId);
    final png0 = c.images.patches.single;
    c.images.update(0, png0.copyWith(quarter: 6)); // an edit that isn't the SVG's
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('Unused'), findsOneWidget);
    await shot('assets-unused');
    expect(find.textContaining('SVG · '), findsOneWidget);
    expect(find.byTooltip('Remove'), findsOneWidget, reason: 'only the PNG is on the score');
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Purge unused')).onPressed, isNotNull);

    await tester.tap(find.text('Purge unused'));
    await tester.pumpAndSettle();
    expect(find.text('Unused'), findsNothing);
    expect(find.textContaining('SVG · '), findsNothing);
    expect(c.images.unused, isEmpty);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Purge unused')).onPressed, isNull);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    // Undo keeps every other edit but never brings the SVG back.
    c.undo();
    expect(c.images.patches.single, png0, reason: 'the PNG move is undone');
    while (c.canUndo) {
      c.undo();
      expect(c.images.patches.every((p) => p.image.endsWith('.png')), isTrue);
    }
    expect(c.images.patches, isEmpty, reason: 'back to before the PNG was added');
    while (c.canRedo) {
      c.redo();
    }
    expect(c.images.patches.single.quarter, 6);
  });
}
