import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'l10n/l10n.dart';
import 'ui_kit.dart' show windowsKeys;

bool get _mac => defaultTargetPlatform == TargetPlatform.macOS;

/// A key and what is held with it, written the same for every system: [command] is ⌘ on macOS
/// and Ctrl elsewhere; [control] is ⌃ on macOS, and Ctrl elsewhere too (there, one with
/// [command]: two chords that differ only so are equal).
@immutable
class KeyChord {
  const KeyChord(this.key, {this.command = false, this.control = false, this.alt = false, this.shift = false});
  final LogicalKeyboardKey key;
  final bool command, control, alt, shift;

  // What is held on this system.
  bool get _meta => _mac && command;
  bool get _ctrl => _mac ? control : command || control;

  /// The key [event] is, with what is held now; null for a modifier alone, or with the Windows
  /// key held (which no chord here has).
  static KeyChord? of(KeyEvent event, [HardwareKeyboard? keyboard]) {
    final keys = keyboard ?? HardwareKeyboard.instance;
    if (_modifiers.contains(event.logicalKey) || (!_mac && keys.isMetaPressed)) return null;
    return KeyChord(
      event.logicalKey,
      command: _mac ? keys.isMetaPressed : keys.isControlPressed,
      control: _mac && keys.isControlPressed,
      alt: keys.isAltPressed,
      shift: keys.isShiftPressed,
    );
  }

  static final _modifiers = {
    LogicalKeyboardKey.shift, LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.control, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.alt, LogicalKeyboardKey.altLeft, LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.meta, LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.capsLock, LogicalKeyboardKey.fn, LogicalKeyboardKey.fnLock, LogicalKeyboardKey.numLock,
    LogicalKeyboardKey.scrollLock, LogicalKeyboardKey.superKey, LogicalKeyboardKey.hyper,
  };

  /// What [CallbackShortcuts] and the menus take.
  SingleActivator get activator => SingleActivator(key, meta: _meta, control: _ctrl, alt: alt, shift: shift);

  /// Whether ⌘ or ⌃ (Ctrl) is held: a menu's key needs one, or a typed letter would be taken.
  bool get commanded => _meta || _ctrl;

  /// As the menus write it: "⇧⌘S" on macOS, "Ctrl+Shift+S" elsewhere.
  String get label => _mac
      ? '${control ? '⌃' : ''}${alt ? '⌥' : ''}${shift ? '⇧' : ''}${command ? '⌘' : ''}${keyName(key)}'
      : [if (_ctrl) 'Ctrl', if (alt) 'Alt', if (shift) 'Shift', keyName(key)].join('+');

  /// Saved as the key's ID in hexadecimal and what is held: "6f+c" is ⌘O (c ⌘, t ⌃, a ⌥, s ⇧).
  String write() => '${key.keyId.toRadixString(16)}+${command ? 'c' : ''}${control ? 't' : ''}${alt ? 'a' : ''}${shift ? 's' : ''}';

  static KeyChord? read(String text) {
    final parts = text.split('+');
    final id = parts.length == 2 ? int.tryParse(parts[0], radix: 16) : null;
    if (id == null) return null;
    final held = parts[1];
    return KeyChord(LogicalKeyboardKey.findKeyByKeyId(id) ?? LogicalKeyboardKey(id),
        command: held.contains('c'), control: held.contains('t'), alt: held.contains('a'), shift: held.contains('s'));
  }

  @override
  bool operator ==(Object other) =>
      other is KeyChord && other.key == key && other._meta == _meta && other._ctrl == _ctrl && other.alt == alt && other.shift == shift;

  @override
  int get hashCode => Object.hash(key, _meta, _ctrl, alt, shift);

  @override
  String toString() => 'KeyChord($label)';
}

/// A key's name as it is written on it, or as macOS draws it in its menus.
String keyName(LogicalKeyboardKey key) => switch (key) {
      LogicalKeyboardKey.arrowLeft => '←',
      LogicalKeyboardKey.arrowRight => '→',
      LogicalKeyboardKey.arrowUp => '↑',
      LogicalKeyboardKey.arrowDown => '↓',
      LogicalKeyboardKey.space => 'Space'.trIn('key'),
      LogicalKeyboardKey.enter => _mac ? '↩' : 'Enter',
      LogicalKeyboardKey.numpadEnter => _mac ? '⌤' : 'Enter',
      LogicalKeyboardKey.backspace => _mac ? '⌫' : 'Backspace',
      LogicalKeyboardKey.delete => _mac ? '⌦' : 'Delete',
      LogicalKeyboardKey.tab => _mac ? '⇥' : 'Tab',
      LogicalKeyboardKey.escape => 'Esc',
      LogicalKeyboardKey.pageUp => 'Page Up',
      LogicalKeyboardKey.pageDown => 'Page Down',
      _ => key.keyLabel.length == 1 ? key.keyLabel.toUpperCase() : key.keyLabel,
    };

/// Where a command's keys work. Two commands of one place can't share a key; the menus' keys
/// work over the editor's, so for that the two are one ([sharesKeysWith]).
enum KeyPlace {
  menus,
  editor,
  scoreEditor,
  pdfImport,
  findPhrase,
  code;

  bool sharesKeysWith(KeyPlace other) => this == other || (index <= editor.index && other.index <= editor.index);
}

typedef _K = KeyChord;
typedef _L = LogicalKeyboardKey;

/// Every command a key gives (Settings ▸ Shortcuts lists them, under their [group]s): its name
/// ([label], as the menus or tooltips say it), where it works, its keys as the app comes. Those
/// [editable] are the user's to change ([KeyMap]): the menus' and the editor's; the rest are
/// listed as their windows take them.
///
/// The menus' and the editor's keys are taken from here (main.dart, app_menus.dart), but for the
/// fixed ones of the editor, whose handler lists them itself; the score editor's, the PDF
/// import's, Find Phrase's and the code editors' handlers are their own too. A key added to any
/// of them is added here, where it keeps the user from giving it to another command.
enum KeyCommand {
  // The menus. On macOS, the app's menu (the system's own keys).
  hideApp('Hide Curator', 'Curator', KeyPlace.menus, [_K(_L.keyH, command: true)], macOnly: true),
  hideOthers('Hide Others', 'Curator', KeyPlace.menus, [_K(_L.keyH, command: true, alt: true)], macOnly: true),
  quit('Quit Curator', 'Curator', KeyPlace.menus, [_K(_L.keyQ, command: true)], macOnly: true),
  newLilyPond('New LilyPond Score…', 'File', KeyPlace.menus, [], editable: true),
  open('Open…', 'File', KeyPlace.menus, [_K(_L.keyO, command: true)], editable: true),
  importScore('Import…', 'File', KeyPlace.menus, [_K(_L.keyI, command: true)], editable: true),
  close('Close', 'File', KeyPlace.menus, [_K(_L.keyW, command: true)], editable: true),
  save('Save', 'File', KeyPlace.menus, [_K(_L.keyS, command: true)], editable: true),
  saveAs('Save As…', 'File', KeyPlace.menus, [_K(_L.keyS, command: true, shift: true)], editable: true),
  exportVideo('Export Video…', 'File', KeyPlace.menus, [_K(_L.keyE, command: true)], editable: true),
  exportWeb('Export to Web…', 'File', KeyPlace.menus, [], editable: true),
  // The editor takes Edit's keys with ⌃ too on macOS ([also]).
  undo('Undo', 'Edit', KeyPlace.menus, [_K(_L.keyZ, command: true)], also: [_K(_L.keyZ, control: true)]),
  redo('Redo', 'Edit', KeyPlace.menus, [_K(_L.keyZ, command: true, shift: true)],
      other: [_K(_L.keyY, command: true), _K(_L.keyZ, command: true, shift: true)],
      also: [_K(_L.keyY, control: true), _K(_L.keyZ, control: true, shift: true)]),
  cut('Cut', 'Edit', KeyPlace.menus, [_K(_L.keyX, command: true)], also: [_K(_L.keyX, control: true)]),
  copy('Copy', 'Edit', KeyPlace.menus, [_K(_L.keyC, command: true)], also: [_K(_L.keyC, control: true)]),
  paste('Paste', 'Edit', KeyPlace.menus, [_K(_L.keyV, command: true)], also: [_K(_L.keyV, control: true)]),
  delete('Delete', 'Edit', KeyPlace.menus, [_K(_L.backspace), _K(_L.delete)], other: [_K(_L.delete), _K(_L.backspace)]),
  selectAll('Select All', 'Edit', KeyPlace.menus, [_K(_L.keyA, command: true)], also: [_K(_L.keyA, control: true)]),
  deselect('Deselect', 'Edit', KeyPlace.editor, [_K(_L.escape)], help: 'Stops tapping, or goes back to Select, first.'),
  findPhrase('Find Phrase…', 'Edit', KeyPlace.menus, [_K(_L.keyF, command: true)], editable: true),
  projectSettings('Project Settings…', 'Edit', KeyPlace.menus, [_K(_L.comma, command: true, shift: true)], editable: true),
  settings('Settings…', 'Edit', KeyPlace.menus, [_K(_L.comma, command: true)]),
  showPreview('Hide / Show Preview', 'View', KeyPlace.menus, [], editable: true),
  showTimeline('Hide / Show Timeline', 'View', KeyPlace.menus, [], editable: true),
  maximizePreview('Maximize Preview', 'View', KeyPlace.menus, [], editable: true),
  maximizeTimeline('Maximize Timeline', 'View', KeyPlace.menus, [], editable: true),
  showTabBar('Hide / Show Tab Bar', 'View', KeyPlace.menus, [_K(_L.keyT, command: true, shift: true)], editable: true),
  showAllTabs('Show All Tabs', 'View', KeyPlace.menus, [_K(_L.backslash, command: true, shift: true)], editable: true),
  // In Window on macOS, View elsewhere ([group]).
  previousTab('Show Previous Tab', 'Window', KeyPlace.menus, [_K(_L.tab, control: true, shift: true)], editable: true),
  nextTab('Show Next Tab', 'Window', KeyPlace.menus, [_K(_L.tab, control: true)], editable: true),
  minimize('Minimize', 'Window', KeyPlace.menus, [_K(_L.keyM, command: true)], macOnly: true),
  fullScreen('Enter Full Screen', 'Window', KeyPlace.menus, [_K(_L.keyF, command: true, control: true)], macOnly: true),

  // The editor (a project's window), while no field has the keyboard.
  playPause('Play / Pause', 'Playback', KeyPlace.editor, [_K(_L.space), _K(_L.enter), _K(_L.numpadEnter), _K(_L.keyP)]),
  goToStart('Go to start', 'Playback', KeyPlace.editor, [_K(_L.home)], editable: true),
  goToEnd('Go to end', 'Playback', KeyPlace.editor, [_K(_L.end)], editable: true),
  goTo('Go to bar or time', 'Playback', KeyPlace.editor, [_K(_L.keyG, command: true)], editable: true),
  skip('Skip 5 s', 'Playback', KeyPlace.editor, [_K(_L.arrowLeft), _K(_L.arrowRight)], help: 'With nothing selected.'),
  skipSecond('Skip 1 s', 'Playback', KeyPlace.editor, [_K(_L.arrowLeft, shift: true), _K(_L.arrowRight, shift: true)],
      help: 'With nothing selected.'),
  fineSeek('Fine seek', 'Playback', KeyPlace.editor, [_K(_L.arrowLeft, alt: true), _K(_L.arrowRight, alt: true)]),
  metronome('Metronome', 'Playback', KeyPlace.editor, [_K(_L.keyC)], editable: true),
  tapAnchors('Tap anchors', 'Audio', KeyPlace.editor, [_K(_L.keyT)], editable: true),
  tap('Tap an anchor', 'Audio', KeyPlace.editor, [_K(_L.space)], help: 'While tapping.'),
  warp('Warp', 'Audio', KeyPlace.editor, [_K(_L.keyW)], editable: true),
  nudgeAnchors('Nudge anchors', 'Audio', KeyPlace.editor, [_K(_L.arrowLeft), _K(_L.arrowRight)], help: '⇧ 1 ms'),
  repointAnchors('Re-point anchors', 'Audio', KeyPlace.editor, [_K(_L.arrowUp), _K(_L.arrowDown)]),
  moveTempo('Move a tempo change', 'Audio', KeyPlace.editor, [_K(_L.arrowLeft), _K(_L.arrowRight)], help: 'A beat · ⇧ a sixteenth'),
  tempo('Tempo up / down', 'Audio', KeyPlace.editor, [_K(_L.arrowUp), _K(_L.arrowDown)],
      also: [_K(_L.arrowUp, shift: true), _K(_L.arrowDown, shift: true)], help: '1 BPM · ⇧ 0.1'),
  selectTool('Select', 'Instruments', KeyPlace.editor, [_K(_L.keyV)], editable: true),
  drawTool('Draw', 'Instruments', KeyPlace.editor, [_K(_L.keyD)], editable: true),
  eraseTool('Erase', 'Instruments', KeyPlace.editor, [_K(_L.keyE)], editable: true),
  trimStart('Start at the playhead', 'Instruments', KeyPlace.editor, [_K(_L.bracketLeft)], editable: true),
  trimEnd('End at the playhead', 'Instruments', KeyPlace.editor, [_K(_L.bracketRight)], editable: true),
  moveRegions('Move regions or a key area', 'Instruments', KeyPlace.editor, [_K(_L.arrowLeft), _K(_L.arrowRight)],
      help: 'A bar · ⇧ a beat'),
  nextLane('Select in the lane above / below', 'Instruments', KeyPlace.editor, [_K(_L.arrowUp), _K(_L.arrowDown)]),

  // The score editor (Project Info ▸ Score ▸ Edit…).
  noteInput('Note Input', 'Score Editor', KeyPlace.scoreEditor, [_K(_L.enter), _K(_L.keyN, shift: true)]),
  done('Done', 'Score Editor', KeyPlace.scoreEditor, [_K(_L.enter, command: true)]),
  goToBar('Go to Bar', 'Score Editor', KeyPlace.scoreEditor, [_K(_L.keyG, command: true)]),
  showEnds('Show the first / last bar', 'Score Editor', KeyPlace.scoreEditor, [_K(_L.home), _K(_L.end)]),
  goToEnds('Go to the first / last bar', 'Score Editor', KeyPlace.scoreEditor, [_K(_L.home, command: true), _K(_L.end, command: true)]),
  zoomIn('Zoom In', 'Score Editor', KeyPlace.scoreEditor, [_K(_L.equal, command: true)]),
  zoomOut('Zoom Out', 'Score Editor', KeyPlace.scoreEditor, [_K(_L.minus, command: true)]),
  actualSize('Actual Size', 'Score Editor', KeyPlace.scoreEditor, [_K(_L.digit0, command: true)]),
  nextNote('Previous / next note', 'Score Editor', KeyPlace.scoreEditor, [_K(_L.arrowLeft), _K(_L.arrowRight)],
      help: '⇧ adds to the selection.'),
  nextBar('Previous / next bar', 'Score Editor', KeyPlace.scoreEditor, [_K(_L.arrowLeft, command: true), _K(_L.arrowRight, command: true)],
      help: '⇧ adds to the selection.'),
  nextStaff('Staff above / below', 'Score Editor', KeyPlace.scoreEditor, [_K(_L.arrowUp), _K(_L.arrowDown)]),
  stepUp('Up / down a step', 'Score Editor', KeyPlace.scoreEditor, [_K(_L.arrowUp, alt: true), _K(_L.arrowDown, alt: true)],
      help: 'With no note selected, the markings.'),
  octaveUp('Up / down an octave', 'Score Editor', KeyPlace.scoreEditor,
      [_K(_L.arrowUp, command: true, alt: true), _K(_L.arrowDown, command: true, alt: true)]),
  respell('Respell', 'Score Editor', KeyPlace.scoreEditor, [_K(_L.equal, alt: true), _K(_L.minus, alt: true)],
      help: 'As the note above / below.'),
  moveMarkings('Move markings', 'Score Editor', KeyPlace.scoreEditor, [_K(_L.arrowLeft, alt: true), _K(_L.arrowRight, alt: true)],
      help: '⇧ hairpins’ ends'),
  repeatSelection('Repeat the selection', 'Score Editor', KeyPlace.scoreEditor, [_K(_L.keyR)]),
  scoreDelete('Delete', 'Score Editor', KeyPlace.scoreEditor, [_K(_L.backspace), _K(_L.delete)]),
  scoreDeselect('Deselect', 'Score Editor', KeyPlace.scoreEditor, [_K(_L.escape)], help: 'Stops note input first.'),
  notes('Notes', 'Note Input', KeyPlace.scoreEditor, [], ranges: ['A–G'], help: 'With no caret, the selected notes’ pitch.'),
  chordNote('Add to the chord', 'Note Input', KeyPlace.scoreEditor, [], ranges: ['⌥⇧A–G']),
  chord('Chord', 'Note Input', KeyPlace.scoreEditor, [_K(_L.keyQ)]),
  noteValues('Note values', 'Note Input', KeyPlace.scoreEditor, [], ranges: ['1–9']),
  dot('Dot', 'Note Input', KeyPlace.scoreEditor, [_K(_L.period)]),
  flat('Flat', 'Note Input', KeyPlace.scoreEditor, [_K(_L.minus)]),
  natural('Natural', 'Note Input', KeyPlace.scoreEditor, [_K(_L.digit0)]),
  sharp('Sharp', 'Note Input', KeyPlace.scoreEditor, [_K(_L.equal)]),
  rest('Rest', 'Note Input', KeyPlace.scoreEditor, [_K(_L.comma)]),
  graceNote('Grace Note', 'Note Input', KeyPlace.scoreEditor, [_K(_L.slash)]),
  appoggiatura('Appoggiatura', 'Note Input', KeyPlace.scoreEditor, [_K(_L.slash, shift: true)]),
  tie('Tie', 'Note Input', KeyPlace.scoreEditor, [_K(_L.keyT)]),
  slur('Slur', 'Note Input', KeyPlace.scoreEditor, [_K(_L.keyS)]),
  tuplet('Tuplet', 'Note Input', KeyPlace.scoreEditor, [_K(_L.semicolon)]),
  endTuplet('End the tuplet', 'Note Input', KeyPlace.scoreEditor, [_K(_L.semicolon, shift: true)]),
  nextVoice('Next voice', 'Note Input', KeyPlace.scoreEditor, [_K(_L.keyV)]),
  caretOn('Move the caret on', 'Note Input', KeyPlace.scoreEditor, [_K(_L.space)]),
  accent('Accent', 'Note Input', KeyPlace.scoreEditor, [_K(_L.bracketLeft)]),
  staccato('Staccato', 'Note Input', KeyPlace.scoreEditor, [_K(_L.bracketRight)]),
  marcato('Marcato', 'Note Input', KeyPlace.scoreEditor, [_K(_L.bracketLeft, shift: true)]),
  tenuto('Tenuto', 'Note Input', KeyPlace.scoreEditor, [_K(_L.bracketRight, shift: true)]),
  staccatissimo('Staccatissimo', 'Note Input', KeyPlace.scoreEditor, [_K(_L.quote)]),
  dynamics('Dynamics', 'Notations', KeyPlace.scoreEditor, [_K(_L.keyD, shift: true)]),
  tempoMark('Tempo', 'Notations', KeyPlace.scoreEditor, [_K(_L.keyT, shift: true)]),
  timeSignature('Time Signature', 'Notations', KeyPlace.scoreEditor, [_K(_L.keyM, shift: true)]),
  keySignature('Key Signature', 'Notations', KeyPlace.scoreEditor, [_K(_L.keyK, shift: true)]),
  clef('Clef', 'Notations', KeyPlace.scoreEditor, [_K(_L.keyC, shift: true)]),
  textNotation('Text', 'Notations', KeyPlace.scoreEditor, [_K(_L.keyX, shift: true)]),
  bars('Bars and Barlines', 'Notations', KeyPlace.scoreEditor, [_K(_L.keyB, shift: true)]),
  repeats('Repeats', 'Notations', KeyPlace.scoreEditor, [_K(_L.keyR, shift: true)]),
  rehearsalMark('Rehearsal Mark', 'Notations', KeyPlace.scoreEditor, [_K(_L.keyA, shift: true)]),
  holds('Holds', 'Notations', KeyPlace.scoreEditor, [_K(_L.keyH, shift: true)]),
  ornaments('Ornaments', 'Notations', KeyPlace.scoreEditor, [_K(_L.keyO, shift: true)]),
  lyrics('Lyrics', 'Notations', KeyPlace.scoreEditor, [_K(_L.keyL, shift: true)]),

  // A PDF's import.
  nextPage('Previous / next page', 'PDF Import', KeyPlace.pdfImport,
      [_K(_L.arrowLeft), _K(_L.arrowRight), _K(_L.pageUp), _K(_L.pageDown)]),
  pdfSelect('Select', 'PDF Import', KeyPlace.pdfImport, [_K(_L.keyV)]),
  addBarline('Add Barline', 'PDF Import', KeyPlace.pdfImport, [_K(_L.keyB)]),
  drawRegion('Draw Region', 'PDF Import', KeyPlace.pdfImport, [_K(_L.keyR)]),
  maskLane('Mask Lane', 'PDF Import', KeyPlace.pdfImport, [_K(_L.keyM)]),
  maskAll('Mask All Lanes', 'PDF Import', KeyPlace.pdfImport, [_K(_L.keyM, shift: true)]),
  pdfDelete('Delete', 'PDF Import', KeyPlace.pdfImport, [_K(_L.backspace), _K(_L.delete)]),
  pdfDeselect('Deselect', 'PDF Import', KeyPlace.pdfImport, [_K(_L.escape)]),

  // Find Phrase's window.
  phraseNotes('Notes', 'Find Phrase', KeyPlace.findPhrase, [], ranges: ['A–G']),
  phraseRest('Rest', 'Find Phrase', KeyPlace.findPhrase, [_K(_L.keyR)]),
  phraseValues('Note values', 'Find Phrase', KeyPlace.findPhrase, [], ranges: ['3–8']),
  phraseDot('Dot', 'Find Phrase', KeyPlace.findPhrase, [_K(_L.period)]),
  phraseFlat('Flat', 'Find Phrase', KeyPlace.findPhrase, [_K(_L.minus)]),
  phraseNatural('Natural', 'Find Phrase', KeyPlace.findPhrase, [_K(_L.digit0)]),
  phraseSharp('Sharp', 'Find Phrase', KeyPlace.findPhrase, [_K(_L.equal)]),
  phraseStep('Up / down a step', 'Find Phrase', KeyPlace.findPhrase, [_K(_L.arrowUp), _K(_L.arrowDown)], help: '⇧ an octave'),
  phraseNote('Previous / next note', 'Find Phrase', KeyPlace.findPhrase, [_K(_L.arrowLeft), _K(_L.arrowRight)]),
  phraseDelete('Delete', 'Find Phrase', KeyPlace.findPhrase, [_K(_L.backspace), _K(_L.delete)]),
  nextMatch('Next / previous match', 'Find Phrase', KeyPlace.findPhrase, [_K(_L.enter), _K(_L.enter, shift: true)]),
  phrasePlay('Play / Pause', 'Find Phrase', KeyPlace.findPhrase, [_K(_L.space)]),
  phraseClose('Close', 'Find Phrase', KeyPlace.findPhrase, [_K(_L.escape)]),

  // The LilyPond editor and the score editor's MusicXML.
  engrave('Engrave', 'LilyPond and MusicXML', KeyPlace.code, [_K(_L.keyR, command: true)]),
  find('Find', 'LilyPond and MusicXML', KeyPlace.code, [_K(_L.keyF, command: true)]),
  replace('Replace', 'LilyPond and MusicXML', KeyPlace.code, [_K(_L.keyF, command: true, alt: true)]),
  codeMatch('Next / previous match', 'LilyPond and MusicXML', KeyPlace.code, [_K(_L.enter), _K(_L.enter, shift: true)]),
  closeFind('Close Find', 'LilyPond and MusicXML', KeyPlace.code, [_K(_L.escape)]);

  const KeyCommand(this.label, this._group, this.place, this._keys,
      {this._other, this.also = const [], this.ranges = const [], this.help, this.editable = false, this.macOnly = false});

  /// Its name, in English (translated where shown).
  final String label;
  final String _group;
  final KeyPlace place;
  final List<KeyChord> _keys;
  final List<KeyChord>? _other;

  /// Keys it also takes, not listed (⌃Z beside ⌘Z on macOS; ⇧ with arrows its [help] tells of).
  final List<KeyChord> also;

  /// Keys listed after its chords that no one chord is: "A–G" (written as on macOS, see [keysText]).
  final List<String> ranges;

  /// A line under its name, in English, its keys written as on macOS.
  final String? help;

  /// Whether the user can give it another key ([KeyMap]). Each such has one key at most.
  final bool editable;

  /// Whether only macOS has it (the system's menu items).
  final bool macOnly;

  /// Whether this system has it.
  bool get shown => !macOnly || _mac;

  /// The heading it is listed under: the menu it is in, or its window or the editor's tab.
  String get group => this == previousTab || this == nextTab ? (_mac ? 'Window' : 'View') : _group;

  /// Its keys as the app comes, the first the one menus show.
  List<KeyChord> get defaults => _mac ? _keys : _other ?? _keys;

  /// Whether [key] can be its key: a menu's key holds ⌘ or ⌃ (or is a function key), so typing
  /// it in a field still types; and is one a menu can show: a letter, digit or sign, Tab or a
  /// function key. Null when it can, else why not.
  String? refuses(KeyChord key) {
    if (place != KeyPlace.menus) return null;
    final function = _functionKeys.contains(key.key);
    if (!key.commanded && !function) return _mac ? 'Add ⌘ or ⌃'.tr : 'Add Ctrl'.tr;
    if (!function && key.key != LogicalKeyboardKey.tab && key.key.keyLabel.runes.length != 1) return 'Menus can’t show this key'.tr;
    return null;
  }

  static final _functionKeys = {
    LogicalKeyboardKey.f1, LogicalKeyboardKey.f2, LogicalKeyboardKey.f3, LogicalKeyboardKey.f4, LogicalKeyboardKey.f5,
    LogicalKeyboardKey.f6, LogicalKeyboardKey.f7, LogicalKeyboardKey.f8, LogicalKeyboardKey.f9, LogicalKeyboardKey.f10,
    LogicalKeyboardKey.f11, LogicalKeyboardKey.f12,
  };
}

/// [text] as this system writes keys: as it is on macOS; elsewhere ↩ and ⌦ by name, then
/// [windowsKeys] ("⌥⇧A–G" is "Alt+Shift+A–G").
String keysText(String text) => _mac ? text : windowsKeys(text.replaceAll('↩', 'Enter').replaceAll('⌦', 'Delete'));

/// The keys the user gave commands ([KeyCommand.editable]) in place of their own, and what each
/// command's keys are with those.
@immutable
class KeyMap {
  const KeyMap([this._chosen = const {}]);

  /// Every command with its own keys.
  static const standard = KeyMap();

  /// A command's key (null: none), where the user chose one.
  final Map<KeyCommand, KeyChord?> _chosen;

  /// The keys as set where [context] is ([KeyMapScope]); as the app comes outside one.
  static KeyMap of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<KeyMapScope>()?.keys ?? standard;

  /// [command]'s keys: the one chosen (or none), else its own.
  List<KeyChord> keysOf(KeyCommand command) => _chosen.containsKey(command) ? [?_chosen[command]] : command.defaults;

  /// [command]'s keys as listed: each chord's (two written the same, once), then its ranges.
  List<String> labelsOf(KeyCommand command) =>
      {for (final key in keysOf(command)) key.label, for (final range in command.ranges) keysText(range)}.toList();

  /// The key it shows (in its menu, a tooltip): its first; null while it has none.
  KeyChord? operator [](KeyCommand command) => keysOf(command).firstOrNull;

  /// Whether [command]'s keys are other than its own.
  bool isChanged(KeyCommand command) => _chosen.containsKey(command);

  /// Whether every command has its own keys.
  bool get isStandard => _chosen.isEmpty;

  /// [command] given [key] (null: none); as it comes when that is its own key.
  KeyMap withKey(KeyCommand command, KeyChord? key) {
    assert(command.editable);
    final chosen = {..._chosen}..remove(command);
    if (!listEquals([?key], command.defaults)) chosen[command] = key;
    return KeyMap(Map.unmodifiable(chosen));
  }

  /// [command] with its own keys again.
  KeyMap reset(KeyCommand command) => KeyMap(Map.unmodifiable({..._chosen}..remove(command)));

  /// The command other than [command] that [key] gives where [command]'s keys work, if one does.
  KeyCommand? takenBy(KeyCommand command, KeyChord key) {
    for (final other in KeyCommand.values) {
      if (other == command || !other.shown || !other.place.sharesKeysWith(command.place)) continue;
      if (keysOf(other).contains(key) || (!_chosen.containsKey(other) && other.also.contains(key))) return other;
    }
    return null;
  }

  /// As saved: `{"open": "6f+c", "warp": ""}`, by name, "" for none.
  String write() => jsonEncode({for (final MapEntry(:key, :value) in _chosen.entries) key.name: value?.write() ?? ''});

  /// What [write] wrote; what can't be read (a command no longer there, or no longer the user's
  /// to change) left out; the standard map from nothing.
  static KeyMap read(String? json) {
    if (json == null) return standard;
    try {
      final saved = (jsonDecode(json) as Map).cast<String, Object?>();
      final names = KeyCommand.values.asNameMap();
      final chosen = <KeyCommand, KeyChord?>{};
      for (final MapEntry(:key, :value) in saved.entries) {
        final command = names[key];
        if (command == null || !command.editable || value is! String) continue;
        if (value.isEmpty) {
          chosen[command] = null;
        } else if (KeyChord.read(value) case final chord?) {
          chosen[command] = chord;
        }
      }
      return KeyMap(Map.unmodifiable(chosen));
    } catch (_) {
      return standard; // not a map: damaged, or a newer version's
    }
  }

  @override
  bool operator ==(Object other) => other is KeyMap && mapEquals(other._chosen, _chosen);

  @override
  int get hashCode => Object.hashAllUnordered(_chosen.entries.map((e) => Object.hash(e.key, e.value)));
}

/// Gives the widgets under it the keys as set ([KeyMap.of]): the app puts one over the window,
/// with [AppSettings.keys].
class KeyMapScope extends InheritedWidget {
  const KeyMapScope({super.key, required this.keys, required super.child});
  final KeyMap keys;

  @override
  bool updateShouldNotify(KeyMapScope oldWidget) => keys != oldWidget.keys;
}

/// A tooltip naming [command]'s key where [context] is: [withKey] given it (a text with
/// "{key}"), or [without] while it has none.
String keyed(BuildContext context, KeyCommand command, String Function(String key) withKey, String without) =>
    switch (KeyMap.of(context)[command]) { final key? => withKey(key.label), null => without };
