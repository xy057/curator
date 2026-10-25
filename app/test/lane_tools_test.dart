// Drives the Instruments tab tools with real pointer gestures.
// With SCREENSHOT_DIR set, also saves PNGs of the lanes mid-drag for visual review.

import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/timeline_panel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';
import 'test_fonts.dart';
import 'window.dart';

void main() {
  testWidgets('draw, erase, box-select and nudge in the instrument lanes', (tester) async {
    if (screenshotDir != null) await tester.runAsync(loadTestFonts);
    final c = await _openDemo(tester);
    c.curation!.clearAll();
    await tester.pump();

    final ids = [for (final p in c.score!.metadata.parts) p.id];
    final bars = c.timeline.measureStarts;
    final at = _laneSpots(tester, c);

    // Draw (D): one drag down four lanes shows all of them from bar 3 to bar 7.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    expect(c.lanes.tool, LaneTool.draw);
    var g = await tester.startGesture(at(1, bars[2]));
    await g.moveTo(at(3, bars[5]));
    await g.moveTo(at(4, bars[6]));
    await tester.pump();
    await screenshot(tester, 'lanes-drawing');
    await g.up();
    await tester.pump();
    for (final i in [1, 2, 3, 4]) {
      expect(c.curation!.lane(ids[i]), [Region(bars[2], bars[6])], reason: 'lane $i');
    }
    expect(c.curation!.lane(ids[0]), isEmpty);
    expect(c.curation!.lane(ids[5]), isEmpty);

    // A click the system takes back (the pointer cancelled) draws nothing.
    final before = c.curation!.lane(ids[7]);
    g = await tester.startGesture(at(7, bars[9]));
    await g.cancel();
    await tester.pump();
    expect(c.curation!.lane(ids[7]), before);

    // Erase (E): zoomed out too far to tell beats apart, a click hides one bar, splitting the region.
    final fitted = c.viewport.pxPerSec;
    c.viewport.zoom(0.25, 0);
    await tester.pump();
    expect((c.timeline.secondsAtQuarter(1.5) - c.timeline.secondsAtQuarter(0)) * c.viewport.pxPerSec, lessThan(14));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.tapAt(at(2, (bars[3] + bars[4]) / 2));
    await tester.pump();
    expect(c.curation!.lane(ids[2]), [Region(bars[2], bars[3]), Region(bars[4], bars[6])]);
    c.viewport.zoom(fitted / c.viewport.pxPerSec, 0);
    await tester.pump();

    // Zoomed in until beats can be told apart, a click erases just one beat (6/8: a dotted crotchet).
    final fit = c.viewport.pxPerSec;
    c.viewport.zoom(8, 0);
    await tester.pump();
    expect((c.timeline.secondsAtQuarter(1.5) - c.timeline.secondsAtQuarter(0)) * c.viewport.pxPerSec, greaterThanOrEqualTo(14));
    await tester.tapAt(at(1, bars[3] + 2)); // inside beat 2 of bar 4
    await tester.pump();
    expect(c.curation!.lane(ids[1]), [Region(bars[2], bars[3] + 1.5), Region(bars[4], bars[6])]);
    c.undo();
    c.viewport.zoom(fit / c.viewport.pxPerSec, 0);
    await tester.pump();

    // Select (V): ⇧-drag box-selects across lanes, then → moves the selection a bar.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    g = await tester.startGesture(at(3, bars[1]));
    await g.moveTo(at(4, bars[3]));
    await tester.pump();
    await screenshot(tester, 'lanes-box-select');
    await g.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(c.lanes.selected, {
      (partId: ids[3], region: Region(bars[2], bars[6])),
      (partId: ids[4], region: Region(bars[2], bars[6])),
    });
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(c.curation!.lane(ids[3]), [Region(bars[3], bars[7])]);
    expect(c.curation!.lane(ids[4]), [Region(bars[3], bars[7])]);
    expect(c.curation!.lane(ids[1]), [Region(bars[2], bars[6])]); // not selected: stays
    expect(find.textContaining('2 regions in 2 lanes'), findsOneWidget);
    await screenshot(tester, 'lanes-selected');

    // Dragging one selected region's start edge trims both.
    g = await tester.startGesture(at(3, bars[3]));
    await g.moveTo(at(3, bars[4]));
    await g.up();
    await tester.pump();
    expect(c.curation!.lane(ids[3]), [Region(bars[4], bars[7])]);
    expect(c.curation!.lane(ids[4]), [Region(bars[4], bars[7])]);
    // Let go, the cursor says what is under the pointer: the edge just trimmed, not the arrow.
    final lanesCursor = find.descendant(
        of: find.byType(InstrumentLanes), matching: find.byWidgetPredicate((w) => w is MouseRegion && w.onHover != null));
    expect(tester.widget<MouseRegion>(lanesCursor.first).cursor, SystemMouseCursors.resizeLeftRight);

    // Each gesture was one undo step.
    c.undo();
    expect(c.curation!.lane(ids[4]), [Region(bars[3], bars[7])]);

    // Clicking a lane name selects the whole lane, at once: no waiting for a second click.
    Finder name(int i) => find.text(c.partName(c.score!.metadata.parts[i]));
    await tester.tap(name(2), kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(c.lanes.selected, hasLength(2));
    expect(c.lanes.selectedPartIds, {ids[2]});
    await tester.pump(const Duration(milliseconds: 400));

    // A lane with nothing in it can be selected too, and ↓ moves the selection on.
    expect(c.curation!.lane(ids[5]), isEmpty);
    await tester.tap(name(5), kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(c.lanes.selectedPartIds, {ids[5]});
    expect(c.lanes.selected, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(c.lanes.selectedPartIds, {ids[6]});
    await tester.pump(const Duration(milliseconds: 400));

    // ⌘-click: every lane from the one last clicked, up or down; ⇧-click adds one.
    c.curation!.setLanes({for (final id in ids.take(8)) id: [Region(bars[0], bars[1])]});
    await tester.tap(name(1), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 400));
    final command = defaultTargetPlatform == TargetPlatform.macOS ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;
    await tester.sendKeyDownEvent(command);
    await tester.tap(name(4), kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(c.lanes.selectedPartIds, {ids[1], ids[2], ids[3], ids[4]});
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(name(0), kind: PointerDeviceKind.mouse); // from the same lane, the other way
    await tester.pump();
    expect(c.lanes.selectedPartIds, {ids[0], ids[1]});
    await tester.sendKeyUpEvent(command);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(name(6), kind: PointerDeviceKind.mouse);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(c.lanes.selectedPartIds, {ids[0], ids[1], ids[6]});
  });

  testWidgets('dragging regions moves them freely across lanes as well as along them', (tester) async {
    final c = await _openDemo(tester);

    final ids = [for (final p in c.score!.metadata.parts) p.id];
    final bars = c.timeline.measureStarts;
    final at = _laneSpots(tester, c);
    c.curation!.clearAll();
    c.curation!.setLanes({
      ids[1]: [Region(bars[2], bars[4])],
      ids[4]: [Region(bars[6], bars[8])],
    });
    await tester.pump();

    // One diagonal drag: two lanes down and a bar later, passing over lane 2 on the way.
    var g = await tester.startGesture(at(1, bars[3]));
    await g.moveTo(at(2, bars[3]));
    await tester.pump();
    expect(c.curation!.lane(ids[2]), [Region(bars[2], bars[4])], reason: 'follows the pointer live');
    await g.moveTo(at(3, bars[4]));
    await g.up();
    await tester.pump();
    expect(c.curation!.lane(ids[1]), isEmpty);
    expect(c.curation!.lane(ids[2]), isEmpty, reason: 'passed over, left as it was');
    expect(c.curation!.lane(ids[3]), [Region(bars[3], bars[5])]);
    expect(c.lanes.selected, {(partId: ids[3], region: Region(bars[3], bars[5]))});

    // Dropped onto a lane with a region it touches: they merge, and the result stays selected.
    g = await tester.startGesture(at(3, bars[4]));
    await g.moveTo(at(4, bars[5]));
    await g.up();
    await tester.pump();
    expect(c.curation!.lane(ids[3]), isEmpty);
    expect(c.curation!.lane(ids[4]), [Region(bars[4], bars[8])]);
    expect(c.lanes.selected, {(partId: ids[4], region: Region(bars[4], bars[8]))});

    // Each drag is one undo step.
    c.undo();
    expect(c.curation!.lane(ids[3]), [Region(bars[3], bars[5])]);
    expect(c.curation!.lane(ids[4]), [Region(bars[6], bars[8])]);

    // A multi-lane selection moves as a block and stops at the top lane.
    c.curation!.setLane(ids[2], [Region(bars[0], bars[1])]);
    c.lanes.selectMany([
      (partId: ids[2], region: Region(bars[0], bars[1])),
      (partId: ids[3], region: Region(bars[3], bars[5])),
    ]);
    await tester.pump();
    final mid = (bars[3] + bars[4]) / 2; // not where the last drag began: that would be a double-click
    g = await tester.startGesture(at(3, mid));
    await g.moveTo(at(0, mid));
    await g.up();
    await tester.pump();
    expect(c.curation!.lane(ids[0]), [Region(bars[0], bars[1])]);
    expect(c.curation!.lane(ids[1]), [Region(bars[3], bars[5])]);
    expect(c.curation!.lane(ids[2]), isEmpty);
    expect(c.curation!.lane(ids[3]), isEmpty);

    // ↑/↓ move the selection, not the regions: lanes 0 and 1 selected become lanes 1 and 2,
    // whole; ↑ at the top lane does nothing.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(c.curation!.lane(ids[0]), [Region(bars[0], bars[1])], reason: 'the regions stay');
    expect(c.curation!.lane(ids[1]), [Region(bars[3], bars[5])]);
    expect(c.lanes.selectedPartIds, {ids[1], ids[2]});
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(c.lanes.selectedPartIds, {ids[0], ids[1]});
    expect(c.curation!.lane(ids[0]), [Region(bars[0], bars[1])]);
  });

  testWidgets('the Spacers lane draws, moves, trims and erases horizontal spacers as the lanes do regions', (tester) async {
    final c = await _openDemo(tester);
    c.setExtension('attachImage', true);
    await tester.pump();
    final bars = c.timeline.measureStarts;
    final lane = tester.getRect(find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter.runtimeType.toString() == '_SpanLanePainter'));
    Offset at(double quarter) => lane.topLeft + Offset(c.viewport.x(c.timeline.secondsAtQuarter(quarter)), 12);
    List<(double, double)> spans() => [for (final (i, _) in c.spacers.horizontal.indexed) (c.spacers.startOf(i), c.spacers.endOf(i))];
    Future<void> drag(double from, double to) async {
      final g = await tester.startGesture(at(from));
      await g.moveTo(at((from + to) / 2));
      await g.moveTo(at(to));
      await tester.pump();
      await g.up();
      await tester.pump();
      while (c.isReengraving) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
    }

    // Draw (D): bar 3 widened, and selected.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    await drag(bars[2], bars[3]);
    expect(spans(), [(bars[2], bars[3])]);
    expect(c.spacers.selectedHorizontal, 0);
    expect(c.score!.gaps, c.spacers.horizontal, reason: 'engraved');

    // Select (V): moved a bar on by its middle, its end trimmed a bar further; each one Undo step.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await drag((bars[2] + bars[3]) / 2, (bars[3] + bars[4]) / 2);
    expect(spans(), [(bars[3], bars[4])]);
    await drag(bars[4], bars[5]);
    expect(spans(), [(bars[3], bars[5])]);
    expect(c.spacers.horizontal.single.width, HorizontalSpacer.defaultWidth);

    // Erase (E): its first bar cut off, the rest as wide.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await drag(bars[3], bars[4]);
    expect(spans(), [(bars[4], bars[5])]);
    c.undo();
    expect(spans(), [(bars[3], bars[5])]);
  });
}


/// The desktop window with the demo open in the editor.
Future<EditorController> _openDemo(WidgetTester tester) async {
  desktopWindow(tester);
  await tester.pumpWidget(const CuratedScoreApp());
  final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
  await tester.runAsync(() => c.openFile(demoScore.path));
  await tester.pump();
  await tester.pump();
  return c;
}

/// Where [quarter] is in lane [lane] of the instrument lanes as they are now (26 px a lane);
/// it follows the view's zoom and scroll.
Offset Function(int lane, double quarter) _laneSpots(WidgetTester tester, EditorController c) {
  final lanes = tester.getRect(find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter.runtimeType.toString() == '_LanesPainter'));
  return (lane, quarter) => lanes.topLeft + Offset(c.viewport.x(c.timeline.secondsAtQuarter(quarter)), lane * 26.0 + 12);
}
