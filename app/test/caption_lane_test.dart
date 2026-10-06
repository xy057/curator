import 'dart:io';
import 'dart:ui' as ui;

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/caption_lane.dart';
import 'package:curated_score/captions_dialog.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/lanes_common.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/project_state.dart';
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

    // Done on a sheet left as it was changes nothing (rows show by start; the captions keep their order).
    await tester.tapAt(name);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(name);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pumpAndSettle();
    expect([for (final x in c.captions.captions) x.text], ['Strings alone', 'The horns answer']);
    expect(c.canRedo, isTrue, reason: 'no Undo step');
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
    await tester.tapAt(at(bar[5])); // not where the erase began: no double-click
    await tester.pump(const Duration(milliseconds: 500));
    expect(c.captions.selected, 0);
    expect(find.byType(AlertDialog), findsNothing);
    c.deleteSelection();
    expect(c.captions.captions, isEmpty);

    // A drawing the system cancels asks for nothing.
    c.lanes.tool = LaneTool.draw;
    final gesture = await tester.startGesture(at(bar[2] + 0.1));
    await gesture.moveTo(at(bar[5] + 0.1));
    await tester.pump();
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(find.text('Add Caption'), findsNothing);
    expect(c.captions.captions, isEmpty);
  });

  testWidgets('captions never overlap: drawing, moving and trimming stop at the next; the dialog and the sheet say so',
      (tester) async {
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
    c.captions.add(Caption(bar[4], bar[6], 'B'));

    // Draw across B: it stops where B starts.
    c.lanes.tool = LaneTool.draw;
    await tester.dragFrom(at(bar[1] + 0.1), at(bar[8] + 0.1) - at(bar[1] + 0.1));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Text'), 'A');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(c.captions.captions, [Caption(bar[4], bar[6], 'B'), Caption(bar[1], bar[4], 'A')]);

    // Drawing inside B draws nothing.
    await tester.dragFrom(at(bar[5]), at(bar[7]) - at(bar[5]));
    await tester.pumpAndSettle();
    expect(find.text('Add Caption'), findsNothing);

    // Moved on, A stays clear of B; moved back it goes. Its end trims no further than B.
    c.lanes.tool = LaneTool.select;
    await tester.dragFrom(at(bar[2]), at(bar[5]) - at(bar[2]));
    await tester.pumpAndSettle();
    expect(c.captions.captions.last, Caption(bar[1], bar[4], 'A'));
    await tester.dragFrom(at(bar[3]), at(bar[2]) - at(bar[3]));
    await tester.pumpAndSettle();
    expect(c.captions.captions.last, Caption(bar[0], bar[3], 'A'));
    await tester.tapAt(at(bar[10])); // elsewhere first: not a double-click
    await tester.pumpAndSettle();
    await tester.dragFrom(at(bar[3]) - const Offset(1, 0), at(bar[7]) - at(bar[3]));
    await tester.pumpAndSettle();
    expect(c.captions.captions.last, Caption(bar[0], bar[4], 'A'));

    // Its dialog won't run it into B.
    await tester.tapAt(at(bar[1]));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(at(bar[1]));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Until'), '6');
    await tester.pump();
    expect(find.text('Another caption is there'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Apply')).onPressed, isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Nor will the sheet.
    final name = tester.getCenter(find.text('Captions').first);
    await tester.tapAt(name);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(name);
    await tester.pumpAndSettle();
    final texts = find.descendant(of: find.byType(CaptionsDialog), matching: find.byType(TextField));
    await tester.enterText(texts.at(1), '6');
    await tester.pump();
    expect(find.textContaining('2: Overlaps row 1'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Done')).onPressed, isNull);

    // A row added fits among the rows as they are: A moved to bar 9 here, the new one stops there.
    await tester.enterText(texts.at(0), '9');
    await tester.enterText(texts.at(1), '10');
    await tester.pump();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(texts.at(6)).controller!.text, '7.1');
    expect(tester.widget<TextField>(texts.at(7)).controller!.text, '9.1');
    expect(find.textContaining('Overlaps'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // However they come, one shows at a time: the earlier ends where the next starts.
    c.captions.add(Caption(bar[5], bar[10], 'C'));
    expect(c.captions.captions.firstWhere((x) => x.text == 'B'), Caption(bar[4], bar[5], 'B'));
    final read = ProjectState.fromJson({
      'captions': [
        {'start': 0, 'end': 16, 'text': 'A'},
        {'start': 4, 'end': 8, 'text': 'B'},
      ],
    });
    expect(read.captions, const [Caption(0, 4, 'A'), Caption(4, 8, 'B')]);
  });
}
