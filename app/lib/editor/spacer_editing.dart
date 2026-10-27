part of '../editor_controller.dart';

/// Spacers (the Attach Image extension): vertical ones, staves of nothing that are instruments
/// of their own (a lane, a name, a place in the order), and horizontal ones, stretches of the
/// score made wider (never overlapping). The controller keeps them in its own edits, so opening, Undo and closing take
/// them. Nothing here works while [ImageEditing.enabled] is off, and none is engraved or drawn
/// then; they stay in the project.
class SpacerEditing {
  SpacerEditing._(this._editor);
  final EditorController _editor;

  /// The extension's switch (Attach Image's).
  bool get enabled => _editor.images.enabled;

  /// The vertical spacers, in the order they were added.
  List<VerticalSpacer> get vertical => _editor._doc.spacers;

  /// The horizontal spacers, in the score's order.
  List<HorizontalSpacer> get horizontal => _editor._doc.gaps;

  /// The vertical spacer that is part [partId]; null for an instrument.
  VerticalSpacer? verticalOf(String partId) => vertical.where((s) => s.id == partId).firstOrNull;

  /// The selected vertical spacer (its part id), if one is.
  String? get selectedVertical => _selected is String && verticalOf(_selected as String) != null ? _selected as String : null;

  /// The selected horizontal spacer (an index into [horizontal]), if one is.
  int? get selectedHorizontal {
    if (_selected case ({int bar, double offset}) at) {
      final i = horizontal.indexWhere((g) => g.bar == at.bar && g.offset == at.offset);
      return i < 0 ? null : i;
    }
    return null;
  }

  bool get hasSelection => selectedVertical != null || selectedHorizontal != null;

  /// A vertical spacer's id, or where a horizontal one is (kept by place, not index, so Undo and
  /// re-sorting keep it).
  Object? _selected;

  /// Selects vertical spacer [id] (null: none), and nothing else.
  void selectVertical(String? id) => _select(id == null || verticalOf(id) == null ? null : id);

  /// Selects horizontal spacer [index] (null: none), and nothing else.
  void selectHorizontal(int? index) => _select(index == null || index < 0 || index >= horizontal.length
      ? null
      : (bar: horizontal[index].bar, offset: horizontal[index].offset));

  void _select(Object? what) {
    if (what == _selected) return;
    if (what != null) _editor.clearSelection();
    _selected = what;
    _editor._changed();
  }

  /// Removes the selected spacer: one Undo step.
  Future<void> removeSelected() async {
    if (selectedVertical case final id?) return removeVertical(id);
    if (selectedHorizontal case final i?) return removeHorizontal(i);
  }

  /// Adds a vertical spacer just below [below]'s lane (null: at the bottom), shown throughout,
  /// and selects it: one Undo step. It shows once engraved again.
  Future<void> addVertical({String? below}) async {
    final e = _editor, score = e._score;
    if (!enabled || score == null) return;
    final id = Spacers.nextId([for (final s in vertical) s.id, for (final p in score.metadata.parts) p.id]);
    final order = [...e._doc.partOrder];
    // Below a pair's shared staff, or a condensed pair's lane: below both players.
    final pair = e.condensable.where((g) => g.id == below).firstOrNull ?? (below == null ? null : e.condensedGroupOf(below));
    final after = below == null ? -1 : order.indexOf(pair?.second ?? below);
    order.insert(after < 0 ? order.length : after + 1, id);
    e._doc = e._doc.copyWith(
        spacers: List.unmodifiable([...vertical, VerticalSpacer(id: id)]), partOrder: List.unmodifiable(order));
    e._curation!.setLane(id, [Region(0, score.timeline.measureStarts.last)]);
    _selected = id;
    await _engrave();
  }

  /// Puts [spacer] in place of the vertical spacer with its id: one Undo step. Only a new key
  /// engraves again; the rest is drawn.
  Future<void> setVertical(VerticalSpacer spacer) async {
    final e = _editor, old = verticalOf(spacer.id);
    if (!enabled || old == null || old == spacer) return;
    e._doc = e._doc.copyWith(spacers: List.unmodifiable([for (final s in vertical) s.id == spacer.id ? spacer : s]));
    if (old.engravesLike(spacer)) {
      e._showSettings();
      e._edited();
      return;
    }
    await _engrave();
  }

  /// Takes the vertical spacer [id] out of the score, its lane with it: one Undo step.
  Future<void> removeVertical(String id) => removeVerticals([id]);

  /// Takes the vertical spacers [ids] out of the score, their lanes with them: one Undo step.
  Future<void> removeVerticals(Iterable<String> ids) async {
    final e = _editor, gone = {for (final id in ids) if (verticalOf(id) != null) id};
    if (!enabled || gone.isEmpty) return;
    e._doc = e._doc.copyWith(
      spacers: List.unmodifiable([for (final s in vertical) if (!gone.contains(s.id)) s]),
      partOrder: List.unmodifiable([for (final p in e._doc.partOrder) if (!gone.contains(p)) p]),
    );
    await _engrave();
  }

  /// The horizontal spacer over score quarter [quarter], if any (an index into [horizontal]).
  int? horizontalAt(double quarter) {
    for (final (i, _) in horizontal.indexed) {
      if (quarter >= startOf(i) - 1e-9 && quarter < endOf(i) - 1e-9) return i;
    }
    return null;
  }

  /// Widens [start]–[end] (score quarters) and selects it: one Undo step. Nothing where it
  /// would overlap one already there.
  Future<void> addHorizontal(double start, double end) async {
    final added = _spacer(start, end);
    if (!enabled || added == null) return;
    final engraved = _setHorizontal([...horizontal, added]);
    if (engraved == null) return;
    _editor.clearSelection();
    _selected = (bar: added.bar, offset: added.offset);
    _editor._changed();
    await engraved;
  }

  /// Puts horizontal spacer [index] over [start]–[end], its width kept (the selection with it):
  /// one Undo step. Nothing where it would overlap another.
  Future<void> setHorizontalSpan(int index, double start, double end) async {
    if (!enabled || index < 0 || index >= horizontal.length) return;
    final was = horizontal[index], next = _spacer(start, end, width: was.width);
    if (next == null || next == was) return;
    final selected = _selected == (bar: was.bar, offset: was.offset);
    final engraved = _setHorizontal([for (final (i, g) in horizontal.indexed) i == index ? next : g]);
    if (engraved == null) return;
    if (selected) _selected = (bar: next.bar, offset: next.offset);
    _editor._changed();
    await engraved;
  }

  /// Moves horizontal spacer [index] to start at score quarter [start], as long as it was (so
  /// no further on than ends it at the final barline).
  Future<void> moveHorizontal(int index, double start) {
    final length = endOf(index) - startOf(index), total = _editor._score!.timeline.measureStarts.last;
    start = math.min(start, total - length);
    return setHorizontalSpan(index, start, start + length);
  }

  /// Every horizontal spacer at once, each [pieces] entry over its stretch with the width of
  /// the one it is a piece of (erasing): one Undo step.
  Future<void> replaceHorizontal(List<({int from, double start, double end})> pieces) async {
    if (!enabled) return;
    final next = [
      for (final p in pieces)
        if (p.from >= 0 && p.from < horizontal.length) ?_spacer(p.start, p.end, width: horizontal[p.from].width),
    ];
    _selected = null;
    await _setHorizontal(next);
  }

  /// A horizontal spacer over [start]–[end]; null where it isn't in the score or is too short.
  HorizontalSpacer? _spacer(double start, double end, {double width = HorizontalSpacer.defaultWidth}) {
    final at = _place(start), total = _editor._score?.timeline.measureStarts.last ?? 0;
    if (at == null) return null; // before the score or past its end (then start > total)
    end = end.clamp(start, total).toDouble();
    if (end - start < HorizontalSpacer.minLength - 1e-9) return null;
    return HorizontalSpacer(bar: at.bar, offset: at.offset, length: end - start, width: width);
  }

  /// [gaps] in the score's order, engraving (the Undo step taken at once); null, nothing
  /// changed, where two overlap.
  Future<void>? _setHorizontal(List<HorizontalSpacer> gaps) {
    final starts = _editor._score!.timeline.measureStarts;
    double start(HorizontalSpacer g) => starts[g.bar] + g.offset;
    gaps.sort((a, b) => start(a).compareTo(start(b)));
    for (var i = 0; i + 1 < gaps.length; i++) {
      if (start(gaps[i]) + gaps[i].length > start(gaps[i + 1]) + 1e-9) return null;
    }
    if (listEquals(gaps, horizontal)) return null;
    final e = _editor;
    e._doc = e._doc.copyWith(gaps: List.unmodifiable(gaps));
    return _engrave();
  }

  /// Moves vertical spacer [id] to just before the [to]th of the other lanes (their count:
  /// to the bottom), its staff with it: one Undo step.
  void moveVertical(String id, int to) {
    if (!enabled || verticalOf(id) == null) return;
    _editor.moveLane(id, to);
  }

  /// Makes horizontal spacer [index] widen its stretch by [width] staff spaces: one Undo step.
  Future<void> setHorizontalWidth(int index, double width) async {
    if (!enabled || index < 0 || index >= horizontal.length) return;
    width = width.clamp(HorizontalSpacer.minWidth, HorizontalSpacer.maxWidth);
    if (width == horizontal[index].width) return;
    final e = _editor;
    e._doc = e._doc.copyWith(gaps: List.unmodifiable([
      for (final (i, g) in horizontal.indexed) i == index ? g.copyWith(width: width) : g,
    ]));
    await _engrave();
  }

  /// Closes horizontal spacer [index]: one Undo step.
  Future<void> removeHorizontal(int index) async {
    if (!enabled || index < 0 || index >= horizontal.length) return;
    final e = _editor;
    e._doc = e._doc.copyWith(gaps: List.unmodifiable([for (final (i, g) in horizontal.indexed) if (i != index) g]));
    await _engrave();
  }

  /// Score quarter [quarter] as a bar (counted from 0) and quarters into it; null past the end.
  ({int bar, double offset})? _place(double quarter) {
    final starts = _editor._score?.timeline.measureStarts;
    if (starts == null || quarter < 0 || quarter >= starts.last) return null;
    var bar = 0;
    while (bar + 2 < starts.length && starts[bar + 1] <= quarter) {
      bar++;
    }
    return (bar: bar, offset: quarter - starts[bar]);
  }

  /// Where horizontal spacer [index] starts and ends, score quarters.
  double startOf(int index) {
    final g = horizontal[index];
    return _editor._score!.timeline.measureStarts[g.bar] + g.offset;
  }

  double endOf(int index) => startOf(index) + horizontal[index].length;

  /// Engraves the score again with the spacers as they are now, and records the step.
  Future<void> _engrave() async {
    final e = _editor;
    final engraved = e._reengrave();
    e._showSettings();
    e._edited(); // one Undo step, right away
    await engraved;
  }
}
