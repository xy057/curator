// Settings ▸ Advanced ▸ Engrave Option with a score open: the preview beside the list shows
// the score engraved again after each change. With SCREENSHOT_DIR set, saves PNGs.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/engrave_options_dialog.dart';
import 'package:curated_score/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';
import 'test_fonts.dart';

void main() {
  testWidgets('the preview shows the open score, engraved again with each change', (tester) async {
    final dir = Platform.environment['SCREENSHOT_DIR'];
    if (dir != null) await tester.runAsync(loadTestFonts);
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final settings = AppSettings.memory();
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    final state = tester.state(find.byType(HomePage)) as dynamic;
    final c = state.controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScore.path));
    await tester.pump();
    c.playback.time.value = 20; // somewhere with music on every staff
    await tester.pump();

    // Not pumpAndSettle: the editor always has something ticking.
    Future<void> settle() async {
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
    }

    Future<void> engraved() async {
      while (c.isReengraving) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      await settle();
    }

    Future<void> shot(String name) async {
      if (dir == null) return;
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.ancestor(of: find.byType(Dialog), matching: find.byType(RepaintBoundary)).first);
        final image = await boundary.toImage(pixelRatio: 1);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    showEngraveOptionsDialog(tester.element(find.byType(HomePage)), settings, controller: c);
    await settle();
    final preview = find.descendant(of: find.byType(Dialog), matching: find.byType(Slider));
    expect(preview, findsOneWidget, reason: 'a preview, scrubbed with its own slider');
    CustomPainter painter() => tester
        .widgetList<CustomPaint>(find.descendant(of: find.byType(Dialog), matching: find.byType(CustomPaint)))
        .map((p) => p.painter)
        .firstWhere((p) => p.runtimeType.toString() == '_PreviewPainter')!;
    final before = painter();
    final width = c.score!.engraving.width;
    await shot('engrave-preview');

    await tester.enterText(find.widgetWithText(TextField, 'Search').last, 'spacingLinear');
    await settle();
    await tester.enterText(find.descendant(of: find.byType(ListView).last, matching: find.byType(TextField)), '0.95');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(c.isReengraving, isTrue);
    await engraved();
    expect(c.score!.engraving.width, greaterThan(width));
    expect(painter().shouldRepaint(before), isTrue, reason: 'the preview draws the new engraving');
    await shot('engrave-preview-changed');

    // Scrubbing moves only the preview.
    await tester.drag(preview, const Offset(200, 0));
    await settle();
    expect(c.playback.time.value, 20);
    expect(settings.engravingOptions.valueOf(EngraveOption.byKey('spacingLinear')!), 0.95);
  });
}
