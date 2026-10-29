// A tour of the editor's views, which must all draw without an error; with SCREENSHOT_DIR set,
// each is saved as a PNG of the whole window for visual review.
// Run: SCREENSHOT_DIR=/some/dir flutter test test/app_screenshot_test.dart

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/audio_track.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/phrase_search_window.dart';
import 'package:curated_score/video_export.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';
import 'test_fonts.dart';
import 'window.dart';

void main() {
  testWidgets('home screen with the sample score and timeline', (tester) async {
    await tester.runAsync(loadTestFonts);
    desktopWindow(tester);

    final settings = AppSettings.memory()..addRecent(demoProject.absolute.path);
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    await tester.pump(const Duration(seconds: 1));
    await screenshot(tester, 'home');
    await tester.tap(find.text('Open Sample'));
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

    await screenshot(tester, 'app');

    // The same showing the video's frame (the toolbar's toggle), letterboxed in the view.
    settings.previewVideoFrame = true;
    await tester.pump(const Duration(milliseconds: 50));
    await screenshot(tester, 'app-framed');
    // A tall video (9:16): 540 points wide, with room for more staves, centred.
    settings.videoRatio = const VideoRatio(9, 16);
    await tester.pump(const Duration(milliseconds: 50));
    await screenshot(tester, 'app-framed-tall');
    settings.videoRatio = VideoRatio.widescreen;
    settings.previewVideoFrame = false;

    // The same with condensing: both horns (and clarinets) on one staff.
    final controller = state.controller as EditorController;
    controller.setCondensed([for (final g in controller.condensable) g.id], on: true);
    await tester.pump(const Duration(milliseconds: 50));
    await screenshot(tester, 'app-condensed');
    controller.undo();

    // Spacers: a staff of nothing with lines below the clarinet, selected, and bars 37–38 widened.
    controller.setExtension('attachImage', true);
    await tester.runAsync(() async {
      await controller.spacers.addHorizontal(controller.timeline.measureStarts[36] + 1.5, controller.timeline.measureStarts[37] + 1.5);
      await controller.spacers.addVertical(below: controller.laneParts[2].id);
      await controller.spacers.setVertical(controller.spacers.vertical.single.copyWith(lines: true, frozen: true));
    });
    await tester.pump(const Duration(milliseconds: 50));
    await screenshot(tester, 'app-spacers');
    controller.setExtension('attachImage', false);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump(const Duration(milliseconds: 50));

    // Find Phrase (⌘F): the cellos' running sixteenths typed two octaves up, found in any key.
    PhraseSearchWindow.show(Overlay.of(tester.element(find.byType(HomePage))), controller);
    await tester.pump();
    for (final key in [LogicalKeyboardKey.digit4, LogicalKeyboardKey.keyA, LogicalKeyboardKey.keyE]) {
      await tester.sendKeyEvent(key);
    }
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    for (final key in [LogicalKeyboardKey.keyA, LogicalKeyboardKey.keyE, LogicalKeyboardKey.keyA, LogicalKeyboardKey.keyE]) {
      await tester.sendKeyEvent(key);
    }
    for (var i = 0; i < 20 && find.textContaining('matches').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    expect(find.textContaining('matches'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter); // the first, under the playhead
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump(const Duration(milliseconds: 400)); // past the tools' colour change
    await screenshot(tester, 'app-find-phrase', inside: find.text('Find Phrase'));
    // The phrase in the alto clef, chosen from the clef menu.
    await tester.tap(find.descendant(of: find.byType(PhraseSearchWindow), matching: find.text('Auto')));
    await tester.pump(const Duration(milliseconds: 400));
    await screenshot(tester, 'app-find-phrase-clefs', inside: find.text('Find Phrase'));
    await tester.tap(find.text('Alto'));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await screenshot(tester, 'app-find-phrase-alto', inside: find.text('Find Phrase'));

    // A match double-clicked folds the window down to a bar; the toolbar's button is lit.
    final firstMatch = find.descendant(of: find.byType(PhraseSearchWindow), matching: find.text('Violin II')).first;
    await tester.tap(firstMatch);
    await tester.tap(firstMatch);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('1/18'), findsOneWidget);
    await screenshot(tester, 'app-find-phrase-bar', inside: find.text('1/18'));
    await screenshot(tester, 'app-find-phrase-toolbar', outermost: true);
    PhraseSearchWindow.close();
    await tester.pump();

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
    await screenshot(tester, 'app-audio');

    // The same in the dark theme: the chrome goes dark, the score turns to light ink on dark paper.
    settings.themeMode = ThemeMode.dark;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await screenshot(tester, 'app-audio-dark');

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
    await screenshot(tester, 'app-warp-audio');
    controller.tab = BottomTab.instruments;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await screenshot(tester, 'app-warp-instruments');
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
    await screenshot(tester, 'app-midi-audio');
    controller.undo();
  });
}
