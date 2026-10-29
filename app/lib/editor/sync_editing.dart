part of '../editor_controller.dart';

/// Editing in the Audio tab: tapping along, the grid taps snap to, and the selected anchors.
class SyncEditing {
  SyncEditing._(this._editor);
  final EditorController _editor;

  /// The sync, while its anchors are set by hand (not while a MIDI tempo map sets them).
  SyncMap? get _sync => _editor._doc.midi == null ? _editor._sync : null;

  void _reset() {
    _tapArmed = false;
    _taps = null;
    _deselect();
    _pivot = null;
  }

  /// Nothing selected: no anchors, no change of the MIDI tempo map.
  void _deselect() {
    _selected = {};
    _selectedTempo = null;
  }

  bool get _isEmpty => _selected.isEmpty && _selectedTempo == null;

  void _restoreView(ViewState view) {
    _grid = view.grid ?? _grid;
    _snapToOnsets = view.snapTapsToOnsets ?? _snapToOnsets;
  }

  /// Space taps anchors while armed.
  bool get tapArmed => _tapArmed && _sync != null;
  bool _tapArmed = false;
  set tapArmed(bool value) {
    _tapArmed = value && _sync != null;
    if (value) _newPass();
    _editor._changed();
  }

  /// The tapping pass under way: a new one at each arming and each start of playback.
  TapPass? _taps;

  void _newPass() => _taps = _sync == null ? null : TapPass(_sync!);

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

  /// Selected anchors (indices into sync.anchors) while they are set by hand. Batch edits act
  /// on all of them.
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

  /// The change of the MIDI tempo map followed that is selected (an index into its tempos);
  /// null: none.
  int? get selectedTempo => _selectedTempo;
  int? _selectedTempo;

  void selectTempo(int? index) {
    if (index == _selectedTempo) return;
    _selectedTempo = index;
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

  /// Where bar 1 sounds in the recording (Starts at); with a MIDI tempo map, where it starts.
  void setStart(double seconds) {
    if (!seconds.isFinite) return;
    _editor._doc.midi != null ? _editor._followMidi(seconds) : _sync?.startSeconds = seconds;
  }

  /// Removes every anchor.
  void clear() {
    _sync?.clear();
    _selected = {};
    _editor._changed();
  }

  /// Whether a recording added is aligned at once (Settings ▸ General).
  bool alignAdded = true;

  /// How far Align has got (0–1) while it runs; null otherwise.
  double? get aligning => _aligning;
  double? _aligning;

  /// Align: anchors from the recording heard against the score ([AudioAlignment]) in place of
  /// those there, one Undo step. The repeats are the warps set by hand, or with none the score's
  /// own ([ScoreForm.passes]); with [snapToOnsets] each anchor moves onto a note heard within
  /// 50 ms. Returns how many anchors it set: 0 when it heard no music, null when it couldn't
  /// run (no recording, a MIDI tempo map followed, already running) or the document changed
  /// meanwhile. Throws when the recording can't be read.
  Future<int?> align() async {
    final sync = _sync, track = _editor.track, score = _editor._score;
    if (sync == null || track == null || score == null || _aligning != null) return null;
    final starts = score.timeline.measureStarts;
    final passes = sync.passes.length > 1 ? sync.passes : score.metadata.form.passes(starts);
    void report(double done) {
      _aligning = done;
      if (!_editor._disposed) _editor._changed();
    }

    report(0);
    try {
      ({Float32List frames, double frameRate})? heard;
      // In turn: replacing the recording deletes the file read.
      await _editor.inTurn(() async => heard = await track.chroma(progress: (done) => report(0.9 * done)));
      if (heard == null) return null;
      var anchors = await _alignOff(score.musicXML, starts, heard!, passes);
      if (_editor._disposed || _sync != sync || _editor.track != track) return null;
      if (snapToOnsets) {
        anchors = [for (final a in anchors) a.at(track.waveform.nearestOnset(a.seconds, 0.05) ?? a.seconds)];
      }
      if (anchors.isNotEmpty) sync.load(anchors, leadIn: sync.leadIn);
      _deselect();
      return sync.anchors.length;
    } finally {
      _aligning = null;
      if (!_editor._disposed) _editor._changed();
    }
  }

  /// On an isolate, from a static function: a closure made beside one that uses the controller
  /// would take it along.
  static Future<List<SyncAnchor>> _alignOff(
          String xml, List<double> starts, ({Float32List frames, double frameRate}) heard, List<ScorePass> passes) =>
      Isolate.run(() => AudioAlignment.anchors(
            audio: heard.frames,
            frameRate: heard.frameRate,
            notes: soundingNotes(xml, starts).toList(),
            measureStarts: starts,
            passes: passes,
          ));

  /// Space in tap mode: starts playback, then marks the beat that is sounding now.
  void tap() {
    final sync = _sync;
    final playback = _editor.playback;
    if (sync == null) return;
    if (!playback.isPlaying) {
      _newPass();
      playback.play();
      return;
    }
    var t = playback.time.value;
    final onset = snapToOnsets ? _editor.track?.waveform.nearestOnset(t, 0.08) : null;
    if (onset != null) t = onset;
    final taps = _taps?.sync == sync ? _taps! : _taps = TapPass(sync);
    final anchor = taps.tap(t, grid: grid);
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

  /// Delete: removes the selected anchors, or the selected change of the MIDI tempo map.
  void delete() {
    if (_editor._doc.midi case final midi?) {
      if (_selectedTempo case final i?) _editor.editMidiTempo(midi.removed({i}));
    } else {
      _sync?.removeAnchors(_valid);
    }
    _deselect();
    _editor._changed();
  }
}
