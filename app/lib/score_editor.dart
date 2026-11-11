import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'dialog_kit.dart';
import 'l10n/l10n.dart';
import 'ui_kit.dart';

/// Project Settings ▸ Project Info ▸ Score ▸ Edit…: the score's MusicXML in an editor of its own,
/// over the window, laid out as Dorico's Write mode in galley view: the notes panel at the left,
/// the score as one endless system in the middle (Verovio engraves it, a few bars at a time), the
/// notations at the right, and Dorico's keys. Returns the score as edited (null: nothing changed,
/// or the changes were discarded).
Future<String?> showScoreEditor(BuildContext context, EditableScore score, {required String name}) =>
    Navigator.of(context, rootNavigator: true).push<String>(PageRouteBuilder(
      opaque: true,
      transitionDuration: motion(context, 200),
      reverseTransitionDuration: motion(context, 160),
      pageBuilder: (_, _, _) => ScoreEditor(score: score, name: name),
      transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic), child: child),
    ));

/// What a popover asks for (Dorico's, each on ⇧ and a letter but the tuplet's).
enum _Popover {
  dynamics('Dynamics', 'D', 'p  mf  sfz  <  >'),
  tempo('Tempo', 'T', 'Allegro q=120'),
  time('Time Signature', 'M', '3/4  6/8  C'),
  key('Key Signature', 'K', 'G  Eb  f#'),
  clef('Clef', 'C', 'treble  bass  alto'),
  text('Text', 'X', ''),
  bars('Bars and Barlines', 'B', '+2  -1  ||  |]  :|  |:'),
  holds('Holds', 'H', 'fermata  breath  caesura'),
  ornaments('Ornaments', 'O', 'tr  mordent  turn'),
  lyrics('Lyrics', 'L', ''),
  tuplet('Tuplet', ';', '3  5:4'),
  goTo('Go to Bar', 'G', '12');

  const _Popover(this.title, this.letter, this.hint);
  final String title, letter, hint;

  /// Its keys, as the notations panel says them.
  String get keys => switch (this) {
        tuplet => ';',
        goTo => shortcut('⌘G'),
        _ => '⇧$letter',
      };
}

class ScoreEditor extends StatefulWidget {
  const ScoreEditor({super.key, required this.score, required this.name});
  final EditableScore score;
  final String name;

  @override
  State<ScoreEditor> createState() => _ScoreEditorState();
}

class _ScoreEditorState extends State<ScoreEditor> {
  EditableScore get score => widget.score;

  final _focus = FocusNode(debugLabel: 'Score editor');

  // The engraving: a chunk of bars each, engraved again when its bars change.
  List<EditChunk?> _chunks = [];
  EditGalley _galley = EditGalley(const []);
  final _wanted = <int, int>{};
  final _queue = <int>{};
  int _running = 0;
  String? _engraveError;

  // What is selected, and where notes go in (note input is on while there is a caret).
  Set<String> _selected = {};
  ScorePosition? _caret;
  ScorePosition? _anchor;
  ScorePosition? _chordAt;
  NoteType _value = NoteType.quarter;
  int _dots = 0;
  Tuplet? _tuplet;
  int? _alter;
  bool _chordMode = false;

  /// Notes copied, kept while the app runs (across scores).
  static CopiedMusic? _clipboard;

  // The view: points a staff space, and how far it is scrolled (points).
  // Scrolling draws the score again and builds nothing: only the painter listens.
  static const _defaultZoom = 9.0;
  final _zoomed = ValueNotifier(_defaultZoom);
  double get _zoom => _zoomed.value;
  double _zoomAtPinch = _defaultZoom;
  final _scrolled = ValueNotifier(Offset.zero);
  Offset get _scroll => _scrolled.value;
  Size _viewport = Size.zero;
  static const _gutter = 132.0;

  /// The strip along the top that numbers the bars: the score is under it.
  static const _ruler = 20.0;
  final _numbers = <String, TextPainter>{};

  // A rectangle being dragged out (galley units): where it began, what was selected then.
  Offset? _dragFrom;
  Set<String> _dragOver = const {};
  final _marquee = ValueNotifier<Rect?>(null);

  _Popover? _popover;
  final _popoverText = TextEditingController();
  final _popoverFocus = FocusNode(debugLabel: 'Popover');
  bool _popoverError = false;
  bool _edited = false;

  @override
  void initState() {
    super.initState();
    _refresh(all: true);
  }

  @override
  void dispose() {
    for (final c in _chunks) {
      c?.dispose();
    }
    _chunks = [];
    _focus.dispose();
    _scrolled.dispose();
    _zoomed.dispose();
    _marquee.dispose();
    for (final number in _numbers.values) {
      number.dispose();
    }
    _popoverText.dispose();
    _popoverFocus.dispose();
    super.dispose();
  }

  // MARK: Engraving

  /// How many bars a chunk holds: fewer the more staves the score has.
  late final int _bars = EditChunk.barsFor(score.parts.fold(0, (a, p) => a + p.staves));

  /// How many chunks are engraved at a time.
  static final _engravers = (Platform.numberOfProcessors - 2).clamp(2, 6);

  int get _chunkCount => (score.measureCount + _bars - 1) ~/ _bars;

  /// The chunks whose bars changed engraved again (all of them, with [all]): a bar's own, and
  /// those engraved with it (the chunk after its last bar, the ones before whose slurs run into it).
  void _refresh({bool all = false}) {
    final changed = score.takeChanged();
    final count = _chunkCount;
    // The bars chunk k was engraved with after its own (one, until it is known).
    int trail(int k) => (k < _chunks.length ? _chunks[k]?.trail : null) ?? 1;
    final dirty = <int>{
      if (all) for (var k = 0; k < count; k++) k,
      for (final m in changed.bars) ...[
        m ~/ _bars,
        if (m % _bars == _bars - 1) m ~/ _bars + 1,
        for (var k = m ~/ _bars - 1; k >= 0 && (k + 1) * _bars + EditableScore.reach > m; k--)
          if ((k + 1) * _bars + trail(k) > m) k,
      ],
      if (changed.from case final from?)
        for (var k = 0; k < count; k++)
          if ((k + 1) * _bars + trail(k) > from) k,
    };
    if (_chunks.length > count) {
      _retire(_chunks.sublist(count));
      _chunks = _chunks.sublist(0, count);
    } else if (_chunks.length < count) {
      _chunks = [..._chunks, for (var k = _chunks.length; k < count; k++) null];
    }
    for (final k in dirty) {
      if (k >= count) continue;
      _wanted[k] = (_wanted[k] ?? 0) + 1;
      _queue.add(k);
    }
    _galley = _galleyOf(_chunks);
    _pump();
  }

  EditGalley _galleyOf(List<EditChunk?> chunks) {
    final space = chunks.firstWhere((c) => c != null, orElse: () => null)?.data.staffSpace ?? 0;
    return EditGalley(chunks, margin: space * 3, bars: _bars);
  }

  /// Engraves the chunks waiting, a few at a time, the ones nearest the view first.
  void _pump() {
    while (_running < _engravers && _queue.isNotEmpty) {
      final near = _visibleChunk();
      final k = _queue.reduce((a, b) => (a - near).abs() <= (b - near).abs() ? a : b);
      _queue.remove(k);
      final version = _wanted[k];
      final from = k * _bars, to = math.min(score.measureCount, from + _bars);
      _running++;
      EditChunk.engrave(score, from, to).then((chunk) {
        _running--;
        if (!mounted || _wanted[k] != version || k >= _chunks.length) {
          chunk.dispose();
        } else {
          final old = _chunks[k];
          setState(() {
            _chunks = [..._chunks]..[k] = chunk;
            _galley = _galleyOf(_chunks);
            _engraveError = null;
          });
          _retire([old]);
        }
        if (mounted) _pump();
      }, onError: (Object e) {
        _running--;
        if (!mounted) return;
        setState(() => _engraveError = '$e');
        _pump();
      });
    }
    if (mounted) setState(() {});
  }

  /// Chunks no longer drawn, let go once the frame without them is drawn.
  void _retire(Iterable<EditChunk?> chunks) {
    final gone = chunks.nonNulls.toList();
    if (gone.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final c in gone) {
        c.dispose();
      }
    });
  }

  int _visibleChunk() {
    final x = _scroll.dx / _scale;
    for (var k = _chunks.length - 1; k >= 0; k--) {
      if (k < _chunks.length && x >= _galley.chunkLeft(k)) return k;
    }
    return 0;
  }

  // MARK: Geometry

  /// Points a galley unit.
  double get _scale => _zoom / _galley.staffSpace;

  Offset _toGalley(Offset local) => Offset((local.dx - _gutter + _scroll.dx) / _scale, (local.dy - _ruler + _scroll.dy) / _scale);

  /// Verovio's staff number for [staff] of [part].
  int _staffNumber(int part, int staff) {
    var n = 0;
    for (var i = 0; i < part; i++) {
      n += score.parts[i].staves;
    }
    return n + staff;
  }

  ({int part, int staff}) _partStaffOf(int n) {
    var left = n;
    for (final (i, p) in score.parts.indexed) {
      if (left <= p.staves) return (part: i, staff: left);
      left -= p.staves;
    }
    return (part: score.parts.length - 1, staff: score.parts.last.staves);
  }

  void _setScroll(Offset to) {
    final maxX = math.max(0.0, _galley.width * _scale - (_viewport.width - _gutter));
    final maxY = math.max(0.0, _galley.height * _scale - (_viewport.height - _ruler));
    final clamped = Offset(to.dx.clamp(0, maxX), to.dy.clamp(0, maxY));
    if (clamped == _scroll) return;
    _scrolled.value = clamped;
    if (_popover != null) setState(() {}); // it is by what it is about, which moved
  }

  /// Scrolls so [rect] (galley units) is in view.
  void _reveal(Rect? rect) {
    if (rect == null || _viewport.isEmpty) return;
    final r = Rect.fromLTRB(rect.left * _scale, rect.top * _scale, rect.right * _scale, rect.bottom * _scale);
    final width = _viewport.width - _gutter, height = _viewport.height - _ruler, pad = 6 * _zoom;
    var dx = _scroll.dx, dy = _scroll.dy;
    if (r.left - pad < dx) dx = r.left - pad;
    if (r.right + pad > dx + width) dx = r.right + pad - width;
    if (r.top - pad < dy) dy = r.top - pad;
    if (r.bottom + pad > dy + height) dy = math.min(r.top - pad, r.bottom + pad - height);
    _setScroll(Offset(dx, dy));
  }

  /// Where the caret at [at] is drawn across the score: after the last bar when it is past it
  /// (the last bar is full; a note typed adds a bar).
  double? _caretX(ScorePosition at) =>
      _galley.xOf(at.measure, at.time) ?? (at.measure >= score.measureCount ? _galley.barOf(score.measureCount - 1)?.right : null);

  Rect? _caretRect(ScorePosition at) {
    final x = _caretX(at);
    final n = _staffNumber(at.part, at.staff);
    final top = _galley.staffTop(n);
    if (x == null || top == null) return null;
    final space = _galley.staffSpace;
    return Rect.fromLTRB(x - space, top - space * 2, x + space * 3, top + _galley.staffHeight(n) + space * 2);
  }

  Rect? _selectionRect() {
    Rect? out;
    for (final id in _selected) {
      final r = _galley.boundsOf(id);
      if (r != null) out = out?.expandToInclude(r) ?? r;
    }
    return out;
  }

  // MARK: Editing

  /// Runs [change] on the score, then engraves what it changed.
  void _edit(void Function() change) {
    try {
      change();
    } on Object catch (e) {
      setState(() => _engraveError = '$e');
    }
    _edited = _edited || score.canUndo;
    _selected = {
      for (final id in _selected)
        if (score.has(id)) id,
    };
    setState(_refresh);
  }

  Rhythm get _rhythm => Rhythm(_value, dots: _dots, tuplet: _tuplet);

  /// The notes and rests among what is selected (found once for a selection: every note of a
  /// symphony may be).
  List<String> get _selectedNotes {
    if (!identical(_notesOf, _selected)) {
      _notesOf = _selected;
      _notes = [
        for (final id in _selected)
          if (score.isNote(id)) id,
      ];
    }
    return _notes;
  }

  Set<String>? _notesOf;
  List<String> _notes = const [];

  /// Where an edit with no note to work on goes: the caret, the first note selected, or where
  /// the score was last clicked.
  ScorePosition? get _target {
    if (_caret != null) return _caret;
    final events = score.eventsOf(_selectedNotes);
    if (events.isNotEmpty) return events.first.position;
    for (final id in _selected) {
      if (score.whereIs(id) case (:final part, :final measure)) {
        return ScorePosition(part, score.defaultVoice(part, 1, measure), measure, Frac.zero);
      }
    }
    return _anchor;
  }

  void _startInput([ScorePosition? at]) {
    final start = at ?? _target ?? ScorePosition(0, score.defaultVoice(0, 1, 0), 0, Frac.zero);
    setState(() {
      _caret = start;
      _chordAt = null;
      _tuplet = null;
    });
    _reveal(_caretRect(start));
  }

  void _stopInput() => setState(() {
        _caret = null;
        _chordAt = null;
        _tuplet = null;
        _alter = null;
      });

  /// The note value keys (Dorico's 1–9): the caret's next note, or the selected notes'.
  void _setValue(NoteType value) {
    if (_caret == null && _selectedNotes.isNotEmpty) {
      _edit(() => score.setRhythm(_selectedNotes, value));
      setState(() => _value = value);
      return;
    }
    setState(() {
      _value = value;
      _dots = 0;
      if (_tuplet != null) _tuplet = Tuplet(_tuplet!.actual, _tuplet!.normal, value);
    });
  }

  void _toggleDot() {
    if (_caret == null && _selectedNotes.isNotEmpty) return _edit(() => score.toggleDot(_selectedNotes));
    setState(() => _dots = _dots == 0 ? 1 : 0);
  }

  void _setAlter(int alter) {
    if (_caret == null && _selectedNotes.isNotEmpty) return _edit(() => score.setAlter(_selectedNotes, alter));
    setState(() => _alter = _alter == alter ? null : alter);
  }

  /// A letter (A–G as a step 0–6): a note at the caret, at the octave nearest the one before;
  /// added to the chord with [chord] (or in chord mode); outside note input, the selected
  /// notes' pitch.
  void _letter(int step, {bool chord = false}) {
    final caret = _caret;
    if (caret == null) {
      final notes = _selectedNotes;
      if (notes.isEmpty) return;
      if (chord) return _addAbove(score.eventsOf(notes), step);
      _edit(() {
        for (final e in score.eventsOf(notes)) {
          final fifths = score.keyAt(e.position.part, e.position.measure, e.position.time).fifths;
          final near = e.isRest ? score.pitchBefore(e.position) : e.pitches.first;
          final pitch = Pitch.nearest(step, near, alter: Pitch.keyAlter(step, fifths));
          score.input(e.position, [InputItem(e.rhythm ?? Rhythm.express(e.length).first, [pitch])]);
        }
      });
      return;
    }
    if (chord || (_chordMode && _chordAt == caret)) {
      final last = _chordMode ? score.eventAt(caret.part, caret.staff, caret.measure, caret.time, voice: caret.voice.voice) : score.eventBefore(caret);
      if (last != null && !last.isRest) return _addAbove([last], step);
    }
    final fifths = score.keyAt(caret.part, caret.measure, caret.time).fifths;
    final pitch = Pitch.nearest(step, score.pitchBefore(caret), alter: _alter ?? Pitch.keyAlter(step, fifths));
    _put([InputItem(_rhythm, [pitch])]);
  }

  /// [step] added above each of [events]' top notes.
  void _addAbove(List<EventInfo> events, int step) {
    _edit(() {
      for (final e in events) {
        if (e.isRest) continue;
        final top = e.pitches.reduce((a, b) => a.diatonic >= b.diatonic ? a : b);
        final fifths = score.keyAt(e.position.part, e.position.measure, e.position.time).fifths;
        var pitch = Pitch.nearest(step, top, alter: _alter ?? Pitch.keyAlter(step, fifths));
        if (pitch.diatonic <= top.diatonic) pitch = Pitch(pitch.step, pitch.octave + 1, pitch.alter);
        score.addToChord(e.position, pitch);
      }
    });
    _alter = null;
  }

  /// [items] put in at the caret, which moves on past them (in chord mode it stays).
  void _put(List<InputItem> items) {
    final caret = _caret!;
    ScorePosition? after;
    _edit(() => after = score.input(caret, items));
    if (after == null) return;
    final entered = score.eventBefore(after!);
    setState(() {
      _alter = null;
      if (_chordMode) {
        _chordAt = caret;
      } else {
        _caret = after;
      }
      _selected = {...?entered?.ids};
    });
    _reveal(_caretRect(_caret!));
  }

  void _rest() {
    if (_caret == null) return;
    _put([InputItem(_rhythm, const [])]);
  }

  /// T: in note input, a note tied on from the one before at the same pitch; else the selected
  /// notes tied to the next.
  void _tie() {
    final caret = _caret;
    if (caret == null) return _edit(() => score.toggleTie(_selectedNotes));
    final last = score.eventBefore(caret);
    if (last == null || last.isRest) return;
    _put([InputItem(_rhythm, last.pitches, tieFrom: true)]);
  }

  /// The caret moved by [by] (bars crossed as needed).
  void _moveCaret(Frac by) {
    final caret = _caret;
    if (caret == null) return;
    var m = caret.measure;
    var t = caret.time + by;
    while (t.isPositive && m < score.measureCount && t >= score.barLength(m)) {
      if (m == score.measureCount - 1) {
        t = score.barLength(m);
        break;
      }
      t = t - score.barLength(m);
      m++;
    }
    while (t < Frac.zero && m > 0) {
      m--;
      t = t + score.barLength(m);
    }
    if (t < Frac.zero) t = Frac.zero;
    final to = caret.at(m, t);
    setState(() {
      _caret = to;
      _chordAt = null;
    });
    _reveal(_caretRect(to));
  }

  void _caretToBar(int delta) {
    final caret = _caret;
    if (caret == null) return;
    final m = (caret.measure + (delta < 0 && caret.time.isPositive ? 0 : delta)).clamp(0, score.measureCount - 1);
    setState(() => _caret = caret.at(m, Frac.zero));
    _reveal(_caretRect(_caret!));
  }

  /// The caret to the staff above or below, at the same time.
  void _caretToStaff(int delta) {
    final caret = _caret;
    if (caret == null) return;
    final count = score.parts.fold(0, (a, p) => a + p.staves);
    final n = (_staffNumber(caret.part, caret.staff) + delta).clamp(1, count);
    final (:part, :staff) = _partStaffOf(n);
    final to = ScorePosition(part, score.defaultVoice(part, staff, caret.measure), caret.measure, caret.time);
    setState(() => _caret = to);
    _reveal(_caretRect(to));
  }

  /// V: the caret to the next voice of its staff (a new one after the last).
  void _nextVoice() {
    final caret = _caret;
    if (caret == null) return;
    final voices = {
      for (var m = math.max(0, caret.measure - 2); m < math.min(score.measureCount, caret.measure + 3); m++)
        for (final v in score.voicesIn(caret.part, m))
          if (v.staff == caret.staff) v,
    }.toList()
      ..sort();
    final i = voices.indexOf(caret.voice);
    final VoiceKey next;
    if (i >= 0 && i < voices.length - 1) {
      next = voices[i + 1];
    } else if (voices.length >= 4 || (i == voices.length - 1 && voices.length > 1 && !_hasNotes(voices.last, caret))) {
      next = voices.first;
    } else {
      final numbers = voices.map((v) => int.tryParse(v.voice) ?? 0);
      next = VoiceKey(caret.staff, '${(numbers.isEmpty ? (caret.staff - 1) * 4 : numbers.reduce(math.max)) + 1}');
    }
    setState(() => _caret = caret.inVoice(next));
  }

  bool _hasNotes(VoiceKey voice, ScorePosition near) => score.eventsIn(near.part, near.measure, voice).any((e) => !e.isRest);

  void _backspace() {
    final caret = _caret;
    if (caret == null) return _delete();
    final last = score.eventBefore(caret);
    if (last == null) return;
    _edit(() => score.delete(last.ids));
    setState(() {
      _caret = last.position.inVoice(caret.voice);
      _selected = {};
    });
  }

  void _delete() {
    if (_selected.isEmpty) return;
    _edit(() => score.delete(_selected));
  }

  // MARK: Selecting

  void _select(Iterable<String> ids, {bool add = false}) {
    setState(() {
      _selected = add ? {..._selected, ...ids} : {...ids};
      if (ids.isNotEmpty) {
        final e = score.locate(ids.first);
        if (e != null) _anchor = e.position;
      }
    });
    _reveal(_selectionRect());
  }

  /// Bar [m] brought to the view's left: the caret there in note input, else its first note on
  /// the staff last worked on selected.
  void _goToBar(int m) {
    final from = _target;
    final part = from?.part ?? 0, staff = from?.staff ?? 1;
    final at = ScorePosition(part, score.defaultVoice(part, staff, m), m, Frac.zero);
    setState(() {
      _anchor = at;
      if (_caret != null) {
        _caret = at;
        _chordAt = null;
      } else {
        _selected = {...?score.eventAt(part, staff, m, Frac.zero)?.ids};
      }
    });
    _showBar(m);
  }

  /// Scrolls across so bar [m] starts at the view's left (a little in).
  void _showBar(int m) {
    final bar = _galley.barOf(m);
    // One not engraved yet: where its chunk is guessed to be.
    final left = bar?.left ?? _galley.chunkLeft((m ~/ _bars).clamp(0, _chunks.length - 1));
    // (The first bar, from the clefs before it.)
    _setScroll(Offset(m == 0 ? 0 : left * _scale - 24, _scroll.dy));
  }

  /// ←/→ outside note input: the note before or after the selection in its voice (⇧ adds it).
  void _step(int delta, {bool extend = false, bool bar = false}) {
    final events = score.eventsOf(_selectedNotes);
    if (events.isEmpty) {
      final at = _anchor;
      if (at == null) return;
      final first = score.eventAt(at.part, at.staff, at.measure, at.time) ??
          score.eventsIn(at.part, at.measure, score.defaultVoice(at.part, at.staff, at.measure)).firstOrNull;
      if (first != null) _select(first.ids);
      return;
    }
    var e = delta > 0 ? events.last : events.first;
    if (bar) {
      final m = (e.position.measure + delta).clamp(0, score.measureCount - 1);
      final first = score.eventsIn(e.position.part, m, e.position.voice).firstOrNull;
      if (first != null) _select(first.ids, add: extend);
      return;
    }
    final next = delta > 0 ? score.next(e) : score.previous(e);
    if (next != null) _select(next.ids, add: extend);
  }

  /// ↑/↓ outside note input: what sounds at the same time on the staff above or below.
  void _stepStaff(int delta) {
    final events = score.eventsOf(_selectedNotes);
    if (events.isEmpty) return;
    final p = events.first.position;
    final count = score.parts.fold(0, (a, x) => a + x.staves);
    final n = _staffNumber(p.part, p.staff) + delta;
    if (n < 1 || n > count) return;
    final (:part, :staff) = _partStaffOf(n);
    final e = score.eventAt(part, staff, p.measure, p.time);
    if (e != null) _select(e.ids);
  }

  /// ⌘A: everything in the score.
  void _selectAll() => setState(() => _selected = {...score.ids});

  /// A drag from where nothing is: what the rectangle dragged out touches is selected (added
  /// to what was, with ⇧ or ⌘).
  void _dragTo(Offset local) {
    final from = _dragFrom;
    if (from == null) return;
    final to = _toGalley(local);
    if (_marquee.value == null && (to - from).distance * _scale < 4) return;
    final area = Rect.fromPoints(from, to);
    _marquee.value = area;
    final ids = {..._dragOver, ..._galley.idsIn(area)};
    if (ids.length != _selected.length || !ids.containsAll(_selected)) setState(() => _selected = ids);
  }

  void _dragDone() {
    _dragFrom = null;
    _marquee.value = null;
  }

  /// A click on a bar's number: what the bar holds, in every instrument (added, with ⇧ or ⌘).
  void _clickBar(Offset local, {required bool add}) {
    _focus.requestFocus();
    if (_popover != null) _closePopover();
    _dragFrom = null;
    final at = local.dx < _gutter ? null : _galley.timeAtX(_toGalley(local).dx);
    if (at == null) return;
    setState(() {
      _selected = {if (add) ..._selected, ...score.idsIn(at.measure)};
      _anchor = ScorePosition(0, score.defaultVoice(0, 1, at.measure), at.measure, Frac.zero);
    });
  }

  void _click(Offset local, {required bool shift, required bool toggle}) {
    _focus.requestFocus();
    if (_popover != null) _closePopover();
    final p = _toGalley(local);
    final id = _galley.hitTest(p);
    _dragFrom = id == null ? p : null;
    _dragOver = toggle || shift ? _selected : const {};
    if (id != null) {
      final e = score.locate(id);
      final ids = [id]; // a chord's note on its own, as Dorico selects
      if (toggle && _selected.contains(id)) {
        setState(() => _selected = {..._selected}..remove(id));
      } else if (shift && e != null && _selectedNotes.isNotEmpty) {
        // A range in the voice of the first selected.
        final first = score.eventsOf(_selectedNotes).first;
        var x = first;
        final range = <String>{...x.ids};
        while (x.position.part == e.position.part && x.ids.first != e.ids.first) {
          final n = score.next(x);
          if (n == null) break;
          x = n;
          range.addAll(x.ids);
          if (range.length > 2000) break;
        }
        setState(() => _selected = range);
      } else {
        setState(() => _selected = toggle ? {..._selected, ...ids} : {...ids});
      }
      if (e != null) {
        _anchor = e.position;
        if (_caret != null) setState(() => _caret = e.position);
      }
      return;
    }
    final at = _galley.timeAtX(p.dx);
    if (at == null) return;
    final (:part, :staff) = _partStaffOf(_galley.staffAtY(p.dy));
    final position = ScorePosition(part, score.defaultVoice(part, staff, at.measure), at.measure, score.onsetAt(at.measure, at.time));
    setState(() {
      _anchor = position;
      if (!toggle && !shift) _selected = {};
      if (_caret != null) {
        _caret = position;
        _chordAt = null;
      }
    });
  }

  // MARK: Copy and paste

  void _copy({bool cut = false}) {
    final notes = _selectedNotes;
    if (notes.isEmpty) return;
    _clipboard = score.copy(notes);
    if (cut) _edit(() => score.delete(notes));
  }

  void _paste() {
    final music = _clipboard;
    final at = _target;
    if (music == null || music.isEmpty || at == null) return;
    ScorePosition? end;
    _edit(() => end = score.paste(at, music));
    if (_caret != null && end != null) setState(() => _caret = end);
  }

  /// R: the selection again, right after it.
  void _repeat() {
    final events = score.eventsOf(_selectedNotes);
    if (events.isEmpty) return;
    final music = score.copy(_selectedNotes);
    final last = events.where((e) => e.position.part == events.first.position.part && e.position.voice == events.first.position.voice).last;
    var m = last.position.measure;
    var t = last.end;
    if (t >= score.barLength(m)) {
      m++;
      t = Frac.zero;
    }
    ScorePosition? end;
    final from = last.position.at(m, t);
    _edit(() => end = score.paste(from, music));
    if (end == null) return;
    // The copy selected, as Dorico does.
    final ids = <String>{};
    var e = score.eventAt(from.part, from.staff, from.measure, from.time, voice: from.voice.voice);
    while (e != null && (e.position.measure < end!.measure || (e.position.measure == end!.measure && e.position.time < end!.time))) {
      ids.addAll(e.ids);
      e = score.next(e);
    }
    _select(ids);
  }

  // MARK: Popovers

  void _openPopover(_Popover kind) {
    if (_target == null && kind != _Popover.bars && kind != _Popover.goTo) return;
    if (kind == _Popover.lyrics && _selectedNotes.isEmpty) return;
    if (kind == _Popover.tuplet && _caret == null) return;
    _popoverText.text = kind == _Popover.lyrics ? score.lyricOf(_selectedNotes.first) : '';
    _popoverText.selection = TextSelection(baseOffset: 0, extentOffset: _popoverText.text.length);
    setState(() {
      _popover = kind;
      _popoverError = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _popoverFocus.requestFocus());
  }

  void _closePopover() {
    setState(() => _popover = null);
    _focus.requestFocus();
  }

  /// What was typed in the popover applied; false if it says nothing the popover knows.
  bool _applyPopover(String text, {bool next = false}) {
    final kind = _popover;
    final at = _target ?? _anchor ?? ScorePosition(0, score.defaultVoice(0, 1, 0), 0, Frac.zero);
    final t = text.trim();
    if (t.isEmpty && kind != _Popover.lyrics) return true;
    switch (kind) {
      case null:
        return true;
      case _Popover.dynamics:
        final words = t.split(RegExp(r'\s+'));
        final hairpin = words.where((w) => w == '<' || w == '>').firstOrNull;
        final marks = words.where((w) => EditableScore.dynamics.contains(w)).toList();
        final rest = words.where((w) => w != '<' && w != '>' && !EditableScore.dynamics.contains(w)).join(' ');
        if (hairpin == null && marks.isEmpty && rest.isEmpty) return false;
        _edit(() {
          for (final mark in marks.take(1)) {
            score.addDynamic(at, mark);
          }
          if (rest.isNotEmpty) score.addText(at, rest, below: true, italic: true);
          if (hairpin != null) {
            final events = score.eventsOf(_selectedNotes);
            final from = events.isEmpty ? at : events.first.position;
            final last = events.isEmpty ? null : events.where((e) => e.position.part == from.part).last;
            var end = last == null ? from.at(from.measure, from.time + (_caret != null ? _rhythm.length : Frac.one)) : last.position.at(last.position.measure, last.end);
            if (end.time > score.barLength(end.measure)) end = end.at(end.measure, score.barLength(end.measure));
            score.addHairpin(from, end, crescendo: hairpin == '<');
          }
        });
      case _Popover.tempo:
        final metronome = RegExp(r'(?:([whqes])(\.)?\s*=\s*)?(\d+(?:\.\d+)?)\s*$').firstMatch(t);
        final words = (metronome == null ? t : t.substring(0, metronome.start)).trim();
        final unit = switch (metronome?.group(1)) {
          'w' => NoteType.whole,
          'h' => NoteType.half,
          'e' => NoteType.eighth,
          's' => NoteType.sixteenth,
          _ => NoteType.quarter,
        };
        final bpm = metronome == null ? null : double.tryParse(metronome.group(3)!);
        if (words.isEmpty && bpm == null) return false;
        _edit(() => score.addTempo(at, words: words, unit: unit, dotted: metronome?.group(2) != null, perMinute: bpm));
      case _Popover.time:
        final meter = TimeSig.parse(t);
        if (meter == null) return false;
        _edit(() => score.setTime(at.measure, meter));
      case _Popover.key:
        final key = KeySig.parse(t);
        if (key == null) return false;
        _edit(() => score.setKey(at.measure, key));
      case _Popover.clef:
        final clef = Clef.named(t);
        if (clef == null) return false;
        _edit(() => score.setClef(at, clef));
      case _Popover.text:
        _edit(() => score.addText(at, t));
      case _Popover.bars:
        final count = RegExp(r'^([+-])\s*(\d+)$').firstMatch(t);
        if (count != null) {
          final n = int.tryParse(count.group(2)!);
          if (n == null || n < 1 || n > 999) return false;
          if (count.group(1) == '+') {
            _edit(() => score.addBars(_target == null ? score.measureCount : at.measure + 1, n));
          } else {
            if (n >= score.measureCount) return false;
            _edit(() => score.deleteBars(at.measure, n));
            setState(() {
              _caret = null;
              _selected = {};
            });
          }
        } else {
          var ok = false;
          _edit(() => ok = score.setBarline(at.measure, t));
          if (!ok) return false;
        }
      case _Popover.holds:
        final name = switch (t.toLowerCase()) {
          'fermata' || 'pause' || 'u' => 'fermata',
          'breath' || ',' || 'breath mark' => 'breath-mark',
          'caesura' || '//' => 'caesura',
          _ => null,
        };
        if (name == null || _selectedNotes.isEmpty) return false;
        _edit(() => score.toggleMark(_selectedNotes, name));
      case _Popover.ornaments:
        final name = switch (t.toLowerCase()) {
          'tr' || 'trill' => 'trill-mark',
          'mordent' || 'mord' => 'mordent',
          'inverted mordent' || 'prall' || 'pralltriller' => 'inverted-mordent',
          'turn' => 'turn',
          _ => null,
        };
        if (name == null || _selectedNotes.isEmpty) return false;
        _edit(() => score.toggleMark(_selectedNotes, name));
      case _Popover.lyrics:
        final id = _selectedNotes.firstOrNull;
        if (id == null) return true;
        _edit(() => score.setLyric(id, t));
        if (next) {
          // On to the next note (rests skipped), the popover kept open.
          var e = score.locate(id);
          do {
            e = e == null ? null : score.next(e);
          } while (e != null && e.isRest);
          if (e != null) {
            _select(e.ids);
            _popoverText.text = score.lyricOf(e.ids.first);
            _popoverText.selection = TextSelection.collapsed(offset: _popoverText.text.length);
            return true;
          }
        }
      case _Popover.tuplet:
        final tuplet = Tuplet.parse(t, _value);
        if (tuplet == null) return false;
        setState(() => _tuplet = tuplet);
      case _Popover.goTo:
        // The bar numbered so, as the score numbers them; else the bar that many from the first.
        var m = [for (var i = 0; i < score.measureCount; i++) score.barNumber(i)].indexOf(t);
        if (m < 0) {
          final n = int.tryParse(t);
          if (n == null || n < 1 || n > score.measureCount) return false;
          m = n - 1;
        }
        _closePopover();
        _goToBar(m);
        return true;
    }
    if (!next) _closePopover();
    return true;
  }

  // MARK: Keys

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    // A popover's field keeps what is typed in it: this is asked before the field is, and a key
    // taken here never reaches it (an F typed for forte would be the note's new pitch).
    if (FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    final shift = keys.isShiftPressed, alt = keys.isAltPressed, command = keys.isMetaPressed || keys.isControlPressed;
    final key = event.logicalKey;
    final char = event.character?.toLowerCase();
    final input = _caret != null;

    VoidCallback? action;
    if (command) {
      action = switch (key) {
        LogicalKeyboardKey.keyZ when shift => _redo,
        LogicalKeyboardKey.keyZ => _undo,
        LogicalKeyboardKey.keyY => _redo,
        LogicalKeyboardKey.keyC => _copy,
        LogicalKeyboardKey.keyX => () => _copy(cut: true),
        LogicalKeyboardKey.keyV => _paste,
        LogicalKeyboardKey.keyA => _selectAll,
        LogicalKeyboardKey.keyG => () => _openPopover(_Popover.goTo),
        LogicalKeyboardKey.home => () => _goToBar(0),
        LogicalKeyboardKey.end => () => _goToBar(score.measureCount - 1),
        LogicalKeyboardKey.equal || LogicalKeyboardKey.add || LogicalKeyboardKey.numpadAdd => () => _zoomBy(1.2),
        LogicalKeyboardKey.minus || LogicalKeyboardKey.numpadSubtract => () => _zoomBy(1 / 1.2),
        LogicalKeyboardKey.digit0 || LogicalKeyboardKey.numpad0 => () => _zoomTo(_defaultZoom),
        LogicalKeyboardKey.arrowUp when alt => () => _edit(() => score.transpose(_selectedNotes, octaves: 1)),
        LogicalKeyboardKey.arrowDown when alt => () => _edit(() => score.transpose(_selectedNotes, octaves: -1)),
        LogicalKeyboardKey.arrowLeft => () => input ? _caretToBar(-1) : _step(-1, bar: true, extend: shift),
        LogicalKeyboardKey.arrowRight => () => input ? _caretToBar(1) : _step(1, bar: true, extend: shift),
        LogicalKeyboardKey.enter => _done,
        _ => null,
      };
    } else if (alt && (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown)) {
      final steps = key == LogicalKeyboardKey.arrowUp ? 1 : -1;
      action = () {
        final ids = _selectedNotes;
        if (ids.isNotEmpty) _edit(() => score.transpose(ids, steps: steps));
      };
    } else if (alt && shift && char != null && 'abcdefg'.contains(char) && char.length == 1) {
      action = () => _letter('cdefgab'.indexOf(char), chord: true);
    } else {
      final letter = _letterOf(key);
      action = switch (key) {
        LogicalKeyboardKey.escape => () {
            if (input) {
              _stopInput();
            } else {
              setState(() => _selected = {});
            }
          },
        LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter => () => input ? _stopInput() : _startInput(),
        LogicalKeyboardKey.backspace => _backspace,
        LogicalKeyboardKey.delete => _delete,
        LogicalKeyboardKey.arrowLeft => () => input ? _moveCaret(-_rhythm.length) : _step(-1, extend: shift),
        LogicalKeyboardKey.arrowRight => () => input ? _moveCaret(_rhythm.length) : _step(1, extend: shift),
        LogicalKeyboardKey.arrowUp => () => input ? _caretToStaff(-1) : _stepStaff(-1),
        LogicalKeyboardKey.arrowDown => () => input ? _caretToStaff(1) : _stepStaff(1),
        LogicalKeyboardKey.space => () => input ? _moveCaret(_rhythm.length) : null,
        LogicalKeyboardKey.home => () => _showBar(0),
        LogicalKeyboardKey.end => () => _showBar(score.measureCount - 1),
        _ when shift && letter != null => switch (letter) {
            'n' => () => input ? _stopInput() : _startInput(),
            'd' => () => _openPopover(_Popover.dynamics),
            't' => () => _openPopover(_Popover.tempo),
            'm' => () => _openPopover(_Popover.time),
            'k' => () => _openPopover(_Popover.key),
            'c' => () => _openPopover(_Popover.clef),
            'x' => () => _openPopover(_Popover.text),
            'b' => () => _openPopover(_Popover.bars),
            'h' => () => _openPopover(_Popover.holds),
            'o' => () => _openPopover(_Popover.ornaments),
            'l' => () => _openPopover(_Popover.lyrics),
            _ => null,
          },
        _ when letter != null && 'abcdefg'.contains(letter) => () => _letter('cdefgab'.indexOf(letter)),
        _ when letter == 'q' => () => setState(() {
              _chordMode = !_chordMode;
              _chordAt = null;
            }),
        _ when letter == 't' => _tie,
        _ when letter == 's' => () => _edit(() => score.toggleSlur(_selectedNotes)),
        _ when letter == 'r' => _repeat,
        _ when letter == 'v' => _nextVoice,
        _ => switch (char) {
            final c? when c.length == 1 && '123456789'.contains(c) => () => _setValue(NoteType.ofDigit(int.parse(c))!),
            '.' => _toggleDot,
            '-' => () => _setAlter(-1),
            '=' => () => _setAlter(1),
            '0' => () => _setAlter(0),
            ',' => _rest,
            ';' => () => _openPopover(_Popover.tuplet),
            ':' => () => setState(() => _tuplet = null),
            '[' => () => _mark('accent'),
            ']' => () => _mark('staccato'),
            '{' => () => _mark('strong-accent', {'type': 'up'}),
            '}' => () => _mark('tenuto'),
            "'" => () => _mark('staccatissimo'),
            _ => null,
          },
      };
    }
    if (action == null) return KeyEventResult.ignored;
    action();
    return KeyEventResult.handled;
  }

  static String? _letterOf(LogicalKeyboardKey key) {
    final label = key.keyLabel;
    return label.length == 1 && RegExp('[A-Za-z]').hasMatch(label) ? label.toLowerCase() : null;
  }

  void _mark(String name, [Map<String, String> attributes = const {}]) {
    final ids = _selectedNotes;
    if (ids.isNotEmpty) _edit(() => score.toggleMark(ids, name, attributes: attributes));
  }

  void _undo() {
    if (!score.canUndo) return;
    _edit(score.undo);
  }

  void _redo() {
    if (!score.canRedo) return;
    _edit(score.redo);
  }

  /// Zooms by [factor], what is at [about] in the view (its middle, if not said) staying there.
  void _zoomBy(double factor, {Offset? about}) => _zoomTo(_zoom * factor, about: about);

  void _zoomTo(double zoom, {Offset? about}) {
    final to = zoom.clamp(3.0, 20.0);
    if (to == _zoom) return;
    final at = about ?? Offset(_gutter + (_viewport.width - _gutter) / 2, _ruler + (_viewport.height - _ruler) / 2);
    final held = _toGalley(at);
    _zoomed.value = to;
    _setScroll(Offset(held.dx * _scale - (at.dx - _gutter), held.dy * _scale - (at.dy - _ruler)));
    if (_popover != null) setState(() {});
  }

  // MARK: Leaving

  void _done() => Navigator.of(context).pop(_edited ? score.toMusicXML() : null);

  Future<void> _cancel() async {
    if (!_edited) return Navigator.of(context).pop();
    final discard = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: Text('Discard Your Changes?'.tr),
        content: Text('The score stays as it was.'.tr),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text('Keep Editing'.tr)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text('Discard'.tr)),
        ],
        confirmsOnReturn: false,
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
    if (mounted) _focus.requestFocus();
  }

  // MARK: Building

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) _cancel();
      },
      child: Material(
        color: colors.surface,
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _key,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _toolbar(context),
            Divider(height: 1, color: colors.line),
            Expanded(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _notesPanel(context),
                VerticalDivider(width: 1, color: colors.line),
                Expanded(child: _view(context)),
                VerticalDivider(width: 1, color: colors.line),
                _notationsPanel(context),
              ]),
            ),
            Divider(height: 1, color: colors.line),
            _statusBar(context),
          ]),
        ),
      ),
    );
  }

  Widget _toolbar(BuildContext context) {
    final colors = context.colors, style = AppStyle.of(context);
    return Container(
      height: style.toolbar + 8,
      color: colors.chrome,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        Text('Edit Score'.tr, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: colors.text)),
        const SizedBox(width: 10),
        Expanded(
          child: Row(children: [
            Flexible(child: Text(widget.name, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: colors.textMuted))),
            const SizedBox(width: 12),
            if (_running > 0 || _queue.isNotEmpty) PulsingDot(color: colors.accent, size: 8),
          ]),
        ),
        ToolbarButton(icon: AppIcon.undo.of(context), tooltip: 'Undo ({key})'.fill({'key': shortcut('⌘Z')}), onPressed: score.canUndo ? _undo : null),
        ToolbarButton(icon: AppIcon.redo.of(context), tooltip: 'Redo ({key})'.fill({'key': shortcut('⇧⌘Z', 'Ctrl+Y')}), onPressed: score.canRedo ? _redo : null),
        const ToolbarDivider(),
        ToolbarButton(icon: AppIcon.zoomOut.of(context), tooltip: 'Zoom Out'.tr, onPressed: () => _zoomBy(1 / 1.2)),
        ToolbarButton(icon: AppIcon.zoomIn.of(context), tooltip: 'Zoom In'.tr, onPressed: () => _zoomBy(1.2)),
        const ToolbarDivider(),
        OutlinedButton(onPressed: _cancel, child: Text('Cancel'.tr)),
        const SizedBox(width: 8),
        FilledButton(onPressed: _done, child: Text('Done'.tr)),
      ]),
    );
  }

  Widget _notesPanel(BuildContext context) {
    final colors = context.colors;
    final input = _caret != null;
    Widget glyph(String tip, List<(int, double)> codes, VoidCallback? onPressed, {bool selected = false}) =>
        ToolbarButton(glyph: _Glyph(codes), tooltip: tip, onPressed: onPressed, selected: selected);
    final values = [
      for (final v in NoteType.values.reversed)
        glyph('{value} ({key})'.fill({'value': _valueName(v), 'key': '${v.digit}'}), [(_noteGlyph(v), v.index >= NoteType.half.index ? 1.4 : 0)],
            () => _setValue(v), selected: _value == v),
    ];
    final tools = <Widget>[
      ToolbarButton(icon: AppIcon.draw.of(context), tooltip: 'Note Input (⇧N)'.tr, onPressed: () => input ? _stopInput() : _startInput(), selected: input),
      glyph('Chord (Q)'.tr, [(0xE0A4, -0.5), (0xE0A4, 0.5)], () => setState(() => _chordMode = !_chordMode), selected: _chordMode),
      ...values,
      glyph('Dot (.)'.tr, [(0xE1E7, 0)], _toggleDot, selected: _dots > 0),
      glyph('Rest (,)'.tr, [(0xE4E5, 0)], input ? _rest : null),
      glyph('Flat (-)'.tr, [(0xE260, 0)], () => _setAlter(-1), selected: _alter == -1),
      glyph('Natural (0)'.tr, [(0xE261, 0)], () => _setAlter(0), selected: _alter == 0),
      glyph('Sharp (=)'.tr, [(0xE262, 0)], () => _setAlter(1), selected: _alter == 1),
      glyph('Tie (T)'.tr, [(0xE1FD, 0)], _tie),
      ToolbarButton(glyph: const _Slur(), tooltip: 'Slur (S)'.tr, onPressed: () => _edit(() => score.toggleSlur(_selectedNotes))),
      glyph('Tuplet (;)'.tr, [(0xE883, 0)], () => _tuplet != null ? setState(() => _tuplet = null) : _openPopover(_Popover.tuplet), selected: _tuplet != null),
      glyph('Accent ([)'.tr, [(0xE4A0, 0)], () => _mark('accent')),
      glyph('Staccato (])'.tr, [(0xE4A2, 0)], () => _mark('staccato')),
      glyph('Tenuto (⇧])'.tr, [(0xE4A4, 0)], () => _mark('tenuto')),
      glyph('Marcato (⇧[)'.tr, [(0xE4AC, 0)], () => _mark('strong-accent', {'type': 'up'})),
      glyph('Staccatissimo (\')'.tr, [(0xE4A6, 0)], () => _mark('staccatissimo')),
    ];
    return Container(
      width: 76,
      color: colors.chrome,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        child: Wrap(spacing: 4, runSpacing: 4, alignment: WrapAlignment.center, children: tools),
      ),
    );
  }

  Widget _notationsPanel(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: 184,
      color: colors.chrome,
      child: ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
        for (final p in _Popover.values)
          _PanelRow(
            label: p.title.tr,
            shortcut: p.keys,
            selected: _popover == p,
            onPressed: () => _openPopover(p),
          ),
      ]),
    );
  }

  Widget _statusBar(BuildContext context) {
    final colors = context.colors, style = AppStyle.of(context);
    final muted = TextStyle(fontSize: 12, color: colors.textMuted);
    String where(ScorePosition p) => '${score.parts[p.part].name}${score.parts[p.part].staves > 1 ? ' ${p.staff}' : ''} · ${score.describe(p.measure, p.time)}';
    final String text;
    if (_engraveError case final error?) {
      text = 'Couldn’t engrave. {error}'.fill({'error': error});
    } else if (_caret case final caret?) {
      final value = '${_dots > 0 ? 'Dotted {value}'.fill({'value': _valueName(_value)}) : _valueName(_value)}${_tuplet != null ? ' · $_tuplet' : ''}';
      text = [
        'Note input'.tr,
        where(caret),
        'Voice {n}'.fill({'n': caret.voice.voice}),
        value,
        if (_alter != null) switch (_alter) { -1 => '♭', 1 => '♯', _ => '♮' },
        if (_chordMode) 'Chord'.tr,
      ].join(' · ');
    } else {
      final events = score.eventsOf(_selectedNotes);
      if (events.isNotEmpty) {
        final e = events.first;
        text = [
          where(e.position),
          if (e.isRest) 'Rest'.tr else e.pitches.map((p) => p.name).join(' '),
          if (e.rhythm case final r?) r.dots > 0 ? 'Dotted {value}'.fill({'value': _valueName(r.type)}) : _valueName(r.type),
          if (_selected.length > e.ids.length) '{count} selected'.fill({'count': _selected.length}),
        ].join(' · ');
      } else if (_selected.isNotEmpty) {
        text = '{count} selected'.fill({'count': _selected.length});
      } else {
        text = '';
      }
    }
    return Container(
      height: style.panelBar,
      color: colors.chrome,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.centerLeft,
      child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: muted.copyWith(color: _engraveError != null ? colors.erase : null)),
    );
  }

  Widget _view(BuildContext context) {
    final colors = context.colors;
    return LayoutBuilder(builder: (context, constraints) {
      final size = constraints.biggest;
      if (size != _viewport) {
        _viewport = size;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _setScroll(_scroll);
        });
      }
      final caret = _caret;
      final popover = _popover;
      Rect? anchorRect;
      if (popover != null) {
        final target = caret ?? _target;
        final r = (_selectedNotes.isNotEmpty ? _selectionRect() : null) ?? (target == null ? null : _caretRect(target));
        if (r != null) {
          anchorRect = Rect.fromLTRB(r.left * _scale - _scroll.dx + _gutter, r.top * _scale - _scroll.dy + _ruler,
              r.right * _scale - _scroll.dx + _gutter, r.bottom * _scale - _scroll.dy + _ruler);
        }
      }
      return ClipRect(
        child: Stack(children: [
          Positioned.fill(
            child: Listener(
              onPointerSignal: (event) {
                final keys = HardwareKeyboard.instance;
                if (event is PointerScaleEvent) {
                  _zoomBy(event.scale, about: event.localPosition);
                } else if (event is PointerScrollEvent && (keys.isMetaPressed || keys.isControlPressed)) {
                  // ⌘ and the wheel zoom about the pointer.
                  _zoomBy(math.exp(-event.scrollDelta.dy / 240), about: event.localPosition);
                } else if (event is PointerScrollEvent) {
                  final d = keys.isShiftPressed ? Offset(event.scrollDelta.dy, event.scrollDelta.dx) : event.scrollDelta;
                  _setScroll(_scroll + d);
                }
              },
              // Two fingers on a trackpad: moved, they scroll; pinched, they zoom about themselves.
              onPointerPanZoomStart: (_) => _zoomAtPinch = _zoom,
              onPointerPanZoomUpdate: (event) {
                if (event.scale != 1) _zoomTo(_zoomAtPinch * event.scale, about: event.localPosition);
                _setScroll(_scroll - event.panDelta);
              },
              onPointerDown: (event) {
                if (event.buttons != kPrimaryButton) return;
                final keys = HardwareKeyboard.instance;
                final add = keys.isShiftPressed || keys.isMetaPressed || keys.isControlPressed;
                if (event.localPosition.dy < _ruler) return _clickBar(event.localPosition, add: add);
                _click(event.localPosition, shift: keys.isShiftPressed, toggle: keys.isMetaPressed || keys.isControlPressed);
              },
              onPointerMove: (event) {
                if (event.buttons == kPrimaryButton) _dragTo(event.localPosition);
              },
              onPointerUp: (_) => _dragDone(),
              onPointerCancel: (_) => _dragDone(),
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _GalleyPainter(
                    galley: _galley,
                    zoom: _zoomed,
                    scroll: _scrolled,
                    marquee: _marquee,
                    gutter: _gutter,
                    ruler: _ruler,
                    bars: score.measureCount,
                    barNumber: score.barNumber,
                    numbers: _numbers,
                    paper: colors.scorePaper,
                    ink: colors.scoreInk,
                    accent: colors.accent,
                    chrome: colors.chrome,
                    line: colors.line,
                    text: colors.text,
                    selected: _selected,
                    caret: caret == null
                        ? null
                        : (
                            x: _caretX(caret),
                            staff: _staffNumber(caret.part, caret.staff),
                          ),
                    names: [
                      for (final (i, p) in score.parts.indexed) (name: p.name, first: _staffNumber(i, 1), last: _staffNumber(i, p.staves)),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (popover != null)
            _PopoverField(
              kind: popover,
              anchor: anchorRect ?? Rect.fromLTWH(_gutter + 24, 24, 0, 0),
              area: size,
              controller: _popoverText,
              focusNode: _popoverFocus,
              error: _popoverError,
              onSubmit: (text) {
                if (!_applyPopover(text)) setState(() => _popoverError = true);
              },
              onNext: popover == _Popover.lyrics ? (text) => _applyPopover(text, next: true) : null,
              onCancel: _closePopover,
              onChanged: () {
                if (_popoverError) setState(() => _popoverError = false);
              },
            ),
        ]),
      );
    });
  }

  static int _noteGlyph(NoteType v) => switch (v) {
        NoteType.breve => 0xE1D0,
        NoteType.whole => 0xE1D2,
        NoteType.half => 0xE1D3,
        NoteType.quarter => 0xE1D5,
        NoteType.eighth => 0xE1D7,
        NoteType.sixteenth => 0xE1D9,
        NoteType.thirtySecond => 0xE1DB,
        NoteType.sixtyFourth => 0xE1DD,
        NoteType.hundredTwentyEighth => 0xE1DF,
      };

  static String _valueName(NoteType v) => switch (v) {
        NoteType.breve => 'Breve'.tr,
        NoteType.whole => 'Whole'.tr,
        NoteType.half => 'Half'.tr,
        NoteType.quarter => 'Quarter'.tr,
        NoteType.eighth => 'Eighth'.tr,
        NoteType.sixteenth => '16th'.tr,
        NoteType.thirtySecond => '32nd'.tr,
        NoteType.sixtyFourth => '64th'.tr,
        NoteType.hundredTwentyEighth => '128th'.tr,
      };
}

/// A row of the notations panel: its name and its key.
class _PanelRow extends StatelessWidget {
  const _PanelRow({required this.label, required this.shortcut, required this.onPressed, this.selected = false});
  final String label, shortcut;
  final VoidCallback onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors, style = AppStyle.of(context);
    return InkWell(
      onTap: onPressed,
      child: Container(
        height: style.row - 6,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        color: selected ? colors.accentWash : null,
        child: Row(children: [
          Expanded(child: Text(label, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: colors.text))),
          Text(shortcut, style: TextStyle(fontSize: 12, color: colors.textMuted)),
        ]),
      ),
    );
  }
}

/// A popover: a field by the selection where what to add is typed, as in Dorico.
class _PopoverField extends StatelessWidget {
  const _PopoverField({
    required this.kind,
    required this.anchor,
    required this.area,
    required this.controller,
    required this.focusNode,
    required this.error,
    required this.onSubmit,
    required this.onCancel,
    required this.onChanged,
    this.onNext,
  });
  final _Popover kind;
  final Rect anchor;
  final Size area;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool error;
  final ValueChanged<String> onSubmit;
  final ValueChanged<String>? onNext;
  final VoidCallback onCancel, onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors, style = AppStyle.of(context);
    const width = 220.0, height = 64.0;
    final below = kind == _Popover.dynamics || kind == _Popover.lyrics || kind == _Popover.holds;
    var top = below ? anchor.bottom + 6 : anchor.top - height - 6;
    if (top < 4) top = anchor.bottom + 6;
    if (top + height > area.height - 4) top = math.max(4.0, anchor.top - height - 6);
    final left = anchor.left.clamp(4.0, math.max(4.0, area.width - width - 4)).toDouble();
    return Positioned(
      left: left,
      top: top,
      width: width,
      child: Material(
        color: Theme.of(context).dialogTheme.backgroundColor,
        elevation: 8,
        shadowColor: Colors.black.withValues(alpha: 0.25),
        animationDuration: Duration.zero,
        shape: style.isCarbon ? const RoundedRectangleBorder() : RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: colors.line)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(kind.title.tr, style: TextStyle(fontSize: 11, color: colors.textMuted)),
            const SizedBox(height: 4),
            Focus(
              onKeyEvent: (_, event) {
                if (event is! KeyDownEvent) return KeyEventResult.ignored;
                if (event.logicalKey == LogicalKeyboardKey.escape) {
                  onCancel();
                  return KeyEventResult.handled;
                }
                if (onNext != null && (event.logicalKey == LogicalKeyboardKey.space || event.character == '-')) {
                  final text = event.character == '-' ? '${controller.text}-' : controller.text;
                  onNext!(text);
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: SizedBox(
                height: 28,
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  autofocus: true,
                  style: TextStyle(fontSize: 13, color: colors.text),
                  onChanged: (_) => onChanged(),
                  onSubmitted: onSubmit,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: kind.hint,
                    hintStyle: TextStyle(fontSize: 13, color: colors.textMuted),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                    enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: error ? colors.erase : colors.line)),
                    focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: error ? colors.erase : colors.accent, width: 1.5)),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// SMuFL glyphs of the bundled Bravura, each [lift] staff spaces above the box's middle.
class _Glyph extends StatelessWidget {
  const _Glyph(this.codes);
  final List<(int, double)> codes;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: const Size.square(20), painter: _GlyphPainter(codes, IconTheme.of(context).color ?? context.colors.text));
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.codes, this.color);
  final List<(int, double)> codes;
  final Color color;

  @override
  void paint(Canvas canvas, Size box) {
    const size = 18.0, space = size / 4;
    for (final (code, lift) in codes) {
      final glyph = TextPainter(
        text: TextSpan(
            text: String.fromCharCode(code), style: TextStyle(color: color, fontFamily: const RenderStyle().musicFontFamily, fontSize: size, height: 1)),
        textDirection: TextDirection.ltr,
      )..layout();
      glyph.paint(canvas,
          Offset((box.width - glyph.width) / 2, box.height / 2 + lift * space - glyph.computeDistanceToActualBaseline(TextBaseline.alphabetic)));
      glyph.dispose();
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.color != color || old.codes != codes;
}

/// A slur, for its button (no SMuFL glyph is one).
class _Slur extends StatelessWidget {
  const _Slur();

  @override
  Widget build(BuildContext context) => CustomPaint(size: const Size.square(20), painter: _SlurPainter(IconTheme.of(context).color ?? context.colors.text));
}

class _SlurPainter extends CustomPainter {
  _SlurPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(2, 13)
      ..quadraticBezierTo(size.width / 2, 2, size.width - 2, 13)
      ..quadraticBezierTo(size.width / 2, 5, 2, 13);
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SlurPainter old) => old.color != color;
}

/// The galley drawn: the paper, the score scrolled, the selection in the accent, the caret, and
/// the instruments' names in a column of their own at the left.
class _GalleyPainter extends CustomPainter {
  _GalleyPainter({
    required this.galley,
    required this.zoom,
    required this.scroll,
    required this.gutter,
    required this.ruler,
    required this.bars,
    required this.barNumber,
    required this.numbers,
    required this.paper,
    required this.ink,
    required this.accent,
    required this.chrome,
    required this.line,
    required this.text,
    required this.selected,
    required this.caret,
    required this.names,
    required this.marquee,
  }) : super(repaint: Listenable.merge([zoom, scroll, marquee]));

  final EditGalley galley;
  final double gutter, ruler;

  /// How many bars the score has, and what each is numbered.
  final int bars;
  final String Function(int bar) barNumber;

  /// The numbers laid out, kept from one frame to the next.
  final Map<String, TextPainter> numbers;

  /// Points a staff space: drawn again when it changes, as when scrolled.
  final ValueListenable<double> zoom;

  /// How far the score is scrolled: drawn again when it changes.
  final ValueListenable<Offset> scroll;

  /// The rectangle being dragged out, galley units.
  final ValueListenable<Rect?> marquee;
  final Color paper, ink, accent, chrome, line, text;
  final Set<String> selected;
  final ({double? x, int staff})? caret;
  final List<({String name, int first, int last})> names;

  @override
  void paint(Canvas canvas, Size size) {
    final scroll = this.scroll.value, scale = zoom.value / galley.staffSpace;
    canvas.drawRect(Offset.zero & size, Paint()..color = paper);
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(gutter, ruler, size.width, size.height));
    canvas.translate(gutter - scroll.dx, ruler - scroll.dy);
    canvas.scale(scale);
    final visible = Rect.fromLTWH(scroll.dx / scale, scroll.dy / scale, (size.width - gutter) / scale, (size.height - ruler) / scale);
    galley.paint(canvas, visible, ink: ink, selected: selected, accent: accent);
    if (caret case (:final x?, :final staff)) {
      final top = galley.staffTop(staff);
      if (top != null) {
        final space = galley.staffSpace;
        final paint = Paint()
          ..color = accent
          ..strokeWidth = 2 / scale;
        canvas.drawLine(Offset(x - space * 0.6, top - space * 1.5), Offset(x - space * 0.6, top + galley.staffHeight(staff) + space * 1.5), paint);
        canvas.drawRect(Rect.fromLTWH(x - space * 0.6, top - space * 1.5, space * 0.9, 2 / scale), paint);
      }
    }
    if (marquee.value case final area?) {
      canvas.drawRect(area, Paint()..color = accent.withValues(alpha: 0.12));
      canvas.drawRect(
          area,
          Paint()
            ..color = accent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1 / scale);
    }
    canvas.restore();

    // The bars' numbers along the top, each at its bar's left.
    canvas.drawRect(Rect.fromLTWH(gutter, 0, size.width - gutter, ruler), Paint()..color = chrome);
    canvas.drawRect(Rect.fromLTWH(gutter, ruler - 1, size.width - gutter, 1), Paint()..color = line);
    if (galley.barsIn(visible.left, visible.right) case (:final from, :final to)) {
      canvas.save();
      canvas.clipRect(Rect.fromLTRB(gutter, 0, size.width, ruler));
      final muted = text.withValues(alpha: 0.62);
      for (var m = from; m < to && m < bars; m++) {
        final bar = galley.barOf(m);
        if (bar == null) continue;
        final x = bar.left * scale - scroll.dx + gutter;
        if (x > size.width) break;
        canvas.drawRect(Rect.fromLTWH(x, ruler - 6, 1, 5), Paint()..color = line);
        final label = barNumber(m);
        final number = numbers['$label ${muted.toARGB32()}'] ??= TextPainter(
          text: TextSpan(text: label, style: TextStyle(fontSize: 11, color: muted, fontFeatures: const [FontFeature.tabularFigures()])),
          textDirection: TextDirection.ltr,
        )..layout();
        number.paint(canvas, Offset(x + 4, (ruler - number.height) / 2));
      }
      canvas.restore();
    }

    // The names, over a column of their own.
    canvas.drawRect(Rect.fromLTWH(0, 0, gutter, size.height), Paint()..color = chrome);
    canvas.drawRect(Rect.fromLTWH(gutter - 1, 0, 1, size.height), Paint()..color = line);
    for (final (:name, :first, :last) in names) {
      final top = galley.staffTop(first), bottom = galley.staffTop(last);
      if (top == null || bottom == null) continue;
      final middle = ((top + bottom + galley.staffHeight(last)) / 2) * scale - scroll.dy + ruler;
      if (middle < ruler + 4 || middle > size.height + 20) continue;
      final painter = TextPainter(
        text: TextSpan(text: name, style: TextStyle(fontSize: 12, color: text)),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: gutter - 16);
      painter.paint(canvas, Offset(gutter - 10 - painter.width, middle - painter.height / 2));
      painter.dispose();
    }
  }

  @override
  bool shouldRepaint(_GalleyPainter old) =>
      old.galley != galley ||
      old.zoom != zoom ||
      old.scroll != scroll ||
      old.selected != selected ||
      old.caret != caret ||
      old.paper != paper ||
      old.ink != ink ||
      old.accent != accent;
}
