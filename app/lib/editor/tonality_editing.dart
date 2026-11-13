part of '../editor_controller.dart';

/// Tonality (the Tonality extension): the key the music is in from place to place, drawn as a
/// band of colours along the score's top ([CuratedScene.keyAreas]), each area named by the
/// user's own marking or its key's name. The controller keeps the key areas in its own edits,
/// so opening, Undo and closing take them. Nothing here works, and nothing is drawn, while
/// [enabled] is off (Project Settings ▸ Extensions ▸ Tonality); they stay in the project.
class TonalityEditing {
  TonalityEditing._(this._editor);
  final EditorController _editor;

  /// The extension's switch, as the project has it ([EditorController.extensionOn]).
  bool get enabled => _enabled;
  bool _enabled = false;
  set enabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    if (!value) _selected = null;
    _show();
    _editor._changed();
  }

  /// In the score's order, one to a place ([tidyKeyAreas]).
  List<KeyArea> get areas => _editor._doc.keyAreas;

  /// [key]'s name in the interface's language ("F major").
  static String nameOf(MusicKey key) => key.name.tr;

  /// What [area] is called in the band: the user's marking, else its key's name ([nameOf]).
  static String labelOf(KeyArea area) => area.label ?? nameOf(area.key);

  /// The key areas the scene draws, each with what it is called ([labelOf]): none while the
  /// extension is off.
  List<KeyArea> get _sceneAreas {
    if (!_enabled) return const [];
    _namedIn = Strings.language;
    return [for (final a in areas) a.label == null ? a.copyWith(label: nameOf(a.key)) : a];
  }

  /// The language the scene's key names are in.
  AppLanguage? _namedIn;

  /// The scene's key names follow the interface's [language] (Settings ▸ General ▸ Language),
  /// once it has switched to it.
  void followLanguage(AppLanguage language) {
    if (!_enabled || areas.isEmpty || language.resolved == _namedIn) return;
    scheduleMicrotask(() {
      if (!_editor._disposed) _show();
    });
  }

  /// The least two key areas are apart, in score quarters.
  static const apart = 0.25;

  /// The selected key area (an index into [areas], in the Tonality lane); null: none.
  int? get selected => _selected;
  int? _selected;

  void select(int? index) {
    if (!_enabled || (index != null && (index < 0 || index >= areas.length))) index = null;
    if (index == _selected) return;
    _selected = index;
    _editor._changed();
  }

  /// The key area starting at score quarter [at] (an index into [areas]), but for [except].
  int? startingAt(double at, {int? except}) {
    for (final (i, a) in areas.indexed) {
      if (i != except && (a.at - at).abs() < 1e-6) return i;
    }
    return null;
  }

  /// The key at score quarter [at]: the area's there (the first's before it), else C major.
  /// What a new area starts as.
  MusicKey keyAt(double at) => (areas.lastWhere((a) => a.at <= at + 1e-9, orElse: () => areas.firstOrNull ?? const KeyArea(0, MusicKey(0)))).key;

  /// Adds [area] (in place of one starting where it does) and selects it. One Undo step.
  void add(KeyArea area) {
    if (!_enabled || _editor._score == null) return;
    final next = _within(area);
    _set([...areas, next]);
    _selected = startingAt(next.at);
  }

  /// Changes key area [index].
  void update(int index, KeyArea area) {
    if (!_enabled || index < 0 || index >= areas.length) return;
    final next = _within(area);
    if (areas[index] == next) return;
    // Last, so it is the one that stays where another starts.
    _set([...areas]..removeAt(index)..add(next));
    _selected = _selected == null ? null : startingAt(next.at);
  }

  /// Removes key area [index] (the selected one by default).
  void remove([int? index]) {
    index ??= _selected;
    if (!_enabled || index == null || index < 0 || index >= areas.length) return;
    _selected = null;
    _set([...areas]..removeAt(index));
  }

  /// Whether Find Keys is reading the score.
  bool get finding => _finding != null;
  Future<List<KeyArea>>? _finding;

  /// Whether [find] would read the score.
  bool get canFind => _enabled && _editor._score != null && _finding == null;

  /// Find Keys: the keys [findKeys] hears in the score, in place of the areas there are (one
  /// Undo step); an area found where one was in the same key keeps its marking. Read on an
  /// isolate; a score that has changed meanwhile takes nothing.
  Future<void> find() async {
    final score = _editor._score;
    if (!canFind || score == null) return;
    final finding = _finding = _findOff(score.musicXML, score.timeline.measureStarts);
    _editor._changed();
    try {
      final found = await finding;
      if (_editor._disposed || _editor._score != score || !_enabled || found.isEmpty) return;
      final markings = {for (final a in areas) if (a.label != null) ((a.at * 1e6).round(), a.key): a.label};
      _selected = null;
      _set([for (final a in found) a.copyWith(label: markings[((a.at * 1e6).round(), a.key)])]);
    } finally {
      _finding = null;
      if (!_editor._disposed) _editor._changed();
    }
  }

  /// On an isolate, from a static function: a closure made beside one that uses the controller
  /// would take it along.
  static Future<List<KeyArea>> _findOff(String xml, List<double> starts) => Isolate.run(() => findKeys(xml, starts));

  /// [area] inside the score: never at its very end.
  KeyArea _within(KeyArea area) {
    final total = _editor.beats.totalQuarters;
    return area.copyWith(at: area.at.clamp(0.0, math.max(0.0, total - apart)).toDouble());
  }

  void _set(List<KeyArea> next) {
    final e = _editor, tidy = tidyKeyAreas(next);
    if (listEquals(tidy, e._doc.keyAreas)) return;
    e._doc = e._doc.copyWith(keyAreas: List.unmodifiable(tidy));
    _show();
    e._edited();
  }

  void _show() {
    _editor._showSettings();
    _editor.playback._markDirty(); // the preview repaints only when asked
  }
}
