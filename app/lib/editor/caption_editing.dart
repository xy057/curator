part of '../editor_controller.dart';

/// Captions under the score (the Captions extension): adding, changing and removing them.
/// Nothing here works, and no caption is drawn, while [enabled] is off (Settings ▸ Extension
/// ▸ Captions); the captions stay in the project.
class CaptionEditing {
  CaptionEditing._(this._c);
  final EditorController _c;

  /// The extension's switch.
  bool get enabled => _enabled;
  bool _enabled = false;
  set enabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    if (!value) _selected = null;
    _show();
    _c._changed();
  }

  /// In the order they were added.
  List<Caption> get captions => _captions;
  List<Caption> _captions = const [];

  /// The selected caption (an index into [captions], in the Captions lane); null: none.
  int? get selected => _selected;
  int? _selected;

  void select(int? index) {
    if (!_enabled || (index != null && (index < 0 || index >= _captions.length))) index = null;
    if (index == _selected) return;
    _selected = index;
    _c._changed();
  }

  /// How long a new caption lasts when nothing follows it, in bars.
  static const defaultBars = 4;

  /// A new caption from the beat at score quarter [quarter]: [defaultBars] bars, or up to
  /// the next caption.
  Caption draft(double quarter) {
    final beats = _c.beats, q = quarter.clamp(0.0, beats.totalQuarters), m = beats.measureAt(q);
    final start = beats.beatsIn(m).lastWhere((b) => b <= q + 1e-9, orElse: () => beats.measureStarts[m]);
    var end = beats.measureStarts[math.min(m + defaultBars, beats.measureStarts.length - 1)];
    for (final c in _captions) {
      if (c.start > start + 1e-9 && c.start < end) end = c.start;
    }
    return Caption(start, math.max(end, start + 1e-3), '');
  }

  /// The caption showing at [seconds] (an index into [captions]); null: none.
  int? at(double seconds) {
    if (!_enabled) return null;
    return _c._scene?.captionShowingAt(seconds);
  }

  /// Adds [caption]. One Undo step.
  void add(Caption caption) {
    if (!_enabled || _c._score == null || caption.text.trim().isEmpty) return;
    _set([..._captions, _tidy(caption)]);
  }

  /// Changes caption [index]; an empty text removes it.
  void update(int index, Caption caption) {
    if (!_enabled || index < 0 || index >= _captions.length) return;
    if (caption.text.trim().isEmpty) return remove(index);
    final next = _tidy(caption);
    if (_captions[index] == next) return;
    _set([..._captions]..[index] = next);
  }

  /// Replaces every caption at once (the Captions sheet, erasing): one Undo step, or part of
  /// a gesture. Those with an empty text are left out.
  void replaceAll(List<Caption> captions) {
    if (!_enabled || _c._score == null) return;
    final next = [for (final c in captions) if (c.text.trim().isNotEmpty) _tidy(c)];
    if (listEquals(next, _captions)) return;
    _selected = null;
    _set(next);
  }

  /// Removes caption [index] (the selected one by default).
  void remove([int? index]) {
    index ??= _selected;
    if (!_enabled || index == null || index < 0 || index >= _captions.length) return;
    _selected = null;
    _set([..._captions]..removeAt(index));
  }

  Caption _tidy(Caption c) => c.copyWith(text: c.text.trim());

  void _set(List<Caption> captions) {
    _captions = List.unmodifiable(captions);
    _show();
    _c._edited();
    _c._changed();
  }

  /// The captions as the scene draws them: none while the extension is off.
  List<Caption> get _sceneCaptions => _enabled ? _captions : const [];

  void _show() => _c._scene?.captions = _sceneCaptions;

  void _load(List<Caption> captions) => _captions = List.unmodifiable(captions);

  /// After Undo / Redo.
  void _restore(List<Caption> captions) {
    _captions = captions;
    _selected = null;
    _show();
  }

  void _reset() {
    _captions = const [];
    _selected = null;
  }
}
