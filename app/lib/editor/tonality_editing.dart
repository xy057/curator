part of '../editor_controller.dart';

/// Tonality (the Tonality extension): the key the music is in, stretch by stretch, drawn as a
/// band of colours along the score's top ([CuratedScene.keyAreas]), each area named by the
/// user's own marking or its key's name. Key areas are edited as an instrument's regions are
/// (the Tonality lane, ←/→, [ / ], Delete), one going over another where they meet as a region
/// goes over its lane's: what it covers of the others is cut back. The controller keeps them in
/// its own edits, so opening, Undo and closing take them. Nothing here works, and nothing is
/// drawn, while [enabled] is off (Project Settings ▸ Extensions ▸ Tonality); they stay in the
/// project.
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

  /// In the score's order, never overlapping ([tidyKeyAreas]).
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

  /// The selected key area (an index into [areas], in the Tonality lane); null: none.
  int? get selected => _selected;
  int? _selected;

  void select(int? index) {
    if (!_enabled || (index != null && (index < 0 || index >= areas.length))) index = null;
    if (index == _selected) return;
    _selected = index;
    _editor._changed();
  }

  /// The key at score quarter [at]: the area's there, else the last one's before it (the first's
  /// before them all), else C major. What a new area starts as.
  MusicKey keyAt(double at) =>
      (areas.lastWhere((a) => a.start <= at + 1e-9, orElse: () => areas.firstOrNull ?? const KeyArea(0, 1, MusicKey(0)))).key;

  /// Where the area after score quarter [at] starts, else the end of the score: how far a key
  /// added at [at] goes.
  double nextStart(double at) =>
      areas.where((a) => a.start > at + 1e-6).firstOrNull?.start ?? _editor.beats.totalQuarters;

  /// Adds [area] over what it covers of the others, and selects it. One Undo step.
  void add(KeyArea area) {
    if (!_enabled || _editor._score == null) return;
    _set([...areas, area], select: area);
  }

  /// Changes key area [index] (its bounds over what they then cover of the others).
  void update(int index, KeyArea area) => reshape(index, area);

  /// Area [index] of [from] (the areas as a gesture found them; the current ones by default)
  /// as [area]: moved, trimmed or changed over what it then covers of the others, which a
  /// gesture gives back as it goes on, as the instruments' lanes do.
  void reshape(int index, KeyArea area, {List<KeyArea>? from}) {
    final base = from ?? areas;
    if (!_enabled || index < 0 || index >= base.length) return;
    _set([...base]..removeAt(index)..add(area), select: area);
  }

  /// Removes key area [index] (the selected one by default).
  void remove([int? index]) {
    index ??= _selected;
    if (!_enabled || index == null || index < 0 || index >= areas.length) return;
    _selected = null;
    _set([...areas]..removeAt(index));
  }

  /// Every area at once, as erasing leaves them: each a piece of area [from] of [before].
  void replaceAll(List<KeyArea> before, List<({int from, double start, double end})> pieces) {
    if (!_enabled) return;
    _selected = null;
    _set([
      for (final p in pieces)
        if (p.from >= 0 && p.from < before.length) before[p.from].copyWith(start: p.start, end: p.end),
    ]);
  }

  /// ←/→: the selected area moves to the next or previous barline (or beat), over what it then
  /// covers, as a region does.
  void nudge(int direction, {bool beat = false}) {
    final sync = _editor._sync, i = _selected;
    if (!_enabled || sync == null || i == null || i >= areas.length) return;
    final a = areas[i], grid = beat ? SyncGrid.beat : SyncGrid.bar;
    final to = direction > 0 ? sync.nextGrid(a.start, grid) : sync.previousGrid(a.start, grid);
    final delta = (to - a.start).clamp(-a.start, _editor.beats.totalQuarters - a.end).toDouble();
    if (delta.abs() < 1e-9) return;
    reshape(i, a.copyWith(start: a.start + delta, end: a.end + delta));
  }

  /// [ / ]: the selected area now starts (or ends) at the beat nearest the playhead, unless that
  /// would turn it inside out.
  void trimToPlayhead({required bool start}) {
    final sync = _editor._sync, i = _selected;
    if (!_enabled || sync == null || i == null || i >= areas.length) return;
    final q = sync.nearestGrid(_editor.timeline.quarterAtSeconds(_editor.playback.time.value), SyncGrid.beat);
    final a = areas[i];
    if (start ? q >= a.end - 1e-6 : q <= a.start + 1e-6) return;
    reshape(i, start ? a.copyWith(start: q) : a.copyWith(end: q));
  }

  /// Whether Find Keys is reading the score.
  bool get finding => _finding != null;
  Future<List<KeyArea>>? _finding;

  /// Whether [find] would read the score.
  bool get canFind => _enabled && _editor._score != null && _finding == null;

  /// Find Keys: the keys [findKeys] hears in the score, in place of the areas there are (one
  /// Undo step); an area found where one was, in the same key, keeps its marking. Read on an
  /// isolate; a score that has changed meanwhile takes nothing.
  Future<void> find() async {
    final score = _editor._score;
    if (!canFind || score == null) return;
    final finding = _finding = _findOff(score.musicXML, score.timeline.measureStarts);
    _editor._changed();
    try {
      final found = await finding;
      if (_editor._disposed || _editor._score != score || !_enabled || found.isEmpty) return;
      int place(double q) => (q * 1e6).round();
      final markings = {for (final a in areas) if (a.label != null) (place(a.start), place(a.end), a.key): a.label};
      _selected = null;
      _set([for (final a in found) a.copyWith(label: markings[(place(a.start), place(a.end), a.key)])]);
    } finally {
      _finding = null;
      if (!_editor._disposed) _editor._changed();
    }
  }

  /// On an isolate, from a static function: a closure made beside one that uses the controller
  /// would take it along.
  static Future<List<KeyArea>> _findOff(String xml, List<double> starts) => Isolate.run(() => findKeys(xml, starts));

  /// [next] kept ([tidyKeyAreas], inside the score), [select] (when given) selected where it
  /// went, or the selection kept on the area it was.
  void _set(List<KeyArea> next, {KeyArea? select}) {
    final e = _editor, total = e.beats.totalQuarters;
    final was = _selected != null && _selected! < areas.length ? areas[_selected!] : null;
    final tidy = tidyKeyAreas([
      for (final a in next) a.copyWith(start: a.start.clamp(0.0, total).toDouble(), end: a.end.clamp(0.0, total).toDouble()),
    ]);
    int? find(KeyArea? a) {
      if (a == null) return null;
      final i = tidy.indexWhere((t) => (t.start - a.start).abs() < 1e-6 && t.key == a.key);
      return i < 0 ? null : i;
    }

    _selected = select != null ? find(tidyKeyAreas([select]).firstOrNull) : find(was);
    if (listEquals(tidy, e._doc.keyAreas)) return e._changed();
    e._doc = e._doc.copyWith(keyAreas: List.unmodifiable(tidy));
    _show();
    e._edited();
  }

  void _show() {
    _editor._showSettings();
    _editor.playback._markDirty(); // the preview repaints only when asked
  }
}
