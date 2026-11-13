// Settings ▸ Shortcuts: every command's keys listed; those of the menus and the editor given
// others by the user, kept, refused where another command has them, and taken by the menus, the
// editor and their tooltips. With SCREENSHOT_DIR set, the page is saved as PNGs.
// Run: SCREENSHOT_DIR=/some/dir flutter test test/shortcuts_test.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:curated_score/app_colors.dart';
import 'package:curated_score/app_menus.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/key_bindings.dart';
import 'package:curated_score/l10n/po.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/settings_dialog.dart';
import 'package:curated_score/shortcut_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';
import 'window.dart';

const _ctrlK = KeyChord(LogicalKeyboardKey.keyK, command: true);
const _m = KeyChord(LogicalKeyboardKey.keyM);

/// [body] as on macOS (tests run as Android otherwise).
void _onMac(void Function() body) {
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  try {
    body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  group('keys', () {
    test('a chord is written and read back, and named as the menus name it', () {
      const saveAs = KeyChord(LogicalKeyboardKey.keyS, command: true, shift: true);
      expect(KeyChord.read(saveAs.write()), saveAs);
      expect(KeyChord.read('not a chord'), isNull);
      expect(saveAs.label, 'Ctrl+Shift+S');
      expect(const KeyChord(LogicalKeyboardKey.arrowLeft, alt: true).label, 'Alt+←');
      // Off macOS ⌘ and ⌃ are the one Ctrl.
      expect(const KeyChord(LogicalKeyboardKey.tab, control: true), const KeyChord(LogicalKeyboardKey.tab, command: true));
      _onMac(() {
        expect(saveAs.label, '⇧⌘S');
        expect(const KeyChord(LogicalKeyboardKey.tab, control: true, shift: true).label, '⌃⇧⇥');
        expect(const KeyChord(LogicalKeyboardKey.tab, control: true) == const KeyChord(LogicalKeyboardKey.tab, command: true), isFalse);
        expect(keysText('⌥⇧A–G'), '⌥⇧A–G');
      });
      expect(keysText('⌥⇧A–G'), 'Alt+Shift+A–G');
    });

    test('the keys the user gives are kept, read back, and as they come again when their own', () {
      var keys = KeyMap.standard.withKey(KeyCommand.metronome, _m).withKey(KeyCommand.exportWeb, _ctrlK).withKey(KeyCommand.save, null);
      expect(keys[KeyCommand.metronome], _m);
      expect(keys[KeyCommand.exportWeb], _ctrlK);
      expect(keys[KeyCommand.save], isNull, reason: 'none');
      expect(keys.isChanged(KeyCommand.save), isTrue);
      expect(KeyMap.read(keys.write()), keys);
      keys = keys.withKey(KeyCommand.metronome, const KeyChord(LogicalKeyboardKey.keyC)).reset(KeyCommand.save);
      expect(keys.isChanged(KeyCommand.metronome), isFalse, reason: 'its own key again');
      expect(keys[KeyCommand.save], const KeyChord(LogicalKeyboardKey.keyS, command: true));
      expect(keys.reset(KeyCommand.exportWeb).isStandard, isTrue);
      // What can't be read is left out: a command not there, one not the user's, a damaged key.
      expect(KeyMap.read('{"nothing": "6d+", "undo": "6b+c", "warp": 12, "metronome": "6d+"}'),
          KeyMap.standard.withKey(KeyCommand.metronome, _m));
      expect(KeyMap.read('[1, 2]'), KeyMap.standard);
    });

    test('no command the user can change comes with a key another has where it works', () {
      for (final mac in [false, true]) {
        void check() {
          for (final command in KeyCommand.values.where((c) => c.editable)) {
            expect(command.defaults.length, lessThanOrEqualTo(1), reason: command.name);
            for (final key in command.defaults) {
              expect(KeyMap.standard.takenBy(command, key), isNull, reason: '${command.name}: ${key.label}');
              expect(command.refuses(key), isNull, reason: '${command.name}: ${key.label}');
            }
          }
        }

        mac ? _onMac(check) : check();
      }
    });

    test('a key is refused where another command has it, and a menu’s needs Ctrl', () {
      expect(KeyMap.standard.takenBy(KeyCommand.metronome, const KeyChord(LogicalKeyboardKey.keyT)), KeyCommand.tapAnchors);
      expect(KeyMap.standard.takenBy(KeyCommand.metronome, const KeyChord(LogicalKeyboardKey.space)), isNotNull);
      // The menus' keys work over the editor's.
      expect(KeyMap.standard.takenBy(KeyCommand.exportWeb, const KeyChord(LogicalKeyboardKey.keyG, command: true)), KeyCommand.goTo);
      // The score editor's are its own.
      expect(KeyMap.standard.takenBy(KeyCommand.metronome, const KeyChord(LogicalKeyboardKey.keyQ)), isNull);
      // Given away, a key is free.
      expect(KeyMap.standard.withKey(KeyCommand.tapAnchors, null).takenBy(KeyCommand.metronome, const KeyChord(LogicalKeyboardKey.keyT)),
          isNull);
      expect(KeyCommand.exportWeb.refuses(const KeyChord(LogicalKeyboardKey.keyK)), isNotNull);
      expect(KeyCommand.exportWeb.refuses(const KeyChord(LogicalKeyboardKey.keyK, alt: true)), isNotNull);
      expect(KeyCommand.exportWeb.refuses(const KeyChord(LogicalKeyboardKey.arrowLeft, command: true)), isNotNull);
      expect(KeyCommand.exportWeb.refuses(_ctrlK), isNull);
      expect(KeyCommand.exportWeb.refuses(const KeyChord(LogicalKeyboardKey.f5)), isNull);
      expect(KeyCommand.metronome.refuses(_m), isNull);
      _onMac(() {
        // ⌘M is the system's (Minimize); ⌃Z the editor's Undo there too.
        expect(KeyMap.standard.takenBy(KeyCommand.exportWeb, const KeyChord(LogicalKeyboardKey.keyM, command: true)), KeyCommand.minimize);
        expect(KeyMap.standard.takenBy(KeyCommand.exportWeb, const KeyChord(LogicalKeyboardKey.keyZ, control: true)), KeyCommand.undo);
        expect(KeyCommand.exportWeb.refuses(const KeyChord(LogicalKeyboardKey.keyK, control: true)), isNull);
      });
    });

    test('every command’s name, help and heading is in curator.pot', () {
      final pot = {for (final e in PoFile.parse(File('assets/l10n/curator.pot').readAsStringSync()).entries) e.key};
      for (final command in KeyCommand.values) {
        expect(pot, contains(command.label), reason: command.name);
        if (command.help case final help?) expect(pot, contains(help), reason: '${command.name}: help');
        final group = command.group;
        if (group != 'Curator') expect(pot.contains(group) || pot.contains('heading\u0004$group'), isTrue, reason: group);
      }
    });
  });

  testWidgets('Settings ▸ Shortcuts lists every command; a field takes the keys typed for it', (tester) async {
    await tester.runAsync(loadTestFonts);
    desktopWindow(tester);
    final settings = AppSettings.memory();
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    await tester.pump(const Duration(seconds: 1));

    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    // The whole window, the settings over it (another route: the outermost boundary).
    Future<void> shot(String name) async {
      final dir = screenshotDir;
      if (dir == null) return;
      RenderRepaintBoundary? whole;
      for (RenderObject? o = tester.renderObject(find.byType(ShortcutKeys).first); o != null; o = o.parent) {
        if (o is RenderRepaintBoundary) whole = o;
      }
      await tester.runAsync(() async {
        final png = await (await whole!.toImage(pixelRatio: 2)).toByteData(format: ui.ImageByteFormat.png);
        File('$dir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    unawaited(showSettingsDialog(tester.element(find.byType(Scaffold).first), settings, page: 'Shortcuts'));
    await settle();
    final shown = KeyCommand.values.where((c) => c.shown);
    expect(find.byType(ShortcutKeys, skipOffstage: false), findsNWidgets(shown.length));
    expect(find.text('Reset to Default'), findsNothing, reason: 'nothing changed');
    for (final style in UiStyle.values) {
      for (final theme in [ThemeMode.light, ThemeMode.dark]) {
        settings
          ..uiStyle = style
          ..themeMode = theme;
        await settle();
        await shot('shortcuts-${style.name}-${theme.name}');
      }
    }
    settings
      ..uiStyle = UiStyle.refined
      ..themeMode = ThemeMode.light;
    await settle();

    Finder field(KeyCommand command) => find
        .descendant(
            of: find.byWidgetPredicate((w) => w is ShortcutKeys && w.command == command, skipOffstage: false),
            matching: find.byType(InputDecorator, skipOffstage: false))
        .first;
    Future<void> record(KeyCommand command) async {
      await tester.ensureVisible(field(command));
      await settle();
      await tester.tap(field(command));
      await settle();
    }

    // Metronome on M.
    await record(KeyCommand.metronome);
    expect(find.text('Type Shortcut'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await settle();
    expect(settings.keys[KeyCommand.metronome], _m);
    expect(find.text('Type Shortcut'), findsNothing);
    expect(find.text('Reset to Default'), findsOneWidget);
    await shot('shortcuts-changed');

    // T is Tap anchors': refused, and the field goes on listening; Esc leaves it as it was, and
    // the window open.
    await record(KeyCommand.metronome);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await settle();
    expect(find.text('Used by Tap anchors'), findsOneWidget);
    await shot('shortcuts-taken');
    expect(settings.keys[KeyCommand.metronome], _m);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle();
    expect(find.text('Used by Tap anchors'), findsNothing);
    expect(find.byType(ShortcutKeys), findsWidgets, reason: 'Esc was the field’s');
    expect(settings.keys[KeyCommand.metronome], _m);

    // ⌫: none.
    await record(KeyCommand.metronome);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await settle();
    expect(settings.keys[KeyCommand.metronome], isNull);

    // A menu's key needs Ctrl here; with it, the menu has it.
    await record(KeyCommand.exportWeb);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await settle();
    expect(find.text('Add Ctrl'), findsOneWidget);
    expect(settings.keys[KeyCommand.exportWeb], isNull);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await settle();
    expect(find.text('Ctrl+'), findsOneWidget, reason: 'what is held, shown');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle();
    expect(settings.keys[KeyCommand.exportWeb], _ctrlK);
    expect(tester.widget<AppMenus>(find.byType(AppMenus)).keys[KeyCommand.exportWeb], _ctrlK);

    // A row's Reset: its own key again; Reset to Default: every command's.
    await tester.ensureVisible(field(KeyCommand.metronome));
    await settle();
    await tester.tap(find.descendant(
        of: find.byWidgetPredicate((w) => w is ShortcutKeys && w.command == KeyCommand.metronome), matching: find.byTooltip('Reset')));
    await settle();
    expect(settings.keys[KeyCommand.metronome], const KeyChord(LogicalKeyboardKey.keyC));
    expect(settings.keys.isStandard, isFalse);
    await tester.tap(find.text('Reset to Default'));
    await settle();
    expect(settings.keys.isStandard, isTrue);
    expect(find.text('Reset to Default'), findsNothing);

    // The search finds a command by its name.
    await tester.enterText(find.byType(TextField).first, 'metronome');
    await settle();
    expect(find.byWidgetPredicate((w) => w is ShortcutKeys && w.command == KeyCommand.metronome), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the editor and its tooltips take a command’s key as set', (tester) async {
    await tester.runAsync(loadTestFonts);
    desktopWindow(tester);
    final settings = AppSettings.memory()..keys = KeyMap.standard.withKey(KeyCommand.metronome, _m);
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    await tester.pump(const Duration(seconds: 1));
    final pages = find.byType(ProjectPage, skipOffstage: false);
    EditorController controller() => ((pages.evaluate().single as StatefulElement).state as dynamic).controller as EditorController;
    await tester.tap(find.text('Open Sample'));
    await tester.pump();
    for (var i = 0; i < 100 && (pages.evaluate().isEmpty || controller().score == null || controller().isLoading); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await tester.pump(const Duration(seconds: 1));
    final playback = controller().playback;
    final before = playback.metronome;

    expect(find.byTooltip('Metronome (M)'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.pump();
    expect(playback.metronome, before, reason: 'C is no longer its key');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(playback.metronome, !before);

    // Given no key, its tooltip names none; given its own again, C.
    settings.keys = settings.keys.withKey(KeyCommand.metronome, null);
    await tester.pump();
    expect(find.byTooltip('Metronome'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(playback.metronome, !before);
    settings.keys = KeyMap.standard;
    await tester.pump();
    expect(find.byTooltip('Metronome (C)'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.pump();
    expect(playback.metronome, before);
    expect(tester.takeException(), isNull);
  });
}
