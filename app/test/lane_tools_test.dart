// Drives the Instruments tab tools with real pointer gestures.
// With SCREENSHOT_DIR set, also saves PNGs of the lanes mid-drag for visual review.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/timeline_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';
import 'test_fonts.dart';


void main() {
  testWidgets('draw, erase, box-select and nudge in the instrument lanes', (tester) async {
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
    c.curation!.clearAll();
    await tester.pump();

    final ids = [for (final p in c.score!.metadata.parts) p.id];
    final bars = c.timeline.measureStarts;
    final lanes = tester.getRect(find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter.runtimeType.toString() == '_LanesPainter'));
    Offset at(int lane, double quarter) =>
        lanes.topLeft + Offset(c.viewport.x(c.timeline.secondsAtQuarter(quarter)), lane * 26.0 + 12);

    Future<void> shot(String name) async {
      if (dir == null) return;
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.ancestor(of: find.byType(Scaffold), matching: find.byType(RepaintBoundary)).first);
        final image = await boundary.toImage(pixelRatio: 2);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    // Draw (D): one drag down four lanes shows all of them from bar 3 to bar 7.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    expect(c.lanes.tool, LaneTool.draw);
    var g = await tester.startGesture(at(1, bars[2]));
    await g.moveTo(at(3, bars[5]));
    await g.moveTo(at(4, bars[6]));
    await tester.pump();
    await shot('lanes-drawing');
    await g.up();
    await tester.pump();
    for (final i in [1, 2, 3, 4]) {
      expect(c.curation!.lane(ids[i]), [Region(bars[2], bars[6])], reason: 'lane $i');
    }
    expect(c.curation!.lane(ids[0]), isEmpty);
    expect(c.curation!.lane(ids[5]), isEmpty);

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
    await shot('lanes-box-select');
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
    await shot('lanes-selected');

    // Dragging one selected region's start edge trims both.
    g = await tester.startGesture(at(3, bars[3]));
    await g.moveTo(at(3, bars[4]));
    await g.up();
    await tester.pump();
    expect(c.curation!.lane(ids[3]), [Region(bars[4], bars[7])]);
    expect(c.curation!.lane(ids[4]), [Region(bars[4], bars[7])]);

    // Each gesture was one undo step.
    c.undo();
    expect(c.curation!.lane(ids[4]), [Region(bars[3], bars[7])]);

    // Clicking a lane name selects the whole lane.
    await tester.tap(find.text(c.partName(c.score!.metadata.parts[2])));
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.lanes.selected, hasLength(2));
    expect(c.lanes.selectedPartIds, {ids[2]});
  });

  testWidgets("holding an instrument's name and dragging it moves it: Violin I to the top", (tester) async {
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

    final violin = find.text('Violin I');
    await tester.ensureVisible(violin);
    await tester.pump();
    final g = await tester.startGesture(tester.getCenter(violin), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 600)); // held: the lane lifts
    // Up to the top edge of the lanes: they scroll, and Violin I goes along.
    final top = tester.getTopLeft(find.byType(InstrumentLanes)).dy;
    await g.moveTo(Offset(tester.getCenter(violin).dx, top + 4));
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(c.isScoreOrder, isTrue, reason: 'nothing changes until it is let go');
    await _shot(tester, dir, 'lanes-moving');
    await g.up();
    await tester.pump();
    await _shot(tester, dir, 'lanes-moved');
    expect(c.laneParts.first.name, 'Violin I');
    expect(c.scene!.partOrder.first, 'P17');
    expect(c.lanes.selected, isEmpty, reason: 'holding a name is not a click on it');

    // A quick click still selects the lane, and doesn't move it.
    await tester.tap(find.text('Piccolo'), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.lanes.selectedPartIds, {'P1'});
    expect(c.laneParts[1].id, 'P1');

    c.undo();
    expect(c.isScoreOrder, isTrue);
  });

  testWidgets('dragging regions moves them freely across lanes as well as along them', (tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const CuratedScoreApp());
    final state = tester.state(find.byType(HomePage)) as dynamic;
    final c = state.controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScore.path));
    await tester.pump();
    await tester.pump();

    final ids = [for (final p in c.score!.metadata.parts) p.id];
    final bars = c.timeline.measureStarts;
    final lanes = tester.getRect(find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter.runtimeType.toString() == '_LanesPainter'));
    Offset at(int lane, double quarter) =>
        lanes.topLeft + Offset(c.viewport.x(c.timeline.secondsAtQuarter(quarter)), lane * 26.0 + 12);
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

    // ↑/↓ do the same from the keyboard; ↑ at the top lane does nothing.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(c.curation!.lane(ids[1]), [Region(bars[0], bars[1])]);
    expect(c.curation!.lane(ids[2]), [Region(bars[3], bars[5])]);
    expect(c.lanes.selected, hasLength(2));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(c.curation!.lane(ids[0]), [Region(bars[0], bars[1])]);
    expect(c.curation!.lane(ids[1]), [Region(bars[3], bars[5])]);
  });

  testWidgets('a condensed pair is one lane: drawn, erased and dragged as a whole', (tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const CuratedScoreApp());
    final state = tester.state(find.byType(HomePage)) as dynamic;
    final c = state.controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScore.path));
    await tester.pump();
    await tester.pump();

    final parts = c.score!.metadata.parts;
    final ids = [for (final p in parts) p.id];
    final a = ids.indexOf('P2'), b = ids.indexOf('P3'); // a pair that can condense
    final bars = c.timeline.measureStarts;
    final lanes = tester.getRect(find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter.runtimeType.toString() == '_LanesPainter'));
    Offset at(int lane, double quarter) =>
        lanes.topLeft + Offset(c.viewport.x(c.timeline.secondsAtQuarter(quarter)), lane * 26.0 + 12);
    List<Region> lane(int i) => c.curation!.lane(ids[i]);
    c.curation!.clearAll();
    c.curation!.setLanes({
      ids[a]: [Region(bars[2], bars[4])],
      ids[b]: [Region(bars[3], bars[6])],
    });
    final before = c.curation!.lanes;
    c.setCondensed(['cond-P2-P3'], on: true);
    await tester.pump();

    // One lane, named for both, shown wherever either player was.
    expect(c.laneParts, hasLength(parts.length - 1));
    expect(c.laneParts.map((p) => p.id), isNot(contains('P3')));
    expect(find.text(c.laneName(parts[a])), findsOneWidget);
    expect(c.laneName(parts[a]), contains('.'));
    expect(lane(a), [Region(bars[2], bars[6])]);
    expect(lane(b), [Region(bars[2], bars[6])]);

    // Erasing, drawing and dragging on it act on both players.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    var g = await tester.startGesture(at(a, bars[4]));
    await g.moveTo(at(a, bars[5]));
    await g.up();
    await tester.pump();
    expect(lane(b), [Region(bars[2], bars[4]), Region(bars[5], bars[6])]);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    g = await tester.startGesture(at(a, bars[4]));
    await g.moveTo(at(a, bars[5]));
    await g.up();
    await tester.pump();
    expect(lane(b), [Region(bars[2], bars[6])]);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    g = await tester.startGesture(at(a, bars[3]));
    await g.moveTo(at(a, bars[4]));
    await g.up();
    await tester.pump();
    expect(lane(a), [Region(bars[3], bars[7])]);
    expect(lane(b), [Region(bars[3], bars[7])]);
    expect(c.lanes.selected, {(partId: ids[a], region: Region(bars[3], bars[7]))});

    // Auto-curating the lane shows it wherever either player plays.
    c.lanes.autoCurate([ids[a]]);
    final solo = Curation(ids)..autoCurate(c.score!.metadata.activeMeasures, bars, partIds: [ids[a], ids[b]]);
    final either = Curation(['x'])..setLane('x', [...solo.lane(ids[a]), ...solo.lane(ids[b])]);
    expect(lane(a), either.lane('x'));
    expect(lane(b), either.lane('x'));

    // Apart again, each player keeps the regions; Undo goes back to before condensing.
    c.setCondensed(['cond-P2-P3'], on: false);
    await tester.pump();
    expect(c.laneParts, hasLength(parts.length));
    expect(lane(b), either.lane('x'));
    for (var i = 0; i < 6; i++) {
      c.undo(); // splitting, auto-curating, dragging, drawing, erasing, condensing
    }
    expect(c.condensed, isEmpty);
    expect(Curation.sameLanes(c.curation!.lanes, before), isTrue);
  });

  testWidgets('⌘-scroll zooms the lanes horizontally without scrolling them vertically', (tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const CuratedScoreApp());
    final state = tester.state(find.byType(HomePage)) as dynamic;
    final c = state.controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScore.path));
    await tester.pump();
    await tester.pump();

    final lanes = tester.getRect(find.byType(InstrumentLanes));
    final over = lanes.topLeft + const Offset(600, 60);
    // Re-read every time: changing the physics replaces the scroll position object.
    ScrollPosition vertical() => tester.state<ScrollableState>(
        find.descendant(of: find.byType(InstrumentLanes), matching: find.byType(Scrollable))).position;
    expect(vertical().maxScrollExtent, greaterThan(0), reason: 'needs more lanes than fit');
    final mouse = TestPointer(1, PointerDeviceKind.mouse)..hover(over);

    // Plain wheel: scrolls the lanes.
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 40)));
    await tester.pump();
    expect(vertical().pixels, greaterThan(0));
    final top = vertical().pixels;

    // ⌘ + wheel: zooms, lanes stay where they are.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    var zoom = c.viewport.pxPerSec;
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -120)));
    await tester.pump();
    expect(c.viewport.pxPerSec, greaterThan(zoom));
    expect(vertical().pixels, top);

    // ⌘ + two-finger trackpad swipe: the same.
    zoom = c.viewport.pxPerSec;
    final pad = await tester.createGesture(kind: PointerDeviceKind.trackpad);
    await pad.panZoomStart(over);
    for (var i = 1; i <= 5; i++) {
      await pad.panZoomUpdate(over, pan: Offset(0, 30.0 * i));
      await tester.pump();
    }
    await pad.panZoomEnd();
    await tester.pump();
    expect(c.viewport.pxPerSec, greaterThan(zoom));
    expect(vertical().pixels, top);

    // Released: the lanes scroll again.
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 40)));
    await tester.pump();
    expect(vertical().pixels, greaterThan(top));
  });

  testWidgets('in 6/8 the finer grid is the two dotted-crotchet beats of each bar', (tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const CuratedScoreApp());
    final state = tester.state(find.byType(HomePage)) as dynamic;
    final c = state.controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScore.path));
    await tester.pump();
    await tester.pump();
    c.curation!.clearAll();

    final ids = [for (final p in c.score!.metadata.parts) p.id];
    final bars = c.timeline.measureStarts;
    expect(bars[3] - bars[2], 3); // a 6/8 bar is three crotchets long…
    expect(c.beats.beatsIn(2), [bars[2], bars[2] + 1.5]); // …and has two beats

    // Positions count those beats.
    expect(c.beats.format(bars[2] + 1.5), '3.2');
    expect(c.beats.parse('3.2'), bars[2] + 1.5);
    expect(c.beats.parse('3.3'), isNull);

    // Zoomed in, a click erases one dotted crotchet, and drags snap to them.
    c.viewport.zoom(12, 0);
    await tester.pump();
    final lanes = tester.getRect(find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter.runtimeType.toString() == '_LanesPainter'));
    Offset at(int lane, double quarter) =>
        lanes.topLeft + Offset(c.viewport.x(c.timeline.secondsAtQuarter(quarter)), lane * 26.0 + 12);

    c.curation!.setLane(ids[0], [Region(bars[1], bars[4])]);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.tapAt(at(0, bars[2] + 2)); // inside beat 2 of bar 3
    await tester.pump();
    expect(c.curation!.lane(ids[0]), [Region(bars[1], bars[2] + 1.5), Region(bars[3], bars[4])]);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    final g = await tester.startGesture(at(1, bars[1] + 0.9)); // nearer beat 2 (1.5) than beat 1
    await g.moveTo(at(1, bars[2] + 1.1)); // nearer beat 2 of bar 3
    await g.up();
    await tester.pump();
    expect(c.curation!.lane(ids[1]), [Region(bars[1] + 1.5, bars[2] + 1.5)]);
  });
}

/// Saves the window as [name].png in [dir] (SCREENSHOT_DIR), when set.
Future<void> _shot(WidgetTester tester, String? dir, String name) async {
  if (dir == null) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.ancestor(of: find.byType(Scaffold), matching: find.byType(RepaintBoundary)).first);
    final image = await boundary.toImage(pixelRatio: 2);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$dir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
  });
}
