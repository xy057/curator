// A tour of the editor's views, which must all draw without an error; with SCREENSHOT_DIR set,
// each is saved as a PNG of the whole window for visual review.
// Run: SCREENSHOT_DIR=/some/dir flutter test test/app_screenshot_test.dart

import 'dart:async';

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/audio_track.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/editor_toolbar.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/phrase_search_window.dart';
import 'package:curated_score/player_map_view.dart';
import 'package:curated_score/plugins/plugin_actions.dart';
import 'package:curated_score/plugins/plugin_editor.dart';
import 'package:curated_score/plugins/plugins.dart';
import 'package:curated_score/settings_dialog.dart';
import 'package:curated_score/ui_kit.dart';
import 'package:curated_score/video_export.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';
import 'test_fonts.dart';
import 'window.dart';

void main() {
  testWidgets('home screen with the sample score and timeline', (tester) async {
    await tester.runAsync(loadTestFonts);
    desktopWindow(tester);

    final settings = AppSettings.memory()..addRecent(demoProject.absolute.path);
    final plugins = Plugins(settings);
    await tester.pumpWidget(CuratedScoreApp(settings: settings, plugins: plugins));
    await tester.pump(const Duration(seconds: 1));
    await screenshot(tester, 'home');
    await tester.tap(find.text('Open Sample'));
    await tester.pump(); // its tab
    final state = tester.state(find.byType(ProjectPage)) as dynamic;
    for (var i = 0; i < 100 && state.controller.score == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400)); // past the editor's fade in

    // Bar 37: clarinet, horns, snare drum and cellos are shown.
    state.controller.playback.seek(70.0);
    await tester.pump(const Duration(milliseconds: 50));

    await screenshot(tester, 'app');

    // Plugins: Navigator, turned on, puts its button on the toolbar and a Go menu in the bar.
    // Its keys and commands open the app's own dialogs, laid out from what its Lua describes:
    // a form, a table to edit, a list to choose from, its settings.
    plugins.turn('navigator', true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final button = find.byKey(const ValueKey('plugin navigator.loop'));
    expect(button, findsOneWidget);
    expect(find.text('Go'), findsOneWidget, reason: 'its menu');
    Future<void> settle() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle();
    expect(find.text('Add Bookmark'), findsOneWidget, reason: 'its key');
    await screenshot(tester, 'app-plugin-form', inside: find.text('Add Bookmark'), outermost: true);
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await settle();
    expect(find.text('Bookmark added'), findsOneWidget);
    expect(plugins.run('Edit Bookmarks…'), isTrue);
    await settle();
    expect(find.text('Bookmarks'), findsOneWidget);
    await screenshot(tester, 'app-plugin-sheet', inside: find.text('Bookmarks'), outermost: true);
    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await settle();
    expect(plugins.run('Go to Place…'), isTrue);
    await settle();
    expect(find.text('Go to Place'), findsOneWidget);
    await screenshot(tester, 'app-plugin-choice', inside: find.text('Go to Place'), outermost: true);
    await tester.tap(find.widgetWithText(FilledButton, 'Go'));
    await settle();
    plugins.showSettings('navigator');
    await settle();
    expect(find.text('Lead-in before the loop'), findsOneWidget);
    await screenshot(tester, 'app-plugin-settings', inside: find.text('Lead-in before the loop'), outermost: true);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await settle();
    // The toolbar's button turns the loop on, around the playhead, and is lit while it is.
    await tester.tap(button);
    await settle();
    expect(find.textContaining('Loop: '), findsOneWidget);
    expect(tester.widget<ToolbarButton>(button).selected, isTrue);
    await screenshot(tester, 'app-plugin-toolbar');
    expect(plugins.problems.value, isEmpty);
    // Settings ▸ Plugins lists it, on, among Curator's own; its menu's View… shows its code.
    final page = tester.element(find.byType(ProjectPage));
    unawaited(showSettingsDialog(page, settings, controller: state.controller as EditorController, page: 'Plugins'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Reopen Last Project'), findsOneWidget);
    await screenshot(tester, 'settings-plugins', inside: find.text('Reopen Last Project'), outermost: true);
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    unawaited(PluginActions.edit(page, plugins, plugins.package('navigator')!));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PluginEditor), findsOneWidget);
    await screenshot(tester, 'plugin-editor', inside: find.byType(PluginEditor), outermost: true);
    await tester.tap(find.text('Close'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PluginEditor), findsNothing);
    plugins.turn('navigator', false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(button, findsNothing);

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

    // The toolbar's switch shows the player map in the score's place: none yet, then seated
    // smartly, swelling at bar 37 as loud as it is played once the notes are read; in its editor a
    // section dragged sideways, Done making it the project's in one Undo step; Score switches back.
    await tester.tap(find.descendant(of: find.byType(EditorToolbar), matching: find.byWidgetPredicate((w) => w is ToolbarButton && w.tooltip.startsWith('Player map'))));
    await tester.pump(const Duration(milliseconds: 50));
    expect(settings.playerMap, isTrue);
    expect(find.text('No player map'), findsOneWidget);
    controller.playerMap.set(controller.playerMap.smart(SeatingPreset.american));
    controller.playback.seek(70.3);
    for (var i = 0; i < 100 && identical(controller.playerMap.pulses, PlayerPulses.none); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 50));
    expect(identical(controller.playerMap.pulses, PlayerPulses.none), isFalse, reason: 'the notes were read');
    await screenshot(tester, 'app-player-map');
    final seated = controller.playerMap.map!;
    unawaited(showPlayerMapEditor(tester.element(find.byType(ProjectPage)), controller));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PlayerMapEditor), findsOneWidget);
    final stageArea = find.descendant(
        of: find.byType(PlayerMapEditor), matching: find.byWidgetPredicate((w) => w is CustomPaint && w.painter is PlayerMapPainter));
    final area = tester.getRect(stageArea), seat = seated.sections.first.seats.first;
    await tester.dragFrom(area.topLeft + MapStage(area.size, seated.aspect).toView(seat.x, seat.y), const Offset(60, 0));
    await tester.pump();
    expect(find.text('Violin I'), findsWidgets, reason: 'its name in the inspector');
    await screenshot(tester, 'player-map-editor', inside: find.byType(PlayerMapEditor), outermost: true);
    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.playerMap.map!.sections.first.seats.first.x, greaterThan(seat.x));
    controller.undo();
    expect(controller.playerMap.map, seated);
    controller.undo();
    expect(controller.playerMap.map, isNull);
    await tester.tap(find.descendant(of: find.byType(EditorToolbar), matching: find.byWidgetPredicate((w) => w is ToolbarButton && w.tooltip.startsWith('Score'))));
    await tester.pump(const Duration(milliseconds: 50));
    expect(settings.playerMap, isFalse);

    // Find Phrase (⌘F): the cellos' running sixteenths typed two octaves up, found in any key.
    PhraseSearchWindow.show(Overlay.of(tester.element(find.byType(ProjectPage))), controller);
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
    ScaffoldMessenger.of(tester.element(find.byType(ProjectPage))).clearSnackBars();
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
