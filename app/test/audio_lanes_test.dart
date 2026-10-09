// The Audio tab's anchors, by mouse: click, ⇧-click, ⌘-click, drag, box-select, ⌥-click to
// add, a click on the waveform to scrub, double-click to type a position; and tapping along.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/audio_panel.dart';
import 'package:curated_score/audio_track.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/lanes_common.dart';
import 'package:curated_score/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';

/// 30 s of silence with one note starting at [onset] seconds, 1000 samples a second.
Future<Waveform> oneNote(double onset) {
  final samples = Float32List(30000);
  final random = math.Random(1);
  for (var i = (onset * 1000).round(); i < (onset + 0.4) * 1000; i++) {
    samples[i] = (random.nextDouble() * 2 - 1) * 0.8;
  }
  return Waveform.analyze(samples, 1000);
}

void main() {
  testWidgets('anchors are selected, moved, added and retyped with the mouse; tapping along adds them', (tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CuratedScoreApp(settings: AppSettings.memory()));
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScore.path));
    final waveform = (await tester.runAsync(() => oneNote(13.25)))!;
    expect(waveform.onsets, isNotEmpty);
    c.audio.debugTrack = AudioTrack.forTesting(name: 'take.flac', length: 30, waveform: waveform);
    c.tab = BottomTab.audio;
    final sync = c.sync!, starts = sync.measureStarts;
    c.beginEdit();
    sync.load([for (var bar = 0; bar < 6; bar++) SyncAnchor(starts[bar], 1.0 + bar * 2)]); // bars 1–6, every 2 s
    c.endEdit();
    c.anchors.select(null);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200)); // past the tab's transition
    }

    Rect lanes() => tester.getRect(find.byType(AudioLanes));
    double x(double seconds) => lanes().left + kLaneHeaderWidth + c.viewport.x(seconds);
    Offset anchor(int i) => Offset(x(sync.anchors[i].seconds), lanes().top + 15);
    Offset wave(double seconds) => Offset(x(seconds), lanes().top + 80);
    expect(x(14), lessThan(lanes().right), reason: 'the first 14 s are in view');
    Future<void> click(Offset at, [LogicalKeyboardKey? holding]) async {
      if (holding != null) await tester.sendKeyDownEvent(holding);
      await tester.tapAt(at);
      if (holding != null) await tester.sendKeyUpEvent(holding);
      await tester.pump(const Duration(milliseconds: 400)); // no double-click with the next
    }

    // Click, ⇧-click extends, ⌘-click (Ctrl here) toggles.
    await click(anchor(2));
    expect(c.anchors.selected, {2});
    await click(anchor(4), LogicalKeyboardKey.shiftLeft);
    expect(c.anchors.selected, {2, 3, 4});
    await click(anchor(3), LogicalKeyboardKey.controlLeft);
    expect(c.anchors.selected, {2, 4});

    // Dragging one moves the selection together, as one Undo step.
    final before = sync.anchors;
    await tester.dragFrom(anchor(4), Offset(x(9.5) - x(9), 0));
    await tester.pump(const Duration(milliseconds: 400));
    expect(sync.anchors[2].seconds, closeTo(5.5, 0.02));
    expect(sync.anchors[4].seconds, closeTo(9.5, 0.02));
    expect(sync.anchors[3].seconds, 7, reason: 'not selected');
    c.undo();
    expect(sync.anchors, before);

    // A drag across the anchor lane box-selects.
    await tester.dragFrom(Offset(x(2.5), lanes().top + 15), Offset(x(7.5) - x(2.5), 0));
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.anchors.selected, {1, 2, 3});

    // ⌥-click adds one, on the nearest bar.
    await click(wave(12.9), LogicalKeyboardKey.altLeft);
    expect(sync.anchors, hasLength(7));
    expect(sync.anchors.last.quarter, starts[6]);

    // A click on the waveform moves the playhead, and lets go of the selection.
    c.anchors.select(0);
    await click(wave(4.2));
    expect(c.playback.time.value, closeTo(4.2, 0.02));
    expect(c.anchors.selected, isEmpty);

    // Double-click an anchor: type where it is.
    await tester.tapAt(anchor(3));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(anchor(3));
    await tester.pumpAndSettle();
    expect(find.text('Anchor'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'At'), '4.2');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Set'));
    await tester.pumpAndSettle();
    expect(sync.anchors[3].quarter, starts[3] + 1.5, reason: 'bar 4, second beat');

    // Tapping along: the first tap plays, each next one marks the bar sounding, snapped to the
    // note heard nearby.
    c.anchors.tap();
    expect(c.playback.isPlaying, isTrue);
    c.playback.seek(13.2);
    c.anchors.tap();
    c.playback.pause();
    final tapped = sync.anchors.singleWhere((a) => (a.seconds - 13.25).abs() < 0.05);
    expect(tapped.seconds, closeTo(waveform.onsets.first, 1e-9), reason: 'on the onset, not the tap');
    expect(c.anchors.selected, {sync.anchors.indexOf(tapped)});
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('a dragged anchor stays under the pointer when the view scrolls under it', (tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CuratedScoreApp(settings: AppSettings.memory()));
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScore.path));
    c.audio.debugTrack = AudioTrack.forTesting(name: 'take.flac', length: 30, waveform: (await tester.runAsync(() => oneNote(25)))!);
    c.tab = BottomTab.audio;
    final sync = c.sync!, starts = sync.measureStarts;
    sync.load([for (var bar = 0; bar < 6; bar++) SyncAnchor(starts[bar], 1.0 + bar * 2)]); // bars 1–6, every 2 s
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200)); // past the tab's transition
    }

    Rect lanes() => tester.getRect(find.byType(AudioLanes));
    double x(double seconds) => lanes().left + kLaneHeaderWidth + c.viewport.x(seconds);
    final g = await tester.startGesture(Offset(x(5), lanes().top + 15)); // anchor 2
    await g.moveTo(Offset(x(5.5), lanes().top + 15));
    await tester.pump();
    expect(sync.anchors[2].seconds, closeTo(5.5, 0.02));
    // The view pages on (as it follows the playhead): the same point on screen is later now.
    final origin = c.viewport.origin;
    c.viewport.pan(c.viewport.pxPerSec);
    final later = c.viewport.origin - origin;
    expect(later, greaterThan(0.5));
    await g.moveBy(const Offset(1, 0));
    await tester.pump();
    final under = c.viewport.seconds(c.viewport.x(5.5 + later) + 1);
    expect(sync.anchors[2].seconds, closeTo(under, 0.02), reason: 'still under the pointer');
    await g.up();
    await tester.pump(const Duration(milliseconds: 400));
  });
}
