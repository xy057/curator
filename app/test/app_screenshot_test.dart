// A tour of the editor's views, which must all draw without an error; with SCREENSHOT_DIR set,
// each is saved as a PNG of the whole window for visual review.
// Run: SCREENSHOT_DIR=/some/dir flutter test test/app_screenshot_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/audio_track.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/score_view.dart';
import 'package:curated_score/video_export.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';
import 'test_fonts.dart';

void main() {
  testWidgets('home screen with the sample score and timeline', (tester) async {
    final dir = Platform.environment['SCREENSHOT_DIR'];
    await tester.runAsync(loadTestFonts);
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

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

    final settings = AppSettings.memory()..addRecent(demoProject.absolute.path);
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    await tester.pump(const Duration(seconds: 1));
    await shot('home');
    await tester.tap(find.text('Try the sample'));
    final state = tester.state(find.byType(HomePage)) as dynamic;
    for (var i = 0; i < 100 && state.controller.score == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400)); // past the home → editor cross-fade

    // Bar 37: clarinet, horns, snare drum and cellos are shown.
    state.controller.playback.seek(70.0);
    await tester.pump(const Duration(milliseconds: 50));

    await shot('app');

    // The same showing the video's frame (the toolbar's toggle), letterboxed in the view.
    settings.previewVideoFrame = true;
    await tester.pump(const Duration(milliseconds: 50));
    await shot('app-framed');
    // A tall video (9:16): 540 points wide, with room for more staves, centred.
    settings.videoRatio = const VideoRatio(9, 16);
    await tester.pump(const Duration(milliseconds: 50));
    await shot('app-framed-tall');
    settings.videoRatio = VideoRatio.widescreen;
    settings.previewVideoFrame = false;

    // The same with condensing: both horns (and clarinets) on one staff.
    final controller = state.controller as EditorController;
    controller.setCondensed([for (final g in controller.condensable) g.id], on: true);
    await tester.pump(const Duration(milliseconds: 50));
    await shot('app-condensed');
    controller.undo();

    // Audio tab with the demo recording and its sync through the closing ritardando.
    final recording = await tester.runAsync(demoWaveform);
    if (recording == null) return;
    controller.audio.debugTrack = AudioTrack.forTesting(
        name: demoRecording.uri.pathSegments.last, length: recording.length, waveform: recording.waveform);
    controller.tab = BottomTab.audio;
    controller.anchors.selectBetween(78, 86); // a batch of anchors
    controller.viewport.requestFit();
    controller.playback.seek(80);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 300)); // past the tab cross-fade
    await shot('app-audio');

    // The same in the dark theme: the chrome goes dark, the score turns to light ink on dark paper.
    settings.themeMode = ThemeMode.dark;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await shot('app-audio-dark');

    // A warp: bars 1–16 tapped every 2 s, then back to bar 9 and on to the end.
    settings.themeMode = ThemeMode.light;
    final sync = controller.sync!, starts = sync.measureStarts;
    controller.beginEdit();
    sync.load([for (var bar = 0; bar <= 30; bar++) SyncAnchor(starts[bar], 1.0 + bar * 2)]);
    controller.anchors.setAnchor(16, starts[16], jumpTo: starts[8]); // bar 17's anchor is the repeat
    controller.endEdit();
    controller.anchors.select(16);
    controller.tab = BottomTab.audio;
    controller.viewport.requestFit();
    controller.playback.seek(34);
    ScaffoldMessenger.of(tester.element(find.byType(HomePage))).clearSnackBars();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await shot('app-warp-audio');
    controller.tab = BottomTab.instruments;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await shot('app-warp-instruments');
    controller.undo();

    // A MIDI tempo map in place of the anchors: steady, a push, then a long ritardando.
    controller.useMidiTempo(MidiTempoMap('WI275 tempo.mid', [
      (quarter: 0, quartersPerMinute: 132),
      (quarter: 48, quartersPerMinute: 144),
      (quarter: 72, quartersPerMinute: 138),
      for (var i = 0; i < 8; i++) (quarter: 108.0 + i * 3, quartersPerMinute: 126.0 - i * 9),
    ]));
    controller.tab = BottomTab.audio;
    controller.viewport.requestFit();
    controller.playback.seek(40);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await shot('app-midi-audio');
    controller.undo();
  });

  testWidgets('double-clicking a score text edits it in place: Enter changes it, Escape leaves it', (tester) async {
    final dir = Platform.environment['SCREENSHOT_DIR'];
    await tester.runAsync(loadTestFonts);
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    // Framed, so the click goes through the frame's mapping (VideoFrame.toLayout).
    await tester.pumpWidget(CuratedScoreApp(settings: AppSettings.memory()..previewVideoFrame = true));
    final state = tester.state(find.byType(HomePage)) as dynamic;
    final controller = state.controller as EditorController;
    await tester.runAsync(() => controller.openFile(demoScore.path));
    await tester.pump();

    // Show the top three instruments only (the tempo mark sits above the top staff).
    controller.curation!.clearAll();
    for (final p in controller.score!.metadata.parts.take(3)) {
      controller.curation!.setLane(p.id, [const Region(0, 1000)]);
    }
    final vivo = controller.score!.texts.firstWhere((t) => t.text == 'Vivo');
    controller.playback.seek(controller.timeline.secondsAtQuarter(controller.timeline.measureStarts[vivo.measure]));
    await tester.pump(const Duration(milliseconds: 50));

    final box = tester.getRect(find.byType(ScoreView));
    final frame = VideoFrame.fit(box.size, VideoFormat.of(VideoResolution.hd1080, fps: 30).aspectRatio,
        devicePixelRatio: tester.view.devicePixelRatio);
    Future<void> doubleClickVivo() async {
      Offset? target;
      for (var y = 0.0; y < frame.layout.height && target == null; y += 4) {
        for (var x = 140.0; x < frame.layout.width && target == null; x += 6) {
          final hit =
              controller.scene!.textAt(Offset(x, y), controller.playback.time.value, controller.curation!, frame.layout);
          if (hit?.id == vivo.id) target = frame.toView(hit!.rect).center;
        }
      }
      expect(target, isNotNull);
      await tester.tapAt(box.topLeft + target!);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(box.topLeft + target);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
    }

    Future<void> engraved() async {
      while (controller.isReengraving) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      await tester.pump();
    }

    final field = find.descendant(of: find.byType(ScoreView), matching: find.byType(TextField));
    await doubleClickVivo();
    expect(field, findsOneWidget);
    expect(tester.widget<TextField>(field).controller!.text, 'Vivo');

    if (dir != null) {
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.ancestor(of: find.byType(Scaffold), matching: find.byType(RepaintBoundary)).first);
        final image = await boundary.toImage(pixelRatio: 2);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/app-edit-text.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    // Enter: the text is changed, re-engraved, and one Undo step.
    await tester.enterText(field, 'Presto');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await engraved();
    expect(field, findsNothing);
    expect(controller.textById(vivo.id)!.current, 'Presto');

    // Escape: nothing changes.
    await doubleClickVivo();
    expect(tester.widget<TextField>(field).controller!.text, 'Presto');
    await tester.enterText(field, 'Largo');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await engraved();
    expect(field, findsNothing);
    expect(controller.textById(vivo.id)!.current, 'Presto');

    controller.undo();
    await engraved();
    expect(controller.textById(vivo.id)!.current, 'Vivo');
  });
}
