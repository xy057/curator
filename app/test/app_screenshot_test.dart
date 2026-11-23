// A tour of the editor's views, which must all draw without an error; with SCREENSHOT_DIR set,
// each is saved as a PNG of the whole window for visual review.
// Run: SCREENSHOT_DIR=/some/dir flutter test test/app_screenshot_test.dart

import 'dart:async';

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/audio_track.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/editor_toolbar.dart';
import 'package:curated_score/macros.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/panel_bar.dart';
import 'package:curated_score/phrase_search_window.dart';
import 'package:curated_score/player_map_view.dart';
import 'package:curated_score/plugins/plugin_actions.dart';
import 'package:curated_score/plugins/plugin_editor.dart';
import 'package:curated_score/plugins/plugins.dart';
import 'package:curated_score/settings_dialog.dart';
import 'package:curated_score/toolbar_customize.dart';
import 'package:curated_score/toolbar_layout.dart';
import 'package:curated_score/ui_kit.dart';
import 'package:curated_score/video_export.dart';
import 'package:flutter/gestures.dart';
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

    // Edit ▸ Macros…: a macro is a graph, its steps the nodes and its wires what is done after what. A node is moved by
    // its head; a wire is drawn out of a node's right port onto another node (not one that would close a ring) and cut
    // at the dot in its middle; a step is taken out by its ×, its wires with it.
    settings.macros = const [
      LaneMacro(name: 'Both', steps: [
        MacroStep(MacroAction.hear), MacroStep(MacroAction.follow, lanes: MacroLanes.all), MacroStep(MacroAction.match), //
        MacroStep(MacroAction.thin, lanes: MacroLanes.all),
      ], wired: [(from: 0, to: 2), (from: 1, to: 3)]),
    ];
    LaneMacro graph() => settings.macros.single;
    unawaited(showMacrosDialog(page, settings, state.controller as EditorController));
    await settle();
    Finder node(int n) => find.byKey(ValueKey('macro node $n'));
    expect([for (var n = 1; n <= 4; n++) node(n).evaluate().length], [1, 1, 1, 1]);
    await screenshot(tester, 'macros-graph', inside: find.text('Add Step'), outermost: true);
    Future<void> pull(Offset from, Offset to) async {
      final gesture = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      await gesture.moveBy(const Offset(6, 0));
      await tester.pump();
      await gesture.moveTo(to);
      await tester.pump();
      await gesture.up();
      await settle();
    }

    final four = tester.getTopLeft(node(4));
    await pull(four + const Offset(14, 18), four + const Offset(14 + 6 + 30, 18 + 120));
    expect(graph().steps[3].at, isNotNull);
    expect(tester.getTopLeft(node(4)) - four, within(distance: 1.5, from: const Offset(30, 120)));
    Offset port(int n) => tester.getCenter(find.byKey(ValueKey('macro out $n')));
    await pull(port(2), tester.getCenter(node(3)));
    expect(graph().wires, contains((from: 1, to: 2)));
    await pull(port(3), tester.getCenter(node(1)));
    expect(graph().wires, hasLength(3), reason: 'no ring');
    await screenshot(tester, 'macros-graph-wired', inside: find.text('Add Step'), outermost: true);
    await tester.tap(find.byKey(const ValueKey('macro wire 2 3')));
    await settle();
    expect(graph().wires, const [(from: 0, to: 2), (from: 1, to: 3)]);
    await tester.tap(find.descendant(of: node(1), matching: find.byTooltip('Remove')));
    await settle();
    expect([graph().steps.length, graph().wires, graph().steps.first.action], [3, const [(from: 0, to: 2)], MacroAction.follow]);
    await tester.tap(find.text('Done'));
    await settle();
    // A macro's own button on the editor's toolbar goes by the tab showing: one for the lanes is off in the Audio tab.
    {
      final editor = state.controller as EditorController, was = editor.tab;
      editor.tab = BottomTab.instruments;
      settings.macros = const [LaneMacro(name: 'Tidy', steps: [MacroStep(MacroAction.bridge, lanes: MacroLanes.all)])];
      settings.setToolbar(settings.toolbarOf(BarKind.editor).added(BarItem.macro1));
      await settle();
      final own = find.descendant(of: find.byType(EditorToolbar), matching: find.byWidgetPredicate((w) => w is ToolbarButton && w.tooltip.startsWith('Tidy')));
      bool runs() => tester.widget<ToolbarButton>(own).onPressed != null;
      expect(runs(), isTrue);
      editor.tab = BottomTab.audio;
      await settle();
      expect(runs(), isFalse, reason: 'the lanes aren’t showing');
      editor.tab = BottomTab.instruments;
      await settle();
      expect(runs(), isTrue);
      settings.setToolbar(settings.toolbarOf(BarKind.editor).without(BarItem.macro1));
      editor.tab = was;
      await settle();
    }
    settings.macros = const [];

    // The toolbar is the user's. An item's own menu (a right click) moves it into the menu at the
    // bar's end, where it still works. View ▸ Customize Toolbar… lists what can be added in the
    // editor's place: Save dragged onto the bar before Play, the score's size dragged off it,
    // Restore Defaults putting all back. A window too narrow for the bar keeps the items it has
    // no room for in that menu.
    final toolbar = find.byType(EditorToolbar);
    Finder tool(String tip) => find.descendant(of: toolbar, matching: find.byWidgetPredicate((w) => w is ToolbarButton && w.tooltip.startsWith(tip)));
    ToolbarLayout bar([BarKind kind = BarKind.editor]) => settings.toolbarOf(kind);
    expect(bar().isStandard, isTrue);
    // (The button at the bar's end is always built, and shown, so hit, only with something in its menu.)
    final more = find.descendant(of: toolbar, matching: find.byTooltip('More tools')).hitTestable();
    expect(more, findsNothing, reason: 'everything fits');
    await tester.tapAt(tester.getCenter(tool('Metronome')), buttons: kSecondaryButton);
    await settle();
    await tester.tap(find.text('Move to Overflow Menu'));
    await settle();
    expect(bar().menu, [BarItem.metronome]);
    expect(tool('Metronome'), findsNothing);
    await tester.tap(more);
    await settle();
    await tester.tap(find.text('Metronome'));
    await settle();
    expect((state.controller as EditorController).playback.metronome, isTrue, reason: 'chosen in the menu');
    (state.controller as EditorController).playback.metronome = false;
    await tester.tapAt(tester.getTopLeft(toolbar) + const Offset(700, 20), buttons: kSecondaryButton);
    await settle();
    expect(find.text('Remove from Toolbar'), findsNothing, reason: 'the bar’s own menu, over no item');
    await tester.tap(find.text('Customize Toolbar…'));
    await settle();
    expect(find.byType(ToolbarCustomizer), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('overflow menu')), matching: find.text('Metronome')), findsOneWidget);
    Future<void> drag(Finder from, Offset to, {String? shot}) async {
      final gesture = await tester.startGesture(tester.getCenter(from), kind: PointerDeviceKind.mouse);
      await tester.pump();
      await gesture.moveBy(const Offset(4, -12));
      await tester.pump();
      await gesture.moveTo(to);
      await tester.pump();
      if (shot != null) await screenshot(tester, shot, outermost: true);
      await gesture.up();
      await settle();
    }

    await screenshot(tester, 'app-customize-toolbar');
    await drag(find.byKey(const ValueKey('add save')), tester.getTopLeft(find.byTooltip('Play (Space)')) + const Offset(3, 14),
        shot: 'app-customize-toolbar-drag');
    expect(bar().bar.take(3), [BarItem.goToStart, BarItem.save, BarItem.playPause]);
    expect(find.byKey(const ValueKey('add save')), findsNothing, reason: 'one of a kind: on the bar, so not left to add');
    await drag(find.descendant(of: toolbar, matching: find.byType(Slider)), tester.getCenter(find.byType(ToolbarCustomizer)));
    expect(bar().bar, isNot(contains(BarItem.scoreSize)));
    expect(find.byKey(const ValueKey('add scoreSize')), findsOneWidget);
    expect(tester.widget<ToolbarButton>(tool('Go to start')).onPressed, isNotNull);
    final at = (state.controller as EditorController).playback.time.value;
    await tester.tap(tool('Go to start'), warnIfMissed: false);
    expect((state.controller as EditorController).playback.time.value, at, reason: 'customized, the bar’s items do nothing');
    expect(ToolbarLayout.read(BarKind.editor, bar().write()), bar());
    expect(ToolbarLayout.read(BarKind.editor, '{"bar": ["save", "nothing", "space", "save", "space", "align"], "menu": ["space", "undo"]}'),
        ToolbarLayout(kind: BarKind.editor, bar: const [BarItem.save, BarItem.space, BarItem.space], menu: const [BarItem.undo]),
        reason: 'one this version hasn’t got or another toolbar’s left out, one of a kind once, no room to share out in the menu');
    expect(ToolbarLayout.read(BarKind.editor, '[]'), ToolbarLayout.standard(BarKind.editor));
    await tester.tap(find.text('Restore Defaults'));
    await settle();
    expect(bar().isStandard, isTrue);
    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await settle();
    expect(find.byType(ToolbarCustomizer), findsNothing);
    tester.view.physicalSize = const Size(1200, 1800);
    await settle();
    await settle();
    expect(tester.takeException(), isNull, reason: 'the bar never runs past its width');
    await tester.tap(more);
    await settle();
    expect(find.byType(Slider).hitTestable(), findsOneWidget, reason: 'the score’s size, a row of the menu');
    await screenshot(tester, 'app-toolbar-narrow', inside: find.byType(Slider).hitTestable(), outermost: true);
    await tester.tapAt(const Offset(10, 600));
    await settle();
    tester.view.physicalSize = const Size(2880, 1800);
    await settle();
    await settle();
    expect(more, findsNothing);

    // The timeline's bar is the user's too, each tab's by itself: an item's own menu moves it
    // into the menu at the bar's end; customized (a right click on the bar), the tab's toolbar
    // is listed with what it can take (a command's button as any toolbar, not the editor's own
    // controls), the bar shown under the editor's to drag onto, its switch (and the panel's)
    // going to another tab's.
    final editing = state.controller as EditorController;
    final tabWas = editing.tab;
    editing.tab = BottomTab.instruments;
    await settle();
    final panel = find.byType(PanelBar);
    Finder panelTool(String tip, [Finder? of]) =>
        find.descendant(of: of ?? panel, matching: find.byWidgetPredicate((w) => w is ToolbarButton && w.tooltip.startsWith(tip)));
    expect(bar(BarKind.instruments).isStandard, isTrue);
    await tester.tapAt(tester.getCenter(panelTool('Auto-curate')), buttons: kSecondaryButton);
    await settle();
    await tester.tap(find.text('Move to Overflow Menu'));
    await settle();
    expect(bar(BarKind.instruments).menu, [BarItem.autoCurate]);
    expect(bar().isStandard && bar(BarKind.audio).isStandard, isTrue, reason: 'each toolbar by itself');
    expect(panelTool('Auto-curate'), findsNothing);
    await tester.tap(find.descendant(of: panel, matching: find.byTooltip('More tools')).hitTestable());
    await settle();
    expect(find.text('Auto-curate'), findsOneWidget, reason: 'a row of the menu');
    await tester.tapAt(const Offset(10, 600));
    await settle();
    await tester.tapAt(tester.getCenter(panel), buttons: kSecondaryButton);
    await settle();
    expect(find.text('Remove from Toolbar'), findsNothing, reason: 'the bar’s own menu, over what is selected');
    await tester.tap(find.text('Customize Toolbar…'));
    await settle();
    final customizer = find.byType(ToolbarCustomizer);
    final shown = find.descendant(of: customizer, matching: panel);
    expect(shown, findsOneWidget);
    expect(find.byKey(const ValueKey('add save')), findsOneWidget, reason: 'a command’s button goes on any toolbar');
    expect(find.byKey(const ValueKey('add scoreSize')), findsNothing, reason: 'the editor’s own');
    expect(find.descendant(of: find.byKey(const ValueKey('overflow menu')), matching: find.text('Auto-curate')), findsOneWidget);
    await drag(find.byKey(const ValueKey('add speed')), tester.getTopLeft(panelTool('Clear all lanes', shown)) + const Offset(3, 14),
        shot: 'app-customize-panel-drag');
    expect(bar(BarKind.instruments).bar.contains(BarItem.speed), isTrue);
    expect(bar(BarKind.instruments).bar.indexOf(BarItem.speed), bar(BarKind.instruments).bar.indexOf(BarItem.clearLanes) - 1);
    await screenshot(tester, 'app-customize-panel');
    await tester.tap(find.descendant(of: customizer, matching: find.text('Audio')));
    await settle();
    expect(editing.tab, BottomTab.audio);
    expect(find.byKey(const ValueKey('add autoCurate')), findsNothing, reason: 'the Instruments tab’s');
    expect(find.byKey(const ValueKey('add speed')), findsNothing, reason: 'on the Audio tab’s bar as the app comes');
    expect(find.descendant(of: find.byKey(const ValueKey('overflow menu')), matching: find.text('Auto-curate')), findsNothing);
    await screenshot(tester, 'app-customize-panel-audio');
    await tester.tap(find.descendant(of: shown, matching: find.byTooltip('Instruments')));
    await settle();
    expect(find.byKey(const ValueKey('add autoCurate')), findsNothing);
    expect(find.descendant(of: find.byKey(const ValueKey('overflow menu')), matching: find.text('Auto-curate')), findsOneWidget, reason: 'the bar’s switch');
    await tester.tap(find.text('Restore Defaults'));
    await settle();
    expect(bar(BarKind.instruments).isStandard, isTrue);
    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await settle();
    expect(customizer, findsNothing);
    expect(ToolbarLayout.read(BarKind.audio, '{"bar": ["scoreSize", "align", "save", "autoCurate"]}'),
        ToolbarLayout(kind: BarKind.audio, bar: const [BarItem.align, BarItem.save]));
    editing.tab = tabWas;
    await settle();

    // A tall video (9:16): 540 points wide, with room for more staves, centred.
    settings.videoRatio = const VideoRatio(9, 16);
    await tester.pump(const Duration(milliseconds: 50));
    await screenshot(tester, 'app-framed-tall');
    settings.videoRatio = VideoRatio.widescreen;

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
    // section dragged sideways, nudged and copied (each a step of its own Undo), Done making it
    // the project's in one Undo step; Score switches back.
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
    // Two presses of an arrow are one Undo step of the editor's, the drag another.
    PlayerMap edited() => (tester.widget<CustomPaint>(stageArea).painter! as PlayerMapPainter).map;
    final dragged = edited();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(edited().sections.first.seats.first.x, closeTo(dragged.sections.first.seats.first.x + 0.01, 1e-9));
    Future<void> chord(LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    await chord(LogicalKeyboardKey.keyZ);
    expect(edited(), dragged);
    // ⌘D: another of the section selected, where there is room for it.
    await chord(LogicalKeyboardKey.keyD);
    expect(edited().sections, hasLength(dragged.sections.length + 1));
    expect(edited().sections.last.seats, hasLength(dragged.sections.first.seats.length));
    await chord(LogicalKeyboardKey.keyZ);
    expect(edited(), dragged);
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
