// The Audio tab's MIDI tempo map, edited by mouse as a sequencer's tempo track: drag a
// change up and down (its tempo) or sideways (its place, on a beat), ⌥-drag to draw a step a
// beat, select one and Delete it; each one Undo step.
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/audio_panel.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/lanes_common.dart';
import 'package:curated_score/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';

MidiTempo _t(double quarter, double quartersPerMinute) => (quarter: quarter, quartersPerMinute: quartersPerMinute);

void main() {
  testWidgets('the MIDI tempo map is edited by dragging its changes and by drawing with ⌥', (tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
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
    expect(c.anchors.selected, {1}, reason: 'the change dragged is selected');
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

    // A click selects a change, Delete removes it; a click off the line moves the playhead.
    await tester.tapAt(Offset(x(12), y(60)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.anchors.selected, {1});
    c.deleteSelection();
    expect(c.midiTempo!.tempos, [_t(0, 135)]);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(Offset(x(6), lane().top + 10));
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.anchors.selected, isEmpty);
    expect(c.playback.time.value, closeTo(1 + 6 * 60 / 135, 0.05));
  });
}
