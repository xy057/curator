part of '../editor_controller.dart';

/// Spacers (the Attach Image extension): vertical ones, staves of nothing that are instruments
/// of their own (a lane, a name, a place in the order), and horizontal ones, blanks opened
/// between beats. The controller keeps them in its own edits, so opening, Undo and closing take
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

  /// Adds a vertical spacer just below [below]'s lane (null: at the bottom), shown throughout:
  /// one Undo step. It shows once engraved again.
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
  Future<void> removeVertical(String id) async {
    final e = _editor;
    if (!enabled || verticalOf(id) == null) return;
    e._doc = e._doc.copyWith(
      spacers: List.unmodifiable([for (final s in vertical) if (s.id != id) s]),
      partOrder: List.unmodifiable([for (final p in e._doc.partOrder) if (p != id) p]),
    );
    await _engrave();
  }

  /// The horizontal spacer opened at score quarter [quarter], if any (an index into [horizontal]).
  int? horizontalAt(double quarter) {
    final at = _place(quarter);
    if (at == null) return null;
    final i = horizontal.indexWhere((g) => g.bar == at.bar && (g.offset - at.offset).abs() < 1e-6);
    return i < 0 ? null : i;
  }

  /// Opens a horizontal spacer before what sounds at score quarter [quarter] (a beat): one Undo
  /// step. Nothing when one is there already.
  Future<void> addHorizontal(double quarter) async {
    final at = _place(quarter);
    if (!enabled || at == null || horizontalAt(quarter) != null) return;
    final e = _editor;
    final gaps = [...horizontal, HorizontalSpacer(bar: at.bar, offset: at.offset)]
      ..sort((a, b) => a.bar != b.bar ? a.bar.compareTo(b.bar) : a.offset.compareTo(b.offset));
    e._doc = e._doc.copyWith(gaps: List.unmodifiable(gaps));
    await _engrave();
  }

  /// Makes horizontal spacer [index] [width] staff spaces wide: one Undo step.
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

  /// Engraves the score again with the spacers as they are now, and records the step.
  Future<void> _engrave() async {
    final e = _editor;
    final engraved = e._reengrave();
    e._showSettings();
    e._edited(); // one Undo step, right away
    await engraved;
  }
}
