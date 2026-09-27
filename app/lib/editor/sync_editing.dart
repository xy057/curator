part of '../editor_controller.dart';

/// Editing in the Audio tab: tapping along, the grid taps snap to, and the selected anchors.
class SyncEditing {
  SyncEditing._(this._editor);
  final EditorController _editor;

  SyncMap? get _sync => _editor._sync;

  void _reset() {
    _tapArmed = false;
    _selected = {};
    _pivot = null;
  }

  void _restoreView(ViewState view) {
    _grid = view.grid ?? _grid;
    _snapToOnsets = view.snapTapsToOnsets ?? _snapToOnsets;
  }

  /// Space taps anchors while armed.
  bool get tapArmed => _tapArmed;
  bool _tapArmed = false;
  set tapArmed(bool value) {
    _tapArmed = value;
    if (value) _sync?.beginTapping();
    _editor._changed();
  }

  /// What taps and ↑/↓ snap to.
  SyncGrid get grid => _grid;
  SyncGrid _grid = SyncGrid.bar;
  set grid(SyncGrid value) {
    _grid = value;
    _editor._changed();
  }

  /// Move each tap onto the nearest detected note onset (within 80 ms).
  bool get snapToOnsets => _snapToOnsets;
  bool _snapToOnsets = true;
  set snapToOnsets(bool value) {
    _snapToOnsets = value;
    _editor._changed();
  }

  // MARK: Selection

  /// Selected anchors (indices into sync.anchors). Batch edits act on all of them.
  Set<int> get selected => _selected;
  Set<int> _selected = {};
  int? _pivot; // where a ⇧-click range starts

  Set<int> get _valid {
    final count = _sync?.anchors.length ?? 0;
    return {for (final i in _selected) if (i < count) i};
  }

  /// Click: select just [index]. ⇧: extend a range from the last clicked. ⌘: toggle it.
  void select(int? index, {bool extend = false, bool toggle = false}) {
    if (index == null) {
      _selected = {};
    } else if (toggle) {
      _selected = {..._selected};
      if (!_selected.remove(index)) _selected.add(index);
      _pivot = index;
    } else if (extend && _pivot != null) {
      final lo = math.min(_pivot!, index), hi = math.max(_pivot!, index);
      _selected = {for (var i = lo; i <= hi; i++) i};
    } else {
      _selected = {index};
      _pivot = index;
    }
    _editor._changed();
  }

  /// Box selection: every anchor between two times, optionally added to what is selected.
  void selectBetween(double t0, double t1, {Set<int> keep = const {}}) {
    final sync = _sync;
    if (sync == null) return;
    _selected = {...keep, ...sync.anchorsBetween(t0, t1)};
    _editor._changed();
  }

  void selectAll() {
    final count = _sync?.anchors.length ?? 0;
    _selected = {for (var i = 0; i < count; i++) i};
    _editor._changed();
  }

  // MARK: Editing

  /// Pins [anchor] (a ⌥-click) and selects it.
  void add(SyncAnchor anchor) {
    final sync = _sync;
    if (sync == null) return;
    sync.addAnchor(anchor);
    select(sync.anchors.indexOf(anchor));
  }

  /// Drags the selected anchors [delta] seconds from where they were when the drag began
  /// ([from]), together. See [SyncMap.moveAnchors].
  void drag(double delta, {required List<SyncAnchor> from}) => _sync?.moveAnchors(_valid, delta, from: from);

  /// Points anchor [index] at [quarter] and makes it go on from [jumpTo] (a warp; null: a
  /// plain anchor). False (changing nothing) when that would put the anchors out of order or
  /// outside the score. See [SyncMap.setAnchor].
  bool setAnchor(int index, double quarter, {double? jumpTo}) =>
      _sync?.setAnchor(index, quarter, jumpTo: jumpTo) ?? false;

  /// Adds a warp at [seconds] (arriving at [quarter], going on from [jumpTo]; null: a plain
  /// anchor) as one step, and selects it. The anchors after it move with the jump (see
  /// [SyncMap.setJump]). False (adding nothing) when that would push one out of the score.
  bool addWarp(double seconds, double quarter, double? jumpTo) {
    final sync = _sync;
    if (sync == null) return false;
    final before = sync.anchors;
    _editor.beginEdit();
    sync.addAnchor(SyncAnchor(quarter, seconds));
    final index = sync.anchors.indexWhere((a) => a.seconds == seconds);
    final added = jumpTo == null || sync.setJump(index, jumpTo);
    if (!added) sync.load(before, leadIn: sync.leadIn);
    _editor.endEdit();
    select(added ? index : null);
    return added;
  }

  /// Where bar 1 sounds in the recording (Starts at).
  void setStart(double seconds) => _sync?.startSeconds = seconds;

  /// Removes every anchor.
  void clear() {
    _sync?.clear();
    _selected = {};
    _editor._changed();
  }

  /// Space in tap mode: starts playback, then marks the beat that is sounding now.
  void tap() {
    final sync = _sync;
    final playback = _editor.playback;
    if (sync == null) return;
    if (!playback.isPlaying) {
      sync.beginTapping();
      playback.play();
      return;
    }
    var t = playback.time.value;
    final onset = snapToOnsets ? _editor.track?.waveform.nearestOnset(t, 0.08) : null;
    if (onset != null) t = onset;
    final anchor = sync.tap(t, grid: grid);
    _selected = {sync.anchors.indexOf(anchor)};
    _pivot = sync.anchors.indexOf(anchor);
    _editor._changed();
  }

  /// ↑/↓: the selected anchors now mean the next/previous bar (or beat).
  void shift(int direction) {
    final sync = _sync;
    if (sync == null || !sync.shiftAnchors(_valid, direction, grid)) return;
    _editor._changed();
  }

  /// ←/→: nudge the selected anchors in time, together.
  void nudge(double seconds) => _sync?.moveAnchors(_valid, seconds);

  /// Delete: removes the selected anchors.
  void delete() {
    _sync?.removeAnchors(_valid);
    _selected = {};
    _editor._changed();
  }
}
