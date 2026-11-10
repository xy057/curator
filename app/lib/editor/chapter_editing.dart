part of '../editor_controller.dart';

/// Chapters (the Chapters extension): named places in the score, each running to the next,
/// which a video carries for its player and a web page lists. The controller keeps them in
/// its own edits, so opening, Undo and closing take them. Nothing here works, and nothing is
/// exported, while [enabled] is off (Project Settings ▸ Extensions ▸ Chapters); they stay in
/// the project.
class ChapterEditing {
  ChapterEditing._(this._editor);
  final EditorController _editor;

  /// The extension's switch, as the project has it ([EditorController.extensionOn]).
  bool get enabled => _enabled;
  bool _enabled = false;
  set enabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    if (!value) _selected = null;
    _editor._changed();
  }

  /// In the score's order, one to a place ([tidyChapters]).
  List<Chapter> get chapters => _editor._doc.chapters;

  /// The chapters a video or a page gets: none while the extension is off.
  List<Chapter> get exported => _enabled ? chapters : const [];

  /// The least two chapters are apart, in score quarters.
  static const apart = 0.25;

  /// The selected chapter (an index into [chapters], in the Chapters lane); null: none.
  int? get selected => _selected;
  int? _selected;

  void select(int? index) {
    if (!_enabled || (index != null && (index < 0 || index >= chapters.length))) index = null;
    if (index == _selected) return;
    _selected = index;
    _editor._changed();
  }

  /// The chapter starting at score quarter [at] (an index into [chapters]), but for [except].
  int? startingAt(double at, {int? except}) {
    for (final (i, c) in chapters.indexed) {
      if (i != except && (c.at - at).abs() < 1e-6) return i;
    }
    return null;
  }

  /// Adds [chapter] (in place of one starting where it does) and selects it. One Undo step.
  void add(Chapter chapter) {
    if (!_enabled || _editor._score == null || chapter.name.trim().isEmpty) return;
    _set([...chapters, _within(chapter)]);
    _selected = startingAt(_within(chapter).at);
  }

  /// Changes chapter [index]; an empty name removes it.
  void update(int index, Chapter chapter) {
    if (!_enabled || index < 0 || index >= chapters.length) return;
    if (chapter.name.trim().isEmpty) return remove(index);
    final next = _within(chapter);
    if (chapters[index] == next) return;
    // Last, so it is the one that stays where another starts.
    _set([...chapters]..removeAt(index)..add(next));
    _selected = _selected == null ? null : startingAt(next.at);
  }

  /// Removes chapter [index] (the selected one by default).
  void remove([int? index]) {
    index ??= _selected;
    if (!_enabled || index == null || index < 0 || index >= chapters.length) return;
    _selected = null;
    _set([...chapters]..removeAt(index));
  }

  /// The score's rehearsal marks as chapters, each from its bar: none in a score without any.
  List<Chapter> get marks {
    final score = _editor._score;
    if (score == null) return const [];
    final starts = score.timeline.measureStarts;
    return tidyChapters([
      // The first of two in one bar stays, as the bar numbers' row shows it.
      for (final text in score.texts.reversed)
        if (text.kind == ScoreTextKind.rehearsal && text.measure >= 0 && text.measure < starts.length - 1)
          Chapter(starts[text.measure], score.currentText(text)),
    ]);
  }

  /// The [marks] no chapter starts at yet.
  List<Chapter> get _newMarks => [
        for (final m in marks)
          if (startingAt(m.at) == null) m,
      ];

  /// Whether [addMarks] would add any.
  bool get canAddMarks => _enabled && _newMarks.isNotEmpty;

  /// Adds a chapter at every rehearsal mark where none starts. One Undo step.
  void addMarks() {
    final added = _newMarks;
    if (!_enabled || added.isEmpty) return;
    _selected = null;
    _set([...chapters, ...added]);
  }

  /// [chapter] inside the score: never at its very end.
  Chapter _within(Chapter chapter) {
    final total = _editor.beats.totalQuarters;
    return chapter.copyWith(at: chapter.at.clamp(0.0, math.max(0.0, total - apart)).toDouble());
  }

  void _set(List<Chapter> chapters) {
    final e = _editor, next = tidyChapters(chapters);
    if (listEquals(next, e._doc.chapters)) return;
    e._doc = e._doc.copyWith(chapters: List.unmodifiable(next));
    e._edited();
  }
}
