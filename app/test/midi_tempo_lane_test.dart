// The Audio tab's MIDI tempo map, edited by mouse as a sequencer's tempo track: drag a
// change up and down (its tempo) or sideways (its place, on a beat), ⌥-drag to draw a step a
// beat, select one and Delete it; each one Undo step.
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/audio_panel.dart';
import 'package:curated_score/dialog_kit.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/lanes_common.dart';
import 'package:curated_score/main.dart';
import 'package:flutter/material.dart' show ScaffoldMessenger;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';
import 'window.dart';

MidiTempo _t(double quarter, double quartersPerMinute) => (quarter: quarter, quartersPerMinute: quartersPerMinute);

void main() {
  testWidgets('the MIDI tempo map is edited by dragging its changes and by drawing with ⌥', (tester) async {
    desktopWindow(tester);
    await tester.pumpWidget(CuratedScoreApp(settings: AppSettings.memory()));
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScore.path));
    c.tab = BottomTab.audio;
    // The demo is in 6/8: a beat is 1.5 quarters, so 135 quarters a minute is 90 beats, 90 is 60.
    final original = MidiTempoMap('tempo.mid', [_t(0, 135), _t(12, 90)]);
    c.useMidiTempo(original);
    c.anchors.setStart(1);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200)); // past the tab's transition
    }

    Rect lane() => tester.getRect(find.byType(AudioLanes));
    double x(double quarter) => lane().left + kLaneHeaderWidth + c.viewport.x(1 + c.midiTempo!.secondsAt(quarter));
    // The lane fits 60–90 beats a minute between its margins (24 px below, 30 above).
    double y(double bpm) => lane().bottom - 24 - (bpm - 60) / 30 * (lane().height - 54);
    expect(x(16), lessThan(lane().right), reason: 'the changes are in view');

    // Up: the change's tempo, to whole beats a minute, as one Undo step.
    await tester.dragFrom(Offset(x(12), y(60)), Offset(0, y(70) - y(60)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.midiTempo!.tempos, [_t(0, 135), _t(12, 105)]);
    expect(c.sync!.secondsAtQuarter(15), closeTo(1 + 12 * 60 / 135 + 3 * 60 / 105, 1e-6), reason: 'the sync follows');
    expect(c.anchors.selectedTempo, 1, reason: 'the change dragged is selected');
    c.undo();
    expect(c.midiTempo, original);
    await tester.pump(const Duration(milliseconds: 400));

    // Sideways: its place, on the nearest beat. Two seconds at 135 a minute are 4.5 quarters.
    final from = x(12), twoSeconds = c.viewport.x(3) - c.viewport.x(1);
    var gesture = await tester.startGesture(Offset(from, y(60)));
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(Offset(from + twoSeconds * i / 10, y(60)));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.midiTempo!.tempos, [_t(0, 135), _t(16.5, 90)]);
    c.undo();
    expect(c.midiTempo, original);
    await tester.pump(const Duration(milliseconds: 400));

    // Dragged past the change before it, it stops at the beat after that one (a beat is 1.5
    // quarters), and past the one after it at the beat before.
    final beforeStart = x(0);
    gesture = await tester.startGesture(Offset(from, y(60)));
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(Offset(from + (beforeStart - 40 - from) * i / 10, y(60)));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.midiTempo!.tempos, [_t(0, 135), _t(1.5, 90)]);
    c.undo();
    c.editMidiTempo(MidiTempoMap('tempo.mid', [_t(0, 135), _t(6, 135), _t(12, 90)]));
    await tester.pump(const Duration(milliseconds: 400));
    final six = x(6), past = x(14);
    gesture = await tester.startGesture(Offset(six, y(90)));
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(Offset(six + (past - six) * i / 10, y(90)));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.midiTempo!.tempos, [_t(0, 135), _t(10.5, 135), _t(12, 90)]);
    c.undo();
    c.undo();
    expect(c.midiTempo, original);
    await tester.pump(const Duration(milliseconds: 400));

    // The step after a change, taken anywhere along it, sets only its tempo.
    await tester.dragFrom(Offset((x(0) + x(12)) / 2, y(90)), Offset(30, y(80) - y(90)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.midiTempo!.tempos, [_t(0, 120), _t(12, 90)]);
    c.undo();
    await tester.pump(const Duration(milliseconds: 400));

    // ⌥-drag draws a step at each beat crossed, at the height drawn; the change after the
    // drawing (bar 3) holds.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    gesture = await tester.startGesture(Offset(x(3.2), y(80)));
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(Offset(x(3.2) + (x(6.2) - x(3.2)) * i / 10, y(80)));
      await tester.pump();
    }
    await gesture.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.midiTempo!.tempos, [_t(0, 135), _t(3, 120), _t(12, 90)], reason: 'repeats of 80 a beat are left out');
    c.undo();
    expect(c.midiTempo, original, reason: 'one Undo step');
    await tester.pump(const Duration(milliseconds: 400));

    // The pointer is read on the map as the drawing began: drawing much slower moves the beats
    // after it later, but not those under a pointer drawing on (the same beats as at 135), so
    // drawing to past the change at 12 replaces it.
    final drawStart = x(3.2), drawEnd = x(12.5);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    gesture = await tester.startGesture(Offset(drawStart, y(60)));
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(Offset(drawStart + (drawEnd - drawStart) * i / 10, y(60)));
      await tester.pump();
    }
    await gesture.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.midiTempo!.tempos, [_t(0, 135), _t(3, 90)]);
    c.undo();
    expect(c.midiTempo, original);
    await tester.pump(const Duration(milliseconds: 400));

    // ⌥-click on the line adds a change at the nearest beat, keeping the tempo there; it is
    // selected and dragged as any other.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.tapAt(Offset(x(6.2), y(90)));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.midiTempo!.tempos, [_t(0, 135), _t(6, 135), _t(12, 90)]);
    expect(c.anchors.selectedTempo, 1);
    await tester.dragFrom(Offset(x(6), y(90)), Offset(0, y(80) - y(90)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.midiTempo!.tempos, [_t(0, 135), _t(6, 120), _t(12, 90)]);
    c.undo();
    c.undo();
    expect(c.midiTempo, original, reason: 'adding and dragging: an Undo step each');
    await tester.pump(const Duration(milliseconds: 400));

    // A click selects a change, Delete removes it; a click off the line moves the playhead.
    await tester.tapAt(Offset(x(12), y(60)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.anchors.selectedTempo, 1);
    c.commands.delete();
    expect(c.midiTempo!.tempos, [_t(0, 135)]);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(Offset(x(6), lane().top + 10));
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.anchors.selectedTempo, isNull);
    expect(c.playback.time.value, closeTo(1 + 6 * 60 / 135, 0.05));

    // A warp is a line across the lane: double-click it to change where it jumps; an empty
    // jump removes it. The bar 5 the file reaches at its quarter 12 jumps back to bar 1.
    c.undo(); // the change Delete removed
    expect(c.setMidiWarps([(at: 12, jumpTo: 0)]), isTrue);
    expect(c.sync!.passes, hasLength(2));
    await tester.pump(const Duration(milliseconds: 400));
    final warpX = lane().left + kLaneHeaderWidth + c.viewport.x(c.sync!.anchors.firstWhere((a) => a.isWarp).seconds);
    await tester.tapAt(Offset(warpX, lane().top + 40));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(Offset(warpX, lane().top + 40));
    await tester.pumpAndSettle();
    expect(find.text('Warp'), findsOneWidget);
    await tester.enterText(find.descendant(of: find.byType(AppDialog), matching: find.byType(EditableText)).at(1), ''); // At, then Jump to
    await tester.pump();
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();
    expect(c.midiTempo!.warps, isEmpty);
    expect(c.sync!.passes, hasLength(1));

    // A damaged project's warp that doesn't fit the score is left out, the one before it still
    // followed and shown; editing that one lets the other go.
    c.editMidiTempo(c.midiTempo!.withWarps([(at: 12, jumpTo: 0), (at: 1e5, jumpTo: 0)]));
    expect(c.sync!.passes, hasLength(2));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(Offset(warpX + 100, lane().top + 40)); // not a double-click with the last ones
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(Offset(warpX, lane().top + 40));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(Offset(warpX, lane().top + 40));
    await tester.pumpAndSettle();
    await tester.enterText(find.descendant(of: find.byType(AppDialog), matching: find.byType(EditableText)).at(1), '');
    await tester.pump();
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();
    expect(c.midiTempo!.warps, isEmpty);
  });

  testWidgets('Warps from score gives the map the score’s repeats, one Undo step', (tester) async {
    desktopWindow(tester);
    await tester.pumpWidget(CuratedScoreApp(settings: AppSettings.memory()));
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScoreRepeated().path));
    c.tab = BottomTab.audio;
    c.useMidiTempo(MidiTempoMap('tempo.mid', [_t(0, 135)]));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200)); // past the tab's transition
    }

    final button = find.byTooltip('Warps from score');
    expect(button, findsOneWidget);
    await tester.tap(button);
    await tester.pump();
    expect(c.midiTempo!.warps, c.scoreWarps);
    expect(c.scoreWarps, isNotEmpty);
    await tester.tap(button, warnIfMissed: false);
    await tester.pump();
    c.undo();
    expect(c.midiTempo!.warps, isEmpty, reason: 'one Undo step; a second tap, with them in place, did nothing');

    // A file read says where its warps came from, and Remove takes them off (one Undo step).
    expect(c.useScoreWarps(), isTrue);
    showMidiWarpsTaken(tester.element(find.byType(HomePage)), c, (from: MidiWarpsFrom.score, count: 1, file: null));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // slid in
    expect(find.text('1 warp from the score’s repeats'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await tester.pump();
    expect(c.midiTempo!.warps, isEmpty);
    c.undo();
    expect(c.midiTempo!.warps, c.scoreWarps);
    ScaffoldMessenger.of(tester.element(find.byType(HomePage))).removeCurrentSnackBar();
    await tester.pump(const Duration(milliseconds: 400));

    c.useMidiTempo(null);
    await tester.pump(const Duration(milliseconds: 400));
    expect(button, findsNothing, reason: 'only with a MIDI tempo map');
  });

  testWidgets('Undo in the middle of a drag ends it, and Undo goes on recording after', (tester) async {
    desktopWindow(tester);
    await tester.pumpWidget(CuratedScoreApp(settings: AppSettings.memory()));
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScore.path));
    c.tab = BottomTab.audio;
    final original = MidiTempoMap('tempo.mid', [_t(0, 135), _t(12, 90)]);
    c.useMidiTempo(original);
    c.anchors.setStart(1);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    Rect lane() => tester.getRect(find.byType(AudioLanes));
    double x(double quarter) => lane().left + kLaneHeaderWidth + c.viewport.x(1 + c.midiTempo!.secondsAt(quarter));
    double y(double bpm) => lane().bottom - 24 - (bpm - 60) / 30 * (lane().height - 54);

    // Undone mid-drag: the drag stops there, and doesn't bring back what it began from.
    await tester.dragFrom(Offset(x(12), y(60)), Offset(0, y(70) - y(60)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.midiTempo!.tempos, [_t(0, 135), _t(12, 105)]);
    // The lane now fits 70–90: the change, at 70, is at its bottom margin.
    var gesture = await tester.startGesture(Offset(x(12), lane().bottom - 24));
    expect(c.anchors.selectedTempo, 1, reason: 'the change is taken');
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    c.undo();
    await tester.pump();
    expect(c.midiTempo, original);
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.midiTempo, original, reason: 'the drag ended with the Undo');

    // Undone back past the MIDI file mid-drag, the lane goes; Undo still records what follows.
    gesture = await tester.startGesture(Offset(x(12), y(60)));
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    while (c.midiTempo != null && c.canUndo) {
      c.undo(); // Starts at, then using the file
    }
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.midiTempo, isNull);
    expect(find.byType(AudioLanes), findsOneWidget);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    c.useMidiTempo(original);
    c.undo();
    expect(c.midiTempo, isNull, reason: 'using the file again was an Undo step of its own');
  });
}
