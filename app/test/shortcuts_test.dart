// Settings ▸ Shortcuts' keys: written and read back, named as the menus name them, kept as the
// user gives them, and refused where another command has them. (That every command's name is in
// curator.pot is in_step_test's.)
import 'package:curated_score/key_bindings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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
  test('keys: a chord written, read and named; the user’s kept; none given twice; one refused where another command has it', () {
    // A chord is written and read back, and named as the menus name it.
    const saveAs = KeyChord(LogicalKeyboardKey.keyS, command: true, shift: true);
    expect(KeyChord.read(saveAs.write()), saveAs);
    expect(KeyChord.read('not a chord'), isNull);
    expect(saveAs.label, 'Ctrl+Shift+S');
    // Off macOS ⌘ and ⌃ are the one Ctrl.
    expect(const KeyChord(LogicalKeyboardKey.tab, control: true), const KeyChord(LogicalKeyboardKey.tab, command: true));
    _onMac(() {
      expect(saveAs.label, '⇧⌘S');
      expect(const KeyChord(LogicalKeyboardKey.tab, control: true) == const KeyChord(LogicalKeyboardKey.tab, command: true), isFalse);
    });

    // The keys the user gives are kept, read back, and as they come again when their own.
    var keys = KeyMap.standard.withKey(KeyCommand.metronome, _m).withKey(KeyCommand.exportWeb, _ctrlK).withKey(KeyCommand.save, null);
    expect([keys[KeyCommand.metronome], keys[KeyCommand.exportWeb], keys[KeyCommand.save]], [_m, _ctrlK, null]);
    expect(KeyMap.read(keys.write()), keys);
    keys = keys.withKey(KeyCommand.metronome, const KeyChord(LogicalKeyboardKey.keyC)).reset(KeyCommand.save);
    expect(keys.isChanged(KeyCommand.metronome), isFalse, reason: 'its own key again');
    expect(keys.reset(KeyCommand.exportWeb).isStandard, isTrue);
    // What can't be read is left out: a command not there, one not the user's, a damaged key.
    expect(KeyMap.read('{"nothing": "6d+", "undo": "6b+c", "warp": 12, "metronome": "6d+"}'), KeyMap.standard.withKey(KeyCommand.metronome, _m));
    expect(KeyMap.read('[1, 2]'), KeyMap.standard);

    // No command the user can change comes with a key another has where it works.
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

    // A key is refused where another command has it (the menus' over the editor's), and a menu's needs Ctrl.
    expect(KeyMap.standard.takenBy(KeyCommand.metronome, const KeyChord(LogicalKeyboardKey.keyT)), KeyCommand.tapAnchors);
    expect(KeyMap.standard.takenBy(KeyCommand.exportWeb, const KeyChord(LogicalKeyboardKey.keyG, command: true)), KeyCommand.goTo);
    expect(KeyMap.standard.takenBy(KeyCommand.metronome, const KeyChord(LogicalKeyboardKey.keyQ)), isNull, reason: 'the score editor’s are its own');
    expect(KeyMap.standard.withKey(KeyCommand.tapAnchors, null).takenBy(KeyCommand.metronome, const KeyChord(LogicalKeyboardKey.keyT)), isNull,
        reason: 'given away, a key is free');
    expect(KeyCommand.exportWeb.refuses(const KeyChord(LogicalKeyboardKey.keyK)), isNotNull);
    expect(KeyCommand.exportWeb.refuses(_ctrlK), isNull);
    _onMac(() {
      // ⌘M is the system's (Minimize).
      expect(KeyMap.standard.takenBy(KeyCommand.exportWeb, const KeyChord(LogicalKeyboardKey.keyM, command: true)), KeyCommand.minimize);
    });
  });
}
