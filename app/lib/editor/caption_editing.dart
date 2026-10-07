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
    _c.playback._markDirty();
    _c._changed();
  }

  // MARK: Look

  /// The font captions are drawn in, chosen for this project (Score ▸ Fonts…): a text font
  /// family; null: the app's ([defaultFont]). An edit.
  String? get font => _font;
  String? _font;

  void setFont(String? name) {
    if (!_enabled || _c._score == null || name == _font) return;
    _font = name;
    _applyStyle();
    _c._edited();
    _c._changed();
  }

  /// The app's caption font when a project chooses none (Settings ▸ Extension ▸ Captions):
  /// a family, or '' for the score's text font.
  String get defaultFont => _defaultFont;
  String _defaultFont = '';
  CaptionPosition _position = CaptionPosition.bottom;
  CaptionCountdown _countdown = CaptionCountdown.line;
  CaptionSize _size = CaptionSize.medium;

  /// Takes the app's caption settings.
  void configure({required String font, required CaptionPosition position, required CaptionCountdown countdown, required CaptionSize size}) {
    if (font == _defaultFont && position == _position && countdown == _countdown && size == _size) return;
    _defaultFont = font;
    _position = position;
    _countdown = countdown;
    _size = size;
    _applyStyle();
  }

  /// The font in effect ('' : the score's text font).
  String get effectiveFont => _font ?? _defaultFont;

  /// False while [effectiveFont] isn't installed here: the score's text font stands in.
  bool get fontFound => _fontFound;
  bool _fontFound = true;

  /// As the scene draws them.
  CaptionStyle get style => _style;
  CaptionStyle _style = const CaptionStyle();
  int _styleGeneration = 0;

  /// Works out [style] (an installed family is read and registered first) and gives it to the
  /// scene. The latest call wins. Never throws (it isn't awaited): a family that can't be read
  /// is drawn as one not installed.
  Future<void> _applyStyle() async {
    final generation = ++_styleGeneration, name = effectiveFont;
    String? family;
    var found = true;
    if (name == TextFonts.academico) {
      family = TextFonts.familyOf(name);
    } else if (name.isNotEmpty) {
      try {
        final faces = await TextFonts.faces(name);
        if (faces == null) {
          found = false;
        } else {
          await TextFonts.load(name, faces);
          family = TextFonts.familyOf(name);
        }
      } catch (_) {
        found = false; // its files can't be read: as if not installed
      }
    }
    if (generation != _styleGeneration) return;
    _fontFound = found;
    _style = CaptionStyle(fontFamily: family, position: _position, countdown: _countdown, size: _size);
    _c._scene?.captionStyle = _style;
    _c.playback._markDirty(); // the preview repaints only when asked
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

  /// A new caption from the beat at score quarter [quarter] (or the end of the caption there),
  /// among [among] (the captions by default): [defaultBars] bars, or up to the next caption.
  /// Null when there's no room.
  Caption? draft(double quarter, [List<Caption>? among]) {
    among ??= _captions;
    final beats = _c.beats, total = beats.totalQuarters, q = quarter.clamp(0.0, total), m = beats.measureAt(q);
    var start = beats.beatsIn(m).lastWhere((b) => b <= q + 1e-9, orElse: () => beats.measureStarts[m]);
    for (final c in [...among]..sort((a, b) => a.start.compareTo(b.start))) {
      if (start >= c.start - 1e-9 && start < c.end - 1e-9) start = c.end;
    }
    final room = captionRoom(among, start, total);
    if (room == null) return null;
    final end = math.min(beats.measureStarts[math.min(beats.measureAt(start) + defaultBars, beats.measureStarts.length - 1)], room.to);
    return end - start < 1e-3 ? null : Caption(start, end, '');
  }

  /// The caption showing at [seconds] (an index into [captions]); null: none.
  int? at(double seconds) {
    if (!_enabled) return null;
    return _c.scene?.captionShowingAt(seconds);
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

  /// Kept apart: one shows at a time ([separateCaptions]).
  void _set(List<Caption> captions) {
    final apart = separateCaptions(captions);
    if (apart.length != captions.length) _selected = null;
    _captions = List.unmodifiable(apart);
    _show();
    _c._edited();
    _c._changed();
  }

  /// The captions as the scene draws them: none while the extension is off.
  List<Caption> get _sceneCaptions => _enabled ? _captions : const [];

  void _show() => _c._scene?.captions = _sceneCaptions;

  void _load(List<Caption> captions, String? font) {
    _captions = List.unmodifiable(captions);
    _font = font;
    _applyStyle();
  }

  /// After Undo / Redo.
  void _restore(List<Caption> captions, String? font) {
    _captions = captions;
    _selected = null;
    if (font != _font) {
      _font = font;
      _applyStyle();
    }
    _show();
  }

  void _reset() {
    _captions = const [];
    _font = null;
    _selected = null;
  }
}
