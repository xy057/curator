import 'dart:io';
import 'dart:ui' as ui;

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/caption_lane.dart';
import 'package:curated_score/captions_dialog.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/lanes_common.dart';
import 'package:curated_score/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'test_fonts.dart';

void main() {
  testWidgets('the Captions lane is pinned in both tabs; double-click opens the sheet, which edits them all as one step',
      (tester) async {
    await tester.runAsync(loadTestFonts);
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final dir = Platform.environment['SCREENSHOT_DIR'];
    Future<void> shot(String name, Finder inside) async {
      if (dir == null) return;
      await tester.runAsync(() async {
        final boundary =
            tester.renderObject<RenderRepaintBoundary>(find.ancestor(of: inside, matching: find.byType(RepaintBoundary)).first);
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
    expect(find.byType(CaptionLane), findsNothing, reason: 'Captions is off');

    settings.captions = true;
    await tester.pumpAndSettle();
    expect(find.byType(CaptionLane), findsOneWidget);
    expect(find.descendant(of: find.byType(CaptionLane), matching: find.byIcon(Icons.more_horiz)), findsNothing,
        reason: 'no lane menu: it can\'t be moved or unpinned');
    expect(find.descendant(of: find.byType(CaptionLane), matching: find.byIcon(Icons.push_pin)), findsOneWidget);

    final bar = c.score!.timeline.measureStarts;
    c.captions.add(Caption(bar[8], bar[12], 'Strings alone'));
    c.captions.add(Caption(bar[1], bar[4], 'The horns answer'));
    await tester.pumpAndSettle();
    await shot('caption-lane', find.byType(CaptionLane));

    c.tab = BottomTab.audio;
    await tester.pumpAndSettle();
    expect(find.byType(CaptionLane), findsOneWidget, reason: 'pinned in the Audio tab too');
    c.tab = BottomTab.instruments;
    await tester.pumpAndSettle();

    // Double-click the lane's name: the sheet, rows in the order they show.
    final name = tester.getCenter(find.text('Captions').first);
    await tester.tapAt(name);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(name);
    await tester.pumpAndSettle();
    expect(find.byType(CaptionsDialog), findsOneWidget);
    final texts = find.descendant(of: find.byType(CaptionsDialog), matching: find.byType(TextField));
    expect(texts, findsNWidgets(6));
    expect(tester.widget<TextField>(texts.at(2)).controller!.text, 'The horns answer');
    expect(tester.widget<TextField>(texts.at(5)).controller!.text, 'Strings alone');

    // A bad bar: Done waits.
    await tester.enterText(texts.at(0), 'x');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Done')).onPressed, isNull);
    expect(find.textContaining('1: Type a bar'), findsOneWidget);
    await tester.enterText(texts.at(0), '2');
    await tester.enterText(texts.at(2), 'Horns');
    await tester.pump();

    // ↓ goes to the same column of the next row.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(tester.widget<TextField>(texts.at(5)).focusNode!.hasFocus, isTrue);

    // Add a row; remove the strings.
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(texts, findsNWidgets(9));
    await tester.enterText(texts.at(8), 'Tutti');
    await tester.tap(find.byIcon(Icons.close_rounded).at(1));
    await tester.pumpAndSettle();
    await shot('captions-sheet', find.byType(CaptionsDialog));
    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pumpAndSettle();

    expect([for (final x in c.captions.captions) x.text], ['Horns', 'Tutti']);
    expect(c.captions.captions.first.start, bar[1]);
    expect(c.captions.captions.last.start, bar[12], reason: 'the new row follows the last');
    c.undo();
    expect([for (final x in c.captions.captions) x.text], ['Strings alone', 'The horns answer'], reason: 'one step');
  });

  testWidgets('captions are regions in their lane: drawn, moved, trimmed, double-clicked, deleted and erased', (tester) async {
    await tester.runAsync(loadTestFonts);
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final settings = AppSettings.memory()..captions = true;
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Try the sample'));
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    for (var i = 0; i < 100 && c.score == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    final bar = c.score!.timeline.measureStarts;
    final lane = tester.getRect(find.byType(CaptionLane));
    Offset at(double quarter) =>
        Offset(lane.left + kLaneHeaderWidth + c.viewport.x(c.timeline.secondsAtQuarter(quarter)), lane.center.dy);

    // Draw: drag bars 3–7, type the text.
    c.lanes.tool = LaneTool.draw;
    await tester.dragFrom(at(bar[2] + 0.1), at(bar[6] + 0.1) - at(bar[2] + 0.1));
    await tester.pumpAndSettle();
    expect(find.text('Add Caption'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Text'), 'Oboe');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(c.captions.captions.single, Caption(bar[2], bar[6], 'Oboe'));

    // Select: move it a bar on (snapped), one Undo step.
    c.lanes.tool = LaneTool.select;
    await tester.dragFrom(at(bar[4]), at(bar[5]) - at(bar[4]));
    await tester.pumpAndSettle();
    expect(c.captions.captions.single, Caption(bar[3], bar[7], 'Oboe'));
    expect(c.captions.selected, 0);

    // Trim its end back to bar 7.
    await tester.dragFrom(at(bar[7]) - const Offset(1, 0), at(bar[6]) - at(bar[7]));
    await tester.pumpAndSettle();
    expect(c.captions.captions.single, Caption(bar[3], bar[6], 'Oboe'));

    // Double-click it: its dialog.
    await tester.tapAt(at(bar[4]));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(at(bar[4]));
    await tester.pumpAndSettle();
    expect(find.text('Caption'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Text'), 'Oboe solo');
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await tester.pumpAndSettle();
    expect(c.captions.captions.single.text, 'Oboe solo');

    // Erase its middle bar: two, each with the text.
    c.lanes.tool = LaneTool.erase;
    await tester.dragFrom(at(bar[4] + 0.1), at(bar[5] - 0.1) - at(bar[4] + 0.1));
    await tester.pumpAndSettle();
    expect(c.captions.captions, [Caption(bar[3], bar[4], 'Oboe solo'), Caption(bar[5], bar[6], 'Oboe solo')]);
    c.undo();
    expect(c.captions.captions.single, Caption(bar[3], bar[6], 'Oboe solo'), reason: 'one step');

    // Delete removes the selected one.
    c.lanes.tool = LaneTool.select;
    await tester.tapAt(at(bar[4]));
    await tester.pump(const Duration(milliseconds: 500));
    expect(c.captions.selected, 0);
    c.deleteSelection();
    expect(c.captions.captions, isEmpty);
  });
}
