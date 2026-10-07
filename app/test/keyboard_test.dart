// The window's keyboard shortcuts (HomePage's bindings): tools, nudging and trimming in the
// Instruments tab; tap mode, nudging and re-barring anchors, and W in the Audio tab; moving the
// playhead; Escape; Undo and Redo; Cut, Copy and Paste of regions; pasting an image.
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';

void main() {
  late EditorController c;
  late AppSettings settings;

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    settings = AppSettings.memory();
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScore.path));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key, {LogicalKeyboardKey? holding}) async {
    if (holding != null) await tester.sendKeyDownEvent(holding);
    await tester.sendKeyEvent(key);
    if (holding != null) await tester.sendKeyUpEvent(holding);
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('Instruments tab: tools, nudging, trimming to the playhead, Delete, Escape, Undo and Redo', (tester) async {
    await open(tester);
    final starts = c.score!.timeline.measureStarts;

    await press(tester, LogicalKeyboardKey.keyD);
    expect(c.lanes.tool, LaneTool.draw);
    await press(tester, LogicalKeyboardKey.keyE);
    expect(c.lanes.tool, LaneTool.erase);
    await press(tester, LogicalKeyboardKey.escape);
    expect(c.lanes.tool, LaneTool.select, reason: 'nothing selected: Escape puts the tool back');
    await press(tester, LogicalKeyboardKey.keyD);
    await press(tester, LogicalKeyboardKey.keyV);
    expect(c.lanes.tool, LaneTool.select);

    c.curation!.setLane('P1', [Region(starts[4], starts[8])]);
    c.lanes.select('P1', c.curation!.lane('P1').single);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(c.curation!.lane('P1'), [Region(starts[5], starts[9])], reason: 'a bar on');
    await press(tester, LogicalKeyboardKey.arrowLeft, holding: LogicalKeyboardKey.shiftLeft);
    expect(c.curation!.lane('P1'), [Region(starts[5] - 1.5, starts[9] - 1.5)], reason: 'a beat back (6/8)');

    c.playback.seek(c.timeline.secondsAtQuarter(starts[6]));
    await press(tester, LogicalKeyboardKey.bracketLeft);
    expect(c.curation!.lane('P1').single.start, starts[6]);
    c.playback.seek(c.timeline.secondsAtQuarter(starts[7]));
    await press(tester, LogicalKeyboardKey.bracketRight);
    expect(c.curation!.lane('P1'), [Region(starts[6], starts[7])]);

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(c.lanes.selectedPartIds, {'P2'}, reason: 'the selection moves to the lane below');
    c.lanes.select('P1', c.curation!.lane('P1').single);
    await press(tester, LogicalKeyboardKey.delete);
    expect(c.curation!.lane('P1'), isEmpty);

    await press(tester, LogicalKeyboardKey.keyZ, holding: LogicalKeyboardKey.controlLeft);
    expect(c.curation!.lane('P1'), [Region(starts[6], starts[7])]);
    await press(tester, LogicalKeyboardKey.keyY, holding: LogicalKeyboardKey.controlLeft);
    expect(c.curation!.lane('P1'), isEmpty);

    c.curation!.setLane('P1', [Region(starts[4], starts[8])]);
    c.lanes.select('P1', c.curation!.lane('P1').single);
    await press(tester, LogicalKeyboardKey.escape);
    expect(c.lanes.selected, isEmpty, reason: 'Escape lets go of the selection');

    // Cut, then paste at the playhead; Copy leaves the region.
    c.lanes.select('P1', c.curation!.lane('P1').single);
    await press(tester, LogicalKeyboardKey.keyX, holding: LogicalKeyboardKey.controlLeft);
    expect(c.curation!.lane('P1'), isEmpty);
    c.playback.seek(c.timeline.secondsAtQuarter(starts[10]));
    await press(tester, LogicalKeyboardKey.keyV, holding: LogicalKeyboardKey.controlLeft);
    expect(c.curation!.lane('P1'), [Region(starts[10], starts[14])]);
    await press(tester, LogicalKeyboardKey.keyC, holding: LogicalKeyboardKey.controlLeft);
    expect(c.curation!.lane('P1'), [Region(starts[10], starts[14])]);
    c.playback.seek(c.timeline.secondsAtQuarter(starts[20]));
    await press(tester, LogicalKeyboardKey.keyV, holding: LogicalKeyboardKey.controlLeft);
    expect(c.curation!.lane('P1'), [Region(starts[10], starts[14]), Region(starts[20], starts[24])]);
  });

  testWidgets('the playhead: Home, End, ← and → skip (⇧ less), Enter plays', (tester) async {
    await open(tester);
    c.playback.seek(20);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(c.playback.time.value, closeTo(25, 1e-6));
    await press(tester, LogicalKeyboardKey.arrowLeft, holding: LogicalKeyboardKey.shiftLeft);
    expect(c.playback.time.value, closeTo(24, 1e-6));
    await press(tester, LogicalKeyboardKey.end);
    expect(c.playback.time.value, c.playback.duration);
    await press(tester, LogicalKeyboardKey.home);
    expect(c.playback.time.value, 0);
    await press(tester, LogicalKeyboardKey.enter);
    expect(c.playback.isPlaying, isTrue);
    await press(tester, LogicalKeyboardKey.enter);
    expect(c.playback.isPlaying, isFalse);
  });

  testWidgets('Audio tab: T arms tapping and Space taps; anchors nudge, re-bar and select all; W asks for a warp',
      (tester) async {
    await open(tester);
    final sync = c.sync!, starts = sync.measureStarts;
    c.beginEdit();
    sync.load([for (var bar = 0; bar < 6; bar++) SyncAnchor(starts[bar], 1.0 + bar * 2)]);
    c.endEdit();

    await press(tester, LogicalKeyboardKey.keyT);
    expect(c.tab, BottomTab.audio);
    expect(c.anchors.tapArmed, isTrue);
    await press(tester, LogicalKeyboardKey.space);
    expect(c.playback.isPlaying, isTrue, reason: 'the first tap starts playback');
    await press(tester, LogicalKeyboardKey.escape);
    expect((c.anchors.tapArmed, c.playback.isPlaying), (false, false));

    c.anchors.select(2);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(sync.anchors[2].seconds, closeTo(5.01, 1e-9));
    await press(tester, LogicalKeyboardKey.arrowLeft, holding: LogicalKeyboardKey.shiftLeft);
    expect(sync.anchors[2].seconds, closeTo(5.009, 1e-9));
    c.anchors.select(5);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(sync.anchors[5].quarter, starts[6], reason: 'the next bar');
    c.anchors.select(3);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(sync.anchors[3].quarter, starts[3], reason: 'bar 5 is taken: refused');

    await press(tester, LogicalKeyboardKey.keyA, holding: LogicalKeyboardKey.controlLeft);
    expect(c.anchors.selected, hasLength(6));

    c.anchors.select(3);
    await press(tester, LogicalKeyboardKey.keyW);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.widgetWithText(TextField, 'Jump to'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Jump to'), '2');
    await tester.pump();
    expect(find.text('Warp'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Set'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(sync.anchors[3].jumpTo, starts[1], reason: 'after bar 4, back to bar 2');
  });

  testWidgets('pasting: nothing while Attach Image is off; with nothing to paste it says so; SVG text is an image',
      (tester) async {
    await open(tester);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('pasteboard'),
        (call) async => call.method == 'files' ? <Object?>[] : null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('pasteboard'), null));

    await press(tester, LogicalKeyboardKey.keyV, holding: LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SnackBar), findsNothing, reason: 'Attach Image is off');

    settings.attachImage = true;
    await tester.pump();
    await press(tester, LogicalKeyboardKey.keyV, holding: LogicalKeyboardKey.controlLeft);
    for (var i = 0; i < 20 && find.byType(SnackBar).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.text('No image to paste.'), findsOneWidget);
    ScaffoldMessenger.of(tester.element(find.byType(HomePage))).clearSnackBars();

    // SVG text on the clipboard.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method != 'Clipboard.getData') return null;
      return {'text': '<svg xmlns="http://www.w3.org/2000/svg" width="30" height="10"><rect width="30" height="10"/></svg>'};
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    for (var i = 0; i < 50 && c.images.patches.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(c.images.patches, hasLength(1));
  });
}
