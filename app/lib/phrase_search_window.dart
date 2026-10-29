import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'dialog_kit.dart';
import 'editor_controller.dart';
import 'latest.dart';
import 'menu_kit.dart';
import 'ui_kit.dart';
import 'l10n/l10n.dart';

/// Edit ▸ Find Phrase… (⌘F): a melody entered on a staff, engraved by Verovio as it is typed, and
/// every place in the score that plays it ([PhraseSearch]), exactly or nearly, in any key or as
/// written, with or without its rhythm. A window over the editor, not modal, moved by its title:
/// a match clicked (or Enter, ⇧Enter) puts the playhead there, the score showing it under the
/// pointer; double-clicked, it also folds the window down to a bar (the match, the ones before and
/// after, and the window opened again). What was entered stays for the next time it opens, while the
/// app runs.
class PhraseSearchWindow extends StatefulWidget {
  const PhraseSearchWindow({super.key, required this.controller, required this.onClose});
  final EditorController controller;
  final VoidCallback onClose;

  static OverlayEntry? _shown;
  static final _focus = FocusNode(debugLabel: 'Find Phrase');

  /// Whether it is open (folded down or not): the toolbar's button shows it.
  static final shown = ValueNotifier(false);

  /// Folded down to a bar.
  static final _collapsed = ValueNotifier(false);

  /// Shows it over [overlay], opened out, or opens it out and gives it the keyboard if it is
  /// already there.
  static void show(OverlayState overlay, EditorController controller) {
    _collapsed.value = false;
    if (_shown != null) {
      _focus.requestFocus();
      return;
    }
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => PhraseSearchWindow(
        controller: controller,
        onClose: () {
          if (_shown != entry) return;
          close();
        },
      ),
    );
    overlay.insert(_shown = entry);
    shown.value = true;
  }

  static void close() {
    _shown?.remove();
    _shown = null;
    shown.value = false;
  }

  @override
  State<PhraseSearchWindow> createState() => _PhraseSearchWindowState();
}

/// What was entered, kept for the next time the window opens.
class _Entry {
  Phrase phrase = Phrase.empty;
  int? selected;
  NoteValue value = NoteValue.quarter;
  bool dotted = false;
  bool similar = false;
  bool anyKey = true;
  bool rhythm = true;
  PhraseClef clef = PhraseClef.auto;
}

class _PhraseSearchWindowState extends State<PhraseSearchWindow> {
  static const _width = 600.0, _barWidth = 420.0, _barHeight = 44.0;
  static final _entry = _Entry();

  /// The lines last read, for the score they were read from (its file and bars).
  static ({String xml, List<double> starts, Future<List<ScoreLine>> lines})? _read;

  /// Its top right corner, once moved (the bar keeps it there too): at first by the editor's right
  /// edge, under the toolbar.
  Offset? _corner;

  /// The match last clicked, and when: a second click soon after on it is a double-click.
  (int, DateTime)? _lastClick;
  PhrasePicture? _picture;
  final _engraving = Latest();
  List<ScoreLine>? _lines;
  List<PhraseMatch> _matches = const [];
  int? _current;

  EditorController get _controller => widget.controller;
  Phrase get _phrase => _entry.phrase;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_controllerChanged);
    PhraseSearchWindow._collapsed.addListener(_collapsedChanged);
    _readLines();
    _engrave();
    PhraseSearchWindow._focus.requestFocus();
  }

  @override
  void dispose() {
    _controller.removeListener(_controllerChanged);
    PhraseSearchWindow._collapsed.removeListener(_collapsedChanged);
    _engraving.cancel();
    _picture?.dispose();
    super.dispose();
  }

  bool get _isCollapsed => PhraseSearchWindow._collapsed.value;

  void _collapsedChanged() => setState(() {});

  void _collapse(bool collapsed) {
    PhraseSearchWindow._collapsed.value = collapsed;
    PhraseSearchWindow._focus.requestFocus();
  }

  void _controllerChanged() {
    if (_controller.score == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onClose());
    } else {
      _readLines();
    }
  }

  /// Reads the score's lines once per score (on an isolate: a large score's XML takes a while).
  void _readLines() {
    final score = _controller.score;
    if (score == null) return;
    final xml = score.musicXML, starts = score.timeline.measureStarts;
    final read = _read;
    if (read == null || !identical(read.xml, xml) || !listEquals(read.starts, starts)) {
      _read = (xml: xml, starts: starts, lines: _readOff(xml, starts));
    }
    final lines = _read!.lines;
    unawaited(lines.then((value) {
      if (!mounted || !identical(_read?.lines, lines) || identical(value, _lines)) return;
      setState(() {
        _lines = value;
        _search();
      });
    }));
  }

  /// On an isolate, from a static function: a closure made beside one that uses the state
  /// would take the state along, which can't be sent.
  static Future<List<ScoreLine>> _readOff(String xml, List<double> starts) => Isolate.run(() => ScoreLine.read(xml, starts));

  Future<void> _engrave() async {
    final turn = _engraving.start(), phrase = _phrase;
    final picture = await PhrasePicture.engrave(phrase);
    if (!mounted || !turn.isLatest) {
      picture.dispose();
      return;
    }
    final old = _picture;
    setState(() => _picture = picture);
    // Its glyphs may still be in the frame on screen.
    if (old != null) WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  void _search() {
    final lines = _lines;
    _matches = lines == null
        ? const []
        : PhraseSearch.find(_phrase, lines, similar: _entry.similar, anyKey: _entry.anyKey, rhythm: _entry.rhythm);
    _current = null;
  }

  // MARK: Editing

  /// A new phrase (and the note selected), engraved and looked for.
  void _set(List<PhraseNote> notes, int? selected) {
    setState(() {
      _entry
        ..phrase = Phrase(List.unmodifiable(notes), clef: _entry.clef)
        ..selected = notes.isEmpty ? null : selected?.clamp(0, notes.length - 1);
      _search();
    });
    unawaited(_engrave());
  }

  void _setOptions(void Function(_Entry) change) => setState(() {
        change(_entry);
        _search();
      });

  int? get _selected => _entry.selected;

  /// [note] after the one selected (or at the end), selected.
  void _insert(PhraseNote note) {
    final notes = [..._phrase.notes];
    final at = (_selected ?? notes.length - 1) + 1;
    notes.insert(at, note);
    _set(notes, at);
  }

  /// The pitched note nearest before the insertion point, for the octave of a letter typed.
  int? get _previousPitch {
    final notes = _phrase.notes;
    for (var i = math.min(_selected ?? notes.length - 1, notes.length - 1); i >= 0; i--) {
      if (notes[i].midi case final midi?) return midi;
    }
    return null;
  }

  void _letter(int step) =>
      _insert(PhraseNote.nearest(step, _previousPitch, value: _entry.value, dotted: _entry.dotted));

  void _rest() => _insert(PhraseNote.rest(value: _entry.value, dotted: _entry.dotted));

  /// Changes the note selected.
  void _change(PhraseNote Function(PhraseNote) change) {
    final i = _selected;
    if (i == null || i >= _phrase.notes.length) return;
    final notes = [..._phrase.notes];
    notes[i] = change(notes[i]);
    _set(notes, i);
  }

  void _value(NoteValue value) {
    setState(() => _entry.value = value);
    _change((n) => n.copyWith(value: value));
  }

  void _dot() {
    setState(() => _entry.dotted = !_entry.dotted);
    _change((n) => n.copyWith(dotted: _entry.dotted));
  }

  void _alter(int alter) => _change((n) => n.copyWith(alter: n.alter == alter ? 0 : alter));

  void _delete() {
    final notes = [..._phrase.notes];
    if (notes.isEmpty) return;
    final i = _selected ?? notes.length - 1;
    notes.removeAt(i);
    _set(notes, i - 1 < 0 ? (notes.isEmpty ? null : 0) : i - 1);
  }

  /// The clef it is written in (and a click on the staff read in).
  void _clef(PhraseClef clef) {
    _entry.clef = clef;
    _set(_phrase.notes, _selected);
  }

  void _select(int? i) => setState(() => _entry.selected = i);

  // MARK: Matches

  void _goTo(int index) {
    if (index < 0 || index >= _matches.length || _controller.score == null) return;
    setState(() => _current = index);
    _controller.playback.goToQuarter(_matches[index].start);
  }

  /// A match clicked: the playhead goes there; clicked twice, the window folds down to a bar too.
  void _clicked(int index) {
    final now = DateTime.now(), last = _lastClick;
    _lastClick = (index, now);
    _goTo(index);
    if (last != null && last.$1 == index && now.difference(last.$2) < kDoubleTapTimeout) {
      _lastClick = null;
      _collapse(true);
    }
  }

  /// The next match (or previous, [by] -1): after the one shown, else from the playhead.
  void _step(int by) {
    if (_matches.isEmpty || _controller.score == null) return;
    final current = _current;
    if (current != null) {
      _goTo((current + by) % _matches.length);
      return;
    }
    final here = _controller.timeline.quarterAtSeconds(_controller.playback.time.value);
    final next = _matches.indexWhere((m) => m.start >= here - 1e-6);
    _goTo(by > 0 ? (next < 0 ? 0 : next) : ((next < 0 ? _matches.length : next) - 1) % _matches.length);
  }

  // MARK: Keys

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (keys.isMetaPressed || keys.isControlPressed || keys.isAltPressed) return KeyEventResult.ignored;
    final key = event.logicalKey, shift = keys.isShiftPressed;
    final character = event.character?.toUpperCase() ?? '';
    final letter = character.length == 1 ? PhraseNote.letters.indexOf(character) : -1;
    // Folded down, the phrase can't be seen, so isn't edited.
    if (_isCollapsed) {
      final action = switch (key) {
        LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter => () => _step(shift ? -1 : 1),
        LogicalKeyboardKey.arrowLeft => () => _step(-1),
        LogicalKeyboardKey.arrowRight => () => _step(1),
        LogicalKeyboardKey.space => _controller.playback.togglePlay,
        LogicalKeyboardKey.escape => widget.onClose,
        _ => null,
      };
      action?.call();
      return action == null ? KeyEventResult.ignored : KeyEventResult.handled;
    }
    void Function()? action = switch (key) {
      _ when letter >= 0 => () => _letter(letter),
      LogicalKeyboardKey.keyR => _rest,
      LogicalKeyboardKey.digit3 => () => _value(NoteValue.thirtySecond),
      LogicalKeyboardKey.digit4 => () => _value(NoteValue.sixteenth),
      LogicalKeyboardKey.digit5 => () => _value(NoteValue.eighth),
      LogicalKeyboardKey.digit6 => () => _value(NoteValue.quarter),
      LogicalKeyboardKey.digit7 => () => _value(NoteValue.half),
      LogicalKeyboardKey.digit8 => () => _value(NoteValue.whole),
      LogicalKeyboardKey.period => _dot,
      LogicalKeyboardKey.minus => () => _alter(-1),
      LogicalKeyboardKey.equal => () => _alter(1),
      LogicalKeyboardKey.digit0 => () => _change((n) => n.copyWith(alter: 0)),
      LogicalKeyboardKey.arrowUp => () => _change((n) => n.stepped(shift ? 7 : 1)),
      LogicalKeyboardKey.arrowDown => () => _change((n) => n.stepped(shift ? -7 : -1)),
      LogicalKeyboardKey.arrowLeft => () => _select(math.max(0, (_selected ?? _phrase.notes.length) - 1)),
      LogicalKeyboardKey.arrowRight => () =>
          _select(_phrase.notes.isEmpty ? null : math.min(_phrase.notes.length - 1, (_selected ?? -1) + 1)),
      LogicalKeyboardKey.backspace || LogicalKeyboardKey.delete => _delete,
      LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter => () => _step(shift ? -1 : 1),
      LogicalKeyboardKey.space => _controller.playback.togglePlay,
      LogicalKeyboardKey.escape => widget.onClose,
      _ => null,
    };
    if (action == null) return KeyEventResult.ignored;
    action();
    return KeyEventResult.handled;
  }

  // MARK: Layout

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final size = MediaQuery.sizeOf(context);
    final collapsed = _isCollapsed;
    final width = collapsed ? _barWidth : _width;
    final height = collapsed ? _barHeight : math.min(600.0, size.height - 96);
    Offset clamp(Offset o) =>
        Offset(o.dx.clamp(math.min(width, size.width), math.max(width, size.width)), o.dy.clamp(0, math.max(0, size.height - 52)));
    final corner = clamp(_corner ?? Offset(size.width - 24, 72));
    void drag(DragUpdateDetails d) => setState(() => _corner = clamp(corner + d.delta));
    return Positioned(
      left: corner.dx - width,
      top: corner.dy,
      width: width,
      height: height,
      child: Focus(
        focusNode: PhraseSearchWindow._focus,
        onKeyEvent: _key,
        child: FocusScope(
          // Apart from the editor's frames: playback repaints the score under it every frame.
          child: RepaintBoundary(
            child: Material(
              color: Theme.of(context).dialogTheme.backgroundColor,
              elevation: 16,
              shadowColor: Colors.black.withValues(alpha: 0.2),
              animationDuration: Duration.zero,
              shape: AppStyle.of(context).isCarbon
                  ? const RoundedRectangleBorder()
                  : RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: colors.line)),
              clipBehavior: Clip.antiAlias,
              child: Listener(
                // A click anywhere in it gives it the keyboard back (from a checkbox, say).
                onPointerDown: (_) => PhraseSearchWindow._focus.requestFocus(),
                child: collapsed ? _bar(context, drag) : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: drag,
                    child: Container(
                      height: 52,
                      padding: const EdgeInsets.only(left: 24, right: 10),
                      child: Row(children: [
                        Text('Find Phrase'.tr, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: colors.text)),
                        const Spacer(),
                        ToolbarButton(icon: AppIcon.collapse.of(context), tooltip: 'Collapse'.tr, onPressed: () => _collapse(true)),
                        ToolbarButton(icon: AppIcon.close.of(context), tooltip: 'Close'.tr, onPressed: widget.onClose),
                      ]),
                    ),
                  ),
                  Divider(height: 1, color: colors.line),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      _tools(context),
                      const SizedBox(height: 10),
                      _PhraseStaff(
                        picture: _picture,
                        selected: _selected,
                        value: _entry.value,
                        dotted: _entry.dotted,
                        onSelect: _select,
                        onAdd: _insert,
                      ),
                      const SizedBox(height: 8),
                      _Keyboard(
                        selected: switch (_selected) { final i? when i < _phrase.notes.length => _phrase.notes[i].midi, _ => null },
                        onKey: (midi) => _insert(PhraseNote.ofMidi(midi, value: _entry.value, dotted: _entry.dotted)),
                      ),
                      const SizedBox(height: 14),
                      _options(context),
                      const SizedBox(height: 10),
                    ]),
                  ),
                  Divider(height: 1, color: colors.line),
                  Expanded(child: _results(context)),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Folded down: moved by its title as the window is; the match gone to (or how many there are),
  /// the one before and after, the window opened out again, and Close.
  Widget _bar(BuildContext context, GestureDragUpdateCallback drag) {
    final colors = context.colors;
    final score = _controller.score, current = _current;
    final match = current != null && current < _matches.length ? _matches[current] : null;
    final part = match == null ? null : score?.metadata.parts.where((p) => p.id == match.partId).firstOrNull;
    final where = match == null || part == null
        ? _count
        : '${'Bar {bar}'.fill({'bar': _controller.beats.format(match.start, compact: true)})} · ${_controller.partName(part)}';
    final figures = TextStyle(fontSize: 13, color: colors.textMuted, fontFeatures: const [FontFeature.tabularFigures()]);
    return Row(children: [
      Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: drag,
          onDoubleTap: () => _collapse(false),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, right: 8),
            child: Row(children: [
              Icon(AppIcon.search.of(context), size: 16, color: colors.textMuted),
              const SizedBox(width: 8),
              Flexible(child: Text(where, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: colors.text))),
              const SizedBox(width: 8),
              if (match != null) Text('${current! + 1}/${_matches.length}', style: figures),
            ]),
          ),
        ),
      ),
      ToolbarButton(icon: AppIcon.previous.of(context), tooltip: 'Previous ({key})'.fill({'key': shortcut('⇧↩', 'Shift+Enter')}), onPressed: _matches.isEmpty ? null : () => _step(-1)),
      ToolbarButton(icon: AppIcon.next.of(context), tooltip: 'Next ({key})'.fill({'key': shortcut('↩', 'Enter')}), onPressed: _matches.isEmpty ? null : () => _step(1)),
      const ToolbarDivider(),
      ToolbarButton(icon: AppIcon.expand.of(context), tooltip: 'Expand'.tr, onPressed: () => _collapse(false)),
      ToolbarButton(icon: AppIcon.close.of(context), tooltip: 'Close'.tr, onPressed: widget.onClose),
      const SizedBox(width: 6),
    ]);
  }

  /// How many matches there are ('' with nothing to look for, or the score not read yet).
  String get _count => _phrase.pitched.isEmpty || _lines == null
      ? ''
      : switch (_matches.length) {
          0 => 'No matches'.tr,
          1 => '1 match'.tr,
          final n => '{n} matches'.fill({'n': n}),
        };

  Widget _tools(BuildContext context) {
    final selected = switch (_selected) { final i? when i < _phrase.notes.length => _phrase.notes[i], _ => null };
    Widget value(NoteValue v, int glyph, String tip) => ToolbarButton(
        glyph: _Glyph(glyph, lift: v == NoteValue.whole ? 0 : 1.5),
        tooltip: tip,
        selected: _entry.value == v,
        onPressed: () => _value(v));
    Widget alter(int alter, int glyph, String tip, {double lift = 0}) => ToolbarButton(
        glyph: _Glyph(glyph, lift: lift),
        tooltip: tip,
        selected: selected != null && !selected.isRest && selected.alter == alter && alter != 0,
        onPressed: selected == null || selected.isRest ? null : () => _alter(alter));
    return Row(children: [
      _ClefMenu(clef: _entry.clef, shown: _phrase.shownClef, onSelected: _clef),
      const ToolbarDivider(),
      ToolGroup(children: [
        value(NoteValue.whole, 0xE1D2, 'Whole (8)'.tr),
        value(NoteValue.half, 0xE1D3, 'Half (7)'.tr),
        value(NoteValue.quarter, 0xE1D5, 'Quarter (6)'.tr),
        value(NoteValue.eighth, 0xE1D7, 'Eighth (5)'.tr),
        value(NoteValue.sixteenth, 0xE1D9, '16th (4)'.tr),
        value(NoteValue.thirtySecond, 0xE1DB, '32nd (3)'.tr),
      ]),
      const SizedBox(width: 6),
      ToolbarButton(glyph: const _Glyph(0xE1E7, size: 26), tooltip: 'Dot (.)'.tr, selected: _entry.dotted, onPressed: _dot),
      const ToolbarDivider(),
      ToolGroup(children: [
        alter(-1, 0xE260, 'Flat (-)'.tr, lift: 0.5),
        alter(0, 0xE261, 'Natural (0)'.tr),
        alter(1, 0xE262, 'Sharp (=)'.tr),
      ]),
      const SizedBox(width: 6),
      ToolbarButton(glyph: const _Glyph(0xE4E5), tooltip: 'Rest (R)'.tr, onPressed: _rest),
      const Spacer(),
      ToolbarButton(icon: AppIcon.removeNote.of(context), tooltip: 'Delete note ({key})'.fill({'key': shortcut('⌫', 'Backspace')}), onPressed: _phrase.isEmpty ? null : _delete),
      ToolbarButton(icon: AppIcon.reset.of(context), tooltip: 'Clear'.tr, onPressed: _phrase.isEmpty ? null : () => _set(const [], null)),
    ]);
  }

  Widget _options(BuildContext context) => Row(children: [
        AppSegmented<bool>(
          segments: [
            ButtonSegment(value: false, label: Text('Exact'.tr)),
            ButtonSegment(value: true, label: Text('Similar'.tr)),
          ],
          selected: _entry.similar,
          onChanged: (v) => _setOptions((e) => e.similar = v),
        ),
        const SizedBox(width: 20),
        SizedBox(
          width: 110,
          child: AppCheckRow(value: _entry.anyKey, label: 'Any key'.tr, onChanged: (v) => _setOptions((e) => e.anyKey = v ?? false)),
        ),
        SizedBox(
          width: 110,
          child: AppCheckRow(value: _entry.rhythm, label: 'Rhythm'.tr, onChanged: (v) => _setOptions((e) => e.rhythm = v ?? false)),
        ),
        const Spacer(),
        Text(
          _count,
          style: TextStyle(fontSize: 13, color: context.colors.textMuted),
        ),
      ]);

  Widget _results(BuildContext context) {
    final colors = context.colors;
    final score = _controller.score;
    if (score == null || _matches.isEmpty) return const SizedBox.shrink();
    final names = {for (final p in score.metadata.parts) p.id: _controller.partName(p)};
    final figures = TextStyle(fontSize: 13, color: colors.textMuted, fontFeatures: const [FontFeature.tabularFigures()]);
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: _matches.length,
      itemExtent: 32,
      itemBuilder: (context, i) {
        final match = _matches[i];
        final t = match.transposition;
        return Material(
          color: i == _current ? colors.accentSoft : Colors.transparent,
          animationDuration: Duration.zero,
          child: InkWell(
            onTap: () => _clicked(i),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(children: [
                SizedBox(
                  width: 84,
                  child: Text('Bar {bar}'.fill({'bar': _controller.beats.format(match.start, compact: true)}),
                      style: const TextStyle(fontSize: 13, fontFeatures: [FontFeature.tabularFigures()])),
                ),
                Expanded(child: Text(names[match.partId] ?? match.partId, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
                if (_entry.anyKey) SizedBox(width: 44, child: Text(t == 0 ? '' : t > 0 ? '+$t' : '−${-t}', textAlign: TextAlign.right, style: figures)),
                if (_entry.similar)
                  SizedBox(width: 52, child: Text('${(match.similarity * 100).round()}%', textAlign: TextAlign.right, style: figures)),
              ]),
            ),
          ),
        );
      },
    );
  }
}

/// The clef the phrase is written in: Auto (treble, or bass for low notes), or one chosen. Shows the
/// clef it is in, as the staff does.
class _ClefMenu extends StatelessWidget {
  const _ClefMenu({required this.clef, required this.shown, required this.onSelected});
  final PhraseClef clef, shown;
  final ValueChanged<PhraseClef> onSelected;

  static String _label(PhraseClef c) => switch (c) {
        PhraseClef.auto => 'Auto'.tr,
        PhraseClef.treble => 'Treble'.tr,
        PhraseClef.treble8vb => 'Treble 8vb'.tr,
        PhraseClef.alto => 'Alto'.tr,
        PhraseClef.tenor => 'Tenor'.tr,
        PhraseClef.bass => 'Bass'.tr,
      };

  /// How far each clef's ink's middle is above its origin, in staff spaces.
  static double _lift(PhraseClef c) => switch (c.sign) { 'G' => c.octave == 0 ? 1 : 0.5, 'F' => -0.6, _ => 0 };

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // A select, not a popup menu: its menu (an OverlayPortal's) draws over this window, which a
    // popup menu's route, put in under the window's overlay entry, would not.
    return Tip(
      message: 'Clef'.tr,
      child: AppDropdown<PhraseClef>(
        value: clef,
        dense: true,
        icon: Icon(AppIcon.dropDown.of(context)),
        onChanged: (c) {
          if (c != null) onSelected(c);
        },
        items: [
          for (final c in PhraseClef.values)
            DropdownMenuItem(
              value: c,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                // Auto shows the clef it chose.
                _Glyph((c == PhraseClef.auto ? shown : c).glyph, lift: _lift(c == PhraseClef.auto ? shown : c), size: 12, color: colors.text),
                const SizedBox(width: 4),
                Text(_label(c)),
              ]),
            ),
        ],
      ),
    );
  }
}

/// A SMuFL glyph of the bundled Bravura, centred in its box: [lift] staff spaces is how far its
/// ink's middle is above the glyph's origin (a note's stem rises from its head).
class _Glyph extends StatelessWidget {
  const _Glyph(this.code, {this.lift = 0, this.size = 18, this.color});
  final int code;
  final double lift, size;

  /// Its colour (default: the [IconTheme]'s, a toolbar button's).
  final Color? color;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: const Size.square(20), painter: _GlyphPainter(code, lift, size, color ?? IconTheme.of(context).color ?? context.colors.text));
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.code, this.lift, this.size, this.color);
  final int code;
  final double lift, size;
  final Color color;

  @override
  void paint(Canvas canvas, Size box) {
    final glyph = TextPainter(
      text: TextSpan(
          text: String.fromCharCode(code),
          style: TextStyle(color: color, fontFamily: const RenderStyle().musicFontFamily, fontSize: size, height: 1)),
      textDirection: TextDirection.ltr,
    )..layout();
    final space = size / 4; // SMuFL: a staff space is a quarter of the em
    final baseline = box.height / 2 + lift * space;
    glyph.paint(canvas, Offset((box.width - glyph.width) / 2, baseline - glyph.computeDistanceToActualBaseline(TextBaseline.alphabetic)));
    glyph.dispose();
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.code != code || old.lift != lift || old.size != size || old.color != color;
}

/// The phrase on a staff, as Verovio engraves it: a click on a note selects it, anywhere else adds
/// a note of the pitch clicked after the one selected (a faint head shows where); the selected
/// note is tinted.
class _PhraseStaff extends StatefulWidget {
  const _PhraseStaff({
    required this.picture,
    required this.selected,
    required this.value,
    required this.dotted,
    required this.onSelect,
    required this.onAdd,
  });
  final PhrasePicture? picture;
  final int? selected;
  final NoteValue value;
  final bool dotted;
  final ValueChanged<int> onSelect;
  final ValueChanged<PhraseNote> onAdd;

  @override
  State<_PhraseStaff> createState() => _PhraseStaffState();
}

class _PhraseStaffState extends State<_PhraseStaff> {
  static const _height = 136.0, _space = 11.0, _margin = 14.0;
  Offset? _hover;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return LayoutBuilder(builder: (context, constraints) {
      final geometry = _Geometry.of(widget.picture, widget.selected, constraints.maxWidth);
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        onHover: (e) => setState(() => _hover = e.localPosition),
        onExit: (_) => setState(() => _hover = null),
        child: GestureDetector(
          onTapUp: (d) => _tap(geometry, d.localPosition),
          child: Container(
            height: _height,
            decoration: BoxDecoration(
              color: colors.scorePaper,
              border: Border.all(color: colors.line),
              borderRadius: AppStyle.of(context).radius(6),
            ),
            child: ClipRect(
              child: CustomPaint(
                size: Size(constraints.maxWidth, _height),
                painter: _StaffPainter(
                  picture: widget.picture,
                  geometry: geometry,
                  selected: widget.selected,
                  hover: _hover,
                  ink: colors.scoreInk,
                  tint: colors.accent,
                ),
              ),
            ),
          ),
        ),
      );
    });
  }

  void _tap(_Geometry? g, Offset at) {
    final picture = widget.picture;
    if (g == null || picture == null) return;
    final x = g.toPicture(at).dx;
    final hit = g.noteAt(x);
    if (hit != null) {
      widget.onSelect(hit);
    } else {
      widget.onAdd(picture.noteAt(g.toPicture(at).dy, value: widget.value, dotted: widget.dotted));
    }
  }
}

/// Where the picture is drawn in the staff's box: [scale] pixels a unit, moved left as the phrase
/// grows so the note selected (or the end) stays in view.
class _Geometry {
  _Geometry(this.picture, this.scale, this.offset);
  final PhrasePicture picture;
  final double scale;
  final Offset offset;

  static _Geometry? of(PhrasePicture? picture, int? selected, double width) {
    if (picture == null) return null;
    const space = _PhraseStaffState._space, margin = _PhraseStaffState._margin;
    final scale = space / picture.staffSpace;
    // The staff in the middle, moved up or down as far as the notes need to fit (centred on them
    // when they can't).
    const height = _PhraseStaffState._height, room = 6.0;
    var top = (height - 4 * space) / 2 - picture.staffTop * scale;
    if (picture.ink case final ink?) {
      final above = ink.top * scale + top, below = ink.bottom * scale + top;
      if (below - above > height - 2 * room) {
        top += height / 2 - (above + below) / 2;
      } else if (above < room) {
        top += room - above;
      } else if (below > height - room) {
        top -= below - (height - room);
      }
    }
    final xs = picture.noteXs;
    final focus = (selected != null && selected < xs.length ? xs[selected] : picture.right) * scale;
    final shift = math.max(0.0, focus + margin + 6 * space - width);
    return _Geometry(picture, scale, Offset(margin - shift, top));
  }

  Offset toPicture(Offset local) => (local - offset) / scale;

  /// Units from a note's left that count as clicking it.
  double get _reach => picture.staffSpace * 1.6;

  int? noteAt(double x) {
    final xs = picture.noteXs;
    for (var i = 0; i < xs.length; i++) {
      if (x >= xs[i] - picture.staffSpace * 0.5 && x <= xs[i] + _reach) return i;
    }
    return null;
  }

  /// Where a note added now goes: after the one [selected], or past the end.
  double insertAt(int? selected) {
    final xs = picture.noteXs;
    if (selected == null || selected + 1 >= xs.length) return math.max(picture.right, xs.lastOrNull ?? 0) + picture.staffSpace * 1.5;
    return (xs[selected] + xs[selected + 1]) / 2;
  }
}

class _StaffPainter extends CustomPainter {
  _StaffPainter({required this.picture, required this.geometry, required this.selected, required this.hover, required this.ink, required this.tint});
  final PhrasePicture? picture;
  final _Geometry? geometry;
  final int? selected;
  final Offset? hover;
  final Color ink, tint;

  @override
  void paint(Canvas canvas, Size size) {
    final picture = this.picture, g = geometry;
    final lines = Paint()..color = ink.withValues(alpha: 0.55);
    const space = _PhraseStaffState._space;
    final top = g == null ? (size.height - 4 * space) / 2 : g.offset.dy + g.picture.staffTop * g.scale;
    for (var l = 0; l < 5; l++) {
      canvas.drawRect(Rect.fromLTWH(0, top + l * space - 0.5, size.width, 1), lines);
    }
    if (picture == null || g == null) return;
    canvas
      ..save()
      ..translate(g.offset.dx, g.offset.dy)
      ..scale(g.scale);
    final unit = picture.staffSpace;
    if (selected case final i? when i < picture.noteXs.length) {
      final x = picture.noteXs[i];
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTRB(x - unit * 0.6, picture.staffTop - unit * 4, x + unit * 1.8, picture.staffTop + unit * 8),
            Radius.circular(unit * 0.5)),
        Paint()..color = tint.withValues(alpha: 0.16),
      );
    }
    picture.paint(canvas, ink);
    // Where a click would add a note, and its pitch.
    if (hover case final h?) {
      final at = g.toPicture(h);
      if (g.noteAt(at.dx) == null) {
        final steps = ((at.dy - picture.staffTop) / (unit / 2)).round();
        final y = picture.staffTop + steps * unit / 2, x = g.insertAt(selected);
        final faint = Paint()..color = tint.withValues(alpha: 0.5);
        canvas
          ..save()
          ..translate(x + unit * 0.6, y)
          ..rotate(-0.35)
          ..drawOval(Rect.fromCenter(center: Offset.zero, width: unit * 1.3, height: unit * 0.9), faint)
          ..restore();
        // Ledger lines out to it.
        final ledger = Paint()
          ..color = tint.withValues(alpha: 0.5)
          ..strokeWidth = unit * 0.16;
        for (var s = -2; s >= steps; s -= 2) {
          final ly = picture.staffTop + s * unit / 2;
          canvas.drawLine(Offset(x - unit * 0.3, ly), Offset(x + unit * 1.5, ly), ledger);
        }
        for (var s = 10; s <= steps; s += 2) {
          final ly = picture.staffTop + s * unit / 2;
          canvas.drawLine(Offset(x - unit * 0.3, ly), Offset(x + unit * 1.5, ly), ledger);
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StaffPainter old) =>
      old.picture != picture || old.selected != selected || old.hover != hover || old.ink != ink || old.tint != tint || old.geometry?.offset != geometry?.offset;
}

/// Three octaves of a keyboard (C3–B5): a key clicked adds that pitch (black keys as sharps);
/// the selected note's key is tinted.
class _Keyboard extends StatelessWidget {
  const _Keyboard({required this.selected, required this.onKey});
  final int? selected;
  final ValueChanged<int> onKey;

  static const low = 48, octaves = 3, _height = 40.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      return GestureDetector(
        onTapUp: (d) {
          if (_keyAt(d.localPosition, width) case final midi?) onKey(midi);
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: CustomPaint(
            size: Size(width, _height),
            painter: _KeyboardPainter(selected: selected, line: colors.line, tint: colors.accent, paper: colors.scorePaper, ink: colors.scoreInk),
          ),
        ),
      );
    });
  }

  static const _whites = [0, 2, 4, 5, 7, 9, 11];

  /// A black key's left, in white keys from its octave's C.
  static const _blacks = {1: 0.62, 3: 1.72, 6: 3.6, 8: 4.68, 10: 5.76};

  static int? _keyAt(Offset at, double width) {
    final white = width / (7 * octaves);
    if (at.dy < _height * 0.62) {
      for (var o = 0; o < octaves; o++) {
        for (final MapEntry(key: pc, value: left) in _blacks.entries) {
          final x = (o * 7 + left) * white;
          if (at.dx >= x && at.dx <= x + white * 0.62) return low + o * 12 + pc;
        }
      }
    }
    final i = (at.dx / white).floor();
    if (i < 0 || i >= 7 * octaves) return null;
    return low + (i ~/ 7) * 12 + _whites[i % 7];
  }
}

class _KeyboardPainter extends CustomPainter {
  _KeyboardPainter({required this.selected, required this.line, required this.tint, required this.paper, required this.ink});
  final int? selected;
  final Color line, tint, paper, ink;

  @override
  void paint(Canvas canvas, Size size) {
    const octaves = _Keyboard.octaves, low = _Keyboard.low;
    final white = size.width / (7 * octaves);
    final outline = Paint()
      ..color = line
      ..style = PaintingStyle.stroke;
    for (var i = 0; i < 7 * octaves; i++) {
      final midi = low + (i ~/ 7) * 12 + _Keyboard._whites[i % 7];
      final r = Rect.fromLTWH(i * white, 0, white, size.height).deflate(0.5);
      canvas
        ..drawRect(r, Paint()..color = midi == selected ? Color.alphaBlend(tint.withValues(alpha: 0.35), paper) : paper)
        ..drawRect(r, outline);
      if (midi % 12 == 0) {
        final label = TextPainter(
          text: TextSpan(text: 'C${midi ~/ 12 - 1}', style: TextStyle(fontSize: 9, color: ink.withValues(alpha: 0.45))),
          textDirection: TextDirection.ltr,
        )..layout();
        label.paint(canvas, Offset(i * white + (white - label.width) / 2, size.height - label.height - 2));
        label.dispose();
      }
    }
    for (var o = 0; o < octaves; o++) {
      for (final MapEntry(key: pc, value: left) in _Keyboard._blacks.entries) {
        final midi = low + o * 12 + pc;
        final r = Rect.fromLTWH((o * 7 + left) * white, 0, white * 0.62, size.height * 0.62);
        canvas.drawRRect(RRect.fromRectAndCorners(r, bottomLeft: const Radius.circular(2), bottomRight: const Radius.circular(2)),
            Paint()..color = midi == selected ? tint : Color.alphaBlend(ink.withValues(alpha: 0.85), paper));
      }
    }
  }

  @override
  bool shouldRepaint(_KeyboardPainter old) =>
      old.selected != selected || old.line != line || old.tint != tint || old.paper != paper || old.ink != ink;
}
