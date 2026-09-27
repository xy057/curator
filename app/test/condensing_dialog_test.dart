// Drives the Condensing dialog (Instruments toolbar ▸ merge button) with real taps.
// With SCREENSHOT_DIR set, also saves a PNG of the dialog for visual review.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';
import 'test_fonts.dart';

void main() {
  testWidgets('the Condensing dialog condenses built-in pairs, and makes and removes pairs of your own', (tester) async {
    final dir = Platform.environment['SCREENSHOT_DIR'];
    if (dir != null) await tester.runAsync(loadTestFonts);
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const CuratedScoreApp());
    final state = tester.state(find.byType(HomePage)) as dynamic;
    final c = state.controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScore.path));
    await tester.pump();
    await tester.pump();
    // Not pumpAndSettle: the editor always has something ticking.
    Future<void> settle() async {
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
    }

    // The engraving runs for real; what follows it runs in the test's clock, so pump too.
    Future<void> engraved() async {
      while (c.isReengraving) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
    }

    await tester.tap(find.byIcon(Icons.merge_type_rounded));
    await settle();
    final dialog = find.byType(AlertDialog);
    expect(find.descendant(of: dialog, matching: find.byType(CheckboxListTile)), findsNWidgets(7)); // "All pairs" and 6
    expect(find.text('Flute 1.2'), findsOneWidget);

    // A built-in pair's box condenses it.
    await tester.tap(find.text('Flute 1.2'));
    await tester.pump();
    expect(c.condensed, {'cond-P2-P3'});

    // Flute 1 + Oboe 1.
    await tester.tap(find.text('Player').first);
    await settle();
    await tester.tap(find.text('Flute 1').last);
    await settle();
    await tester.tap(find.text('Player'));
    await settle();
    await tester.tap(find.text('Oboe 1').last);
    await settle();
    expect(find.text('Flute 1.2 and Oboe 1.2 will be split.'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pump();
    expect(c.pairs, const [PlayerPair('P2', 'P4')]);
    await engraved();
    await settle();
    expect(find.descendant(of: dialog, matching: find.text('Flute 1 + Oboe 1')), findsOneWidget);
    expect(c.laneName(c.score!.metadata.parts[1]), 'Flute 1 + Oboe 1', reason: 'one lane for the pair');
    if (dir != null) {
      await tester.runAsync(() async {
        // The whole window, the dialog included (its layer is in physical pixels).
        final view = tester.binding.renderViews.first;
        final image = await (view.debugLayer! as OffsetLayer).toImage(Offset.zero & tester.view.physicalSize);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/condensing-dialog.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }
    expect(find.descendant(of: dialog, matching: find.text('Flute 1.2')), findsNothing, reason: 'Flute 1 left the built-in pair');
    expect(c.score!.condensed.map((g) => g.id), contains('cond-P2-P4'));

    // Removing it brings the built-in pairs back.
    await tester.tap(find.byTooltip('Remove this pair'));
    await tester.pump();
    await engraved();
    await settle();
    expect(c.pairs, isEmpty);
    expect(find.descendant(of: dialog, matching: find.text('Flute 1.2')), findsOneWidget);
    expect(c.condensed, contains('cond-P2-P3'), reason: 'back as it was before');

    // "All pairs": some are ticked, so it ticks every one; then none.
    await tester.tap(find.text('All pairs'));
    await tester.pump();
    expect(c.condensed, hasLength(6));
    await tester.tap(find.text('All pairs'));
    await tester.pump();
    expect(c.condensed, isEmpty);
    await tester.tap(find.text('Done'));
    await settle();
    expect(dialog, findsNothing);
  });
}
