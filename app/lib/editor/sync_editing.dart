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
  /// meanwhile. Throws when the recording can't be read. It is three steps, which a script does
  /// one at a time (`hear`, `match`, `snap anchors`: [_hear], [_match], [_snapped]).
  Future<int?> align() => _whileAligning((report) async {
        final sync = _sync, track = _editor.track;
        final heard = await _hear(report);
        if (heard == null) return null;
        var anchors = await _match(heard);
        if (_editor._disposed || _sync != sync || _editor.track != track || sync == null || track == null) return null;
        if (snapToOnsets) anchors = _snapped(anchors, track, alignSnap);
        setAll(anchors);
        return sync.anchors.length;
      });

  /// How near a note heard starting Align snaps an anchor to it, in seconds.
  static const alignSnap = 0.05;

  /// Does [work] as Align: one at a time ([aligning] tells how far it says it has got, from 0
  /// until it ends); null where one is under way.
  Future<T?> _whileAligning<T>(Future<T?> Function(void Function(double done) report) work) async {
    if (_aligning != null) return null;
    var over = false;
    void report(double done) {
      if (over) return; // a stretch still being heard as it ended (another's failed) tells nothing
      _aligning = done;
      if (!_editor._disposed) _editor._changed();
    }

    report(0);
    try {
      return await work(report);
    } finally {
      over = true;
      _aligning = null;
      if (!_editor._disposed) _editor._changed();
    }
  }

  /// The recording as Align hears it ([AudioTrack.notes]: nine tenths of the work, as [report]
  /// is told), with the repeats the score is played through as they are now; null with nothing
  /// to hear.
  Future<({Float32List notes, List<ScorePass> passes})?> _hear(void Function(double done) report) async {
    final sync = _sync, track = _editor.track, score = _editor._score;
    if (sync == null || track == null || score == null) return null;
    final passes = sync.passes.length > 1 ? sync.passes : score.metadata.form.passes(score.timeline.measureStarts);
    Float32List? notes;
    // In turn: replacing the recording deletes the file read.
    await _editor.inTurn(() async => notes = await track.notes(progress: (done) => report(0.9 * done)));
    return notes == null ? null : (notes: notes!, passes: passes);
  }

  /// The anchors what was [heard] gives against the score; none without one.
  Future<List<SyncAnchor>> _match(({Float32List notes, List<ScorePass> passes}) heard) async {
    final score = _editor._score;
    return score == null ? const [] : _alignOff(score.musicXML, score.timeline.measureStarts, heard.notes, heard.passes);
  }

  /// [anchors], each on the nearest note [track] is heard starting, [within] seconds of it.
  /// [anchors] each moved onto the nearest note heard starting, [within] seconds of it, where
  /// that keeps it between its neighbours: two never meet on one note (a second there would be
  /// dropped as no anchor of its own).
  static List<SyncAnchor> _snapped(List<SyncAnchor> anchors, AudioTrack track, double within) {
    final sorted = [...anchors]..sort((a, b) => a.seconds.compareTo(b.seconds));
    final out = <SyncAnchor>[];
    for (final (i, a) in sorted.indexed) {
      final onset = track.waveform.nearestOnset(a.seconds, within);
      final after = out.lastOrNull?.seconds ?? double.negativeInfinity, before = sorted.elementAtOrNull(i + 1)?.seconds ?? double.infinity;
      out.add(onset != null && onset > after + 1e-6 && onset < before - 1e-6 ? a.at(onset) : a);
    }
    return out;
  }

  /// Puts [anchors] in place of those there (none: those there stay), with nothing selected.
  void setAll(List<SyncAnchor> anchors) {
    final sync = _sync;
    if (sync != null && anchors.isNotEmpty) sync.load(anchors, leadIn: sync.leadIn);
    _deselect();
  }

  /// Moves every anchor onto the nearest note heard starting, [within] seconds of it.
  void snapAll(double within) {
    final sync = _sync, track = _editor.track;
    if (sync != null && track != null) setAll(_snapped(sync.anchors, track, within));
  }

  /// On an isolate, from a static function: a closure made beside one that uses the controller
  /// would take it along.
  static Future<List<SyncAnchor>> _alignOff(String xml, List<double> starts, Float32List heard, List<ScorePass> passes) =>
      Isolate.run(() => AudioAlignment.anchors(
            audio: heard,
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

  /// ←/→ with a change of the MIDI tempo map selected: moves it to the next / previous beat
  /// of the score ([fine]: a sixteenth on), stopping short of its neighbours.
  void moveTempo(int direction, {bool fine = false}) {
    final midi = _editor._doc.midi, sync = _editor._sync, i = _selectedTempo;
    if (midi == null || sync == null || i == null || i == 0 || i >= midi.tempos.length) return;
    final t = midi.tempos[i], at = MidiInScore(midi, sync);
    final to = fine
        ? t.quarter + direction * 0.25
        : direction > 0
            ? at.beatAround(t.quarter + 1e-7).end
            : at.beatAround(t.quarter - 1e-7).start;
    _editor.editMidiTempo(midi.moved(i, quarter: to, quartersPerMinute: t.quartersPerMinute));
  }

  /// ↑/↓ with a change of the MIDI tempo map selected: its tempo a beat a minute up / down
  /// ([fine]: a tenth), as the lane counts beats (see [MidiInScore.beatLength]), onto that step.
  void retune(int direction, {bool fine = false}) {
    final midi = _editor._doc.midi, sync = _editor._sync, i = _selectedTempo;
    if (midi == null || sync == null || i == null || i >= midi.tempos.length) return;
    final t = midi.tempos[i], beat = MidiInScore(midi, sync).beatLength(t.quarter), step = fine ? 0.1 : 1.0;
    final steps = t.quartersPerMinute / beat / step;
    final bpm = (direction > 0 ? (steps + 1e-6).floor() + 1 : (steps - 1e-6).ceil() - 1) * step;
    if (bpm < step) return;
    _editor.editMidiTempo(midi.moved(i, quarter: t.quarter, quartersPerMinute: bpm * beat));
  }

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
