import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:score_engine/score_engine.dart';

import 'audio_track.dart';
import 'edit_history.dart';
import 'error_text.dart';
import 'project_state.dart';
import 'time_viewport.dart';

part 'editor/lane_editing.dart';
part 'editor/playback.dart';
part 'editor/sync_editing.dart';

enum BottomTab { instruments, audio }

/// The open score and everything done to it: the engraving, the recording, the curation
/// (when each instrument is shown), the sync (where the score sits in the recording), names
/// and texts. Loading, saving state and Undo (one history for all of it) live here; the rest
/// is split by job:
///
///  * [playback]: the clock, play / pause / seek;
///  * [lanes]: editing in the Instruments tab (tools, the region selection, tidying);
///  * [anchors]: editing in the Audio tab (tapping, the anchor selection).
///
/// All of them notify through this controller, so a widget listens to one thing.
class EditorController extends ChangeNotifier {
  EditorController({required TickerProvider vsync}) {
    playback = Playback._(this, vsync);
  }

  late final Playback playback;
  late final lanes = LaneEditing._(this);
  late final anchors = SyncEditing._(this);

  /// Zoom and scroll shared by both tabs of the bottom panel.
  final viewport = TimeViewport();

  LoadedScore? _score;
  CuratedScene? _scene;
  Curation? _curation;
  SyncMap? _sync;
  String? _fileName;
  bool _loading = false;
  double _staffSpace = 9;

  LoadedScore? get score => _score;
  CuratedScene? get scene => _scene;

  /// When each instrument is shown. Edited in the Instruments tab; read by the preview.
  Curation? get curation => _curation;

  /// How the score lines up with the recording. Edited in the Audio tab.
  SyncMap? get sync => _sync;

  /// The musical-time ↔ seconds mapping everything uses.
  ScoreTimeline get timeline => _sync ?? _score!.timeline;

  /// Where the beats fall in each bar (from the time signatures): the finer grid.
  BeatGrid get beats => _score!.beats;

  String? get fileName => _fileName;
  bool get isLoading => _loading;
  double get staffSpace => _staffSpace;

  /// The range of the score size (the staff space, in logical pixels).
  static const minStaffSpace = 3.0, maxStaffSpace = 10.0;

  BottomTab _tab = BottomTab.instruments;
  BottomTab get tab => _tab;
  set tab(BottomTab value) {
    _tab = value;
    if (value != BottomTab.audio) anchors.tapArmed = false;
    notifyListeners();
  }

  /// For the parts ([Playback], [LaneEditing], [SyncEditing]), which can't call the protected
  /// [notifyListeners] themselves.
  void _changed() => notifyListeners();

  // MARK: Loading

  /// The score file as opened, byte for byte: projects keep it so the source is never lost.
  ({String name, Uint8List bytes})? get source => _source;
  ({String name, Uint8List bytes})? _source;

  /// Opens (imports) a score file: MusicXML, or compressed .mxl. If it can't be read, what
  /// was open stays open.
  Future<void> openFile(String path) async {
    final bytes = await File(path).readAsBytes();
    final score = await _engrave(bytes);
    await _install(path.split(RegExp(r'[/\\]')).last, bytes, score, const ProjectState());
  }

  /// Opens a saved project: the source score with its edits, then the recording at
  /// [mediaPath] (if any; [mediaOriginal] is its own file, when it still exists).
  ///
  /// Either the project opens or nothing changes: the score is engraved before anything is
  /// replaced. A recording that can't be loaded doesn't stop it; the reason is returned.
  Future<String?> openProject({
    required String name,
    required Uint8List scoreBytes,
    required ProjectState state,
    String? mediaPath,
    String? mediaOriginal,
  }) async {
    final score = await _engrave(scoreBytes, textEdits: state.textEdits, pairs: state.pairs);
    await _install(name, scoreBytes, score, state);
    if (mediaPath == null) return null;
    try {
      await loadAudio(mediaPath, temporary: true, originalPath: mediaOriginal);
      return null;
    } catch (e) {
      return 'The recording could not be loaded:\n${describeError(e)}';
    } finally {
      _tab = BottomTab.instruments;
      notifyListeners();
    }
  }

  /// Engraves a score (the slow part, and the one that can fail) without touching what is open.
  Future<LoadedScore> _engrave(Uint8List bytes,
      {Map<String, String> textEdits = const {}, List<PlayerPair> pairs = const []}) async {
    _loading = true;
    notifyListeners();
    try {
      return await LoadedScore.load(ScoreFile.decodeMusicXML(bytes),
          textEdits: textEdits, pairs: pairs, options: _engravingOptions);
    } finally {
      _loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Replaces what is open with [score] and the edits and view in [state], all at once.
  /// Nothing in here fails, so a project is never left half open.
  Future<void> _install(String name, Uint8List bytes, LoadedScore score, ProjectState state) async {
    if (_disposed) return; // the window closed while engraving
    playback.pause();
    await audio.unload();
    _closeDocument();
    final view = state.view;
    _score = score;
    _source = (name: name, bytes: bytes);
    _fileName = name;
    _staffSpace = (view.staffSpace ?? _staffSpace).clamp(minStaffSpace, maxStaffSpace);
    _partNames = Map.unmodifiable(state.partNames);
    _textEdits = Map.unmodifiable(state.textEdits);
    _pairs = List.unmodifiable({for (final p in state.pairs) ?score.condensing.pair(p.first, p.second)});
    _condensed = Set.unmodifiable({for (final g in condensable) if (state.condensed.contains(g.id)) g.id});
    _partOrder = CuratedScene.orderedPartIds(score.metadata.parts, state.partOrder);
    _midi = state.midi;
    _tapped = state.midi != null ? state.anchors : const [];
    _sync = SyncMap(measureStarts: score.timeline.measureStarts, defaultTempo: score.metadata.tempo ?? 100, beats: score.beats)
      ..load(_midi?.anchors(start: state.leadIn, totalQuarters: score.timeline.measureStarts.last) ?? state.anchors,
          leadIn: state.leadIn)
      ..addListener(_syncChanged);
    final parts = [for (final p in score.metadata.parts) p.id];
    _curation = Curation(parts)
      ..load(state.lanes ?? Curation.autoCuratedLanes(parts, score.metadata.activeMeasures, score.timeline.measureStarts),
          transition: state.transition ?? defaultTransition);
    _joinLanes();
    _curation!.addListener(_edited);
    _scene = _makeScene(score);
    _history.clear();
    _committed = _editState; // a fresh document: nothing to undo
    anchors._restoreView(view);
    playback.seek(view.time ?? 0);
    viewport.requestFit();
    notifyListeners();
  }

  /// Closes the score (File ▸ Close): stops playback, lets go of the recording and every
  /// edit, and leaves nothing open.
  Future<void> close() async {
    playback.pause();
    await audio.unload();
    _closeDocument();
    playback.time.value = 0;
    notifyListeners();
  }

  /// Lets go of the score and everything edited in it.
  void _closeDocument() {
    _textGeneration++; // a text edit still engraving is for this document: drop it
    _reengraving = false;
    _history.clear();
    _committed = null;
    _gestures = 0;
    anchors._reset();
    lanes._reset();
    _scene?.dispose();
    _scene = null;
    _curation?.removeListener(_edited);
    _curation?.dispose();
    _curation = null;
    _sync?.removeListener(_syncChanged);
    _sync?.dispose();
    _sync = null;
    _midi = null;
    _tapped = const [];
    _score = null;
    _source = null;
    _fileName = null;
    _mediaOriginal = null;
    _partNames = const {};
    _textEdits = const {};
    _condensed = const {};
    _pairs = const [];
    _partOrder = const [];
    _tab = BottomTab.instruments;
  }

  /// The staff transition a newly imported score starts with (Settings ▸ Animation).
  double defaultTransition = 0.3;

  /// How closely the scroll follows the notes, 0–1 (Settings ▸ Animation; see
  /// [ScrollMap.follow]). A view setting, not an edit.
  double get scrollFollow => _scrollFollow;
  double _scrollFollow = 0.4;
  set scrollFollow(double value) {
    if (value == _scrollFollow) return;
    _scrollFollow = value;
    _scene?.scrollFollow = value;
    notifyListeners();
  }

  CuratedScene _makeScene(LoadedScore score) {
    final scene = CuratedScene(score, style: RenderStyle(staffSpace: _staffSpace))
      ..names = _partNames
      ..condensed = _condensed
      ..partOrder = _partOrder
      ..scrollFollow = _scrollFollow;
    if (_sync != null) scene.setTimeline(_sync!);
    return scene;
  }

  // MARK: Editing names and texts

  Map<String, PartName> _partNames = const {};

  String partName(ScorePart part) => _partNames[part.id]?.name ?? part.name;
  String partAbbreviation(ScorePart part) => _partNames[part.id]?.abbreviation ?? part.abbreviation;

  /// Renames an instrument (shown in the name column and the lanes). Empty values fall back
  /// to the names in the file.
  void renamePart(ScorePart part, {required String name, required String abbreviation}) {
    final next = {..._partNames};
    if (name.trim().isEmpty && abbreviation.trim().isEmpty) {
      next.remove(part.id);
    } else {
      next[part.id] = (
        name: name.trim().isEmpty ? part.name : name.trim(),
        abbreviation: abbreviation.trim().isEmpty ? part.abbreviation : abbreviation.trim(),
      );
    }
    _partNames = Map.unmodifiable(next);
    _scene?.names = _partNames;
    _edited();
    notifyListeners();
  }

  /// The score's text edits (text id → new text; '' removes it). The engraving catches up
  /// with them a moment later ([isReengraving]).
  Map<String, String> _textEdits = const {};
  int _textGeneration = 0;
  bool _reengraving = false;

  /// True while a text edit (a new pair of players, new engraving options) is being engraved.
  bool get isReengraving => _reengraving;

  /// The Verovio options scores are engraved with (Settings ▸ Advanced, for every score). Not
  /// an edit: changing them re-engraves what is open, and the project stays as it was.
  EngravingOptions get engravingOptions => _engravingOptions;
  EngravingOptions _engravingOptions = const EngravingOptions();
  set engravingOptions(EngravingOptions value) {
    if (value == _engravingOptions) return;
    _engravingOptions = value;
    if (_score != null) unawaited(_reengrave());
  }

  /// Changes score texts (id → new text; '' removes it; null restores the original) and
  /// re-engraves. Curation and sync are kept: text never changes the bars.
  Future<void> editTexts(Map<String, String?> changes) async {
    final score = _score;
    if (score == null || changes.isEmpty) return;
    final originals = {for (final t in score.texts) t.id: t.text};
    final edits = {..._textEdits};
    for (final MapEntry(:key, :value) in changes.entries) {
      if (value == null || value == originals[key]) {
        edits.remove(key);
      } else {
        edits[key] = value;
      }
    }
    if (mapEquals(edits, _textEdits)) return;
    _textEdits = Map.unmodifiable(edits);
    final engraved = _reengrave();
    _edited(); // one Undo step, right away
    await engraved;
  }

  /// Engraves the score again with the texts and pairs of players edited so far, and the
  /// engraving options. Only the latest request is shown when several overlap (quick Undos).
  Future<void> _reengrave() async {
    final score = _score!;
    final generation = ++_textGeneration;
    _reengraving = true;
    notifyListeners();
    try {
      final edited = await score.withEdits(textEdits: _textEdits, pairs: _pairs, options: _engravingOptions);
      if (generation != _textGeneration) return; // superseded, or another score was opened
      _score = edited;
      _scene?.dispose();
      _scene = _makeScene(edited);
      playback._markDirty();
    } finally {
      if (generation == _textGeneration) {
        _reengraving = false;
        notifyListeners();
      }
    }
  }

  Future<void> editText(String id, String? text) => editTexts({id: text});

  /// The text with [id] as the file has it, and as it is shown now.
  ({ScoreText original, String current})? textById(String id) {
    final text = _score?.texts.where((t) => t.id == id).firstOrNull;
    if (text == null) return null;
    return (original: text, current: currentText(text));
  }

  /// A text as it reads with the edits made so far.
  String currentText(ScoreText text) => _textEdits[text.id] ?? text.text;

  // MARK: Condensing

  Set<String> _condensed = const {};

  /// The pairs of players that can share a staff: the score's own (Flute 1 and 2, Horn 3
  /// and 4…) and those the user made ([pairs]), which win over them. Known at once; the
  /// shared staff of a new pair is engraved a moment later ([isReengraving]).
  List<PlayerPair> get condensable => _score?.condensing.pairs(_pairs) ?? const [];

  /// The pairs the user made (Flute 1 + Oboe 1), in score order.
  List<PlayerPair> get pairs => _pairs;
  List<PlayerPair> _pairs = const [];

  /// The pairs that do: their shared staff is shown while both players are.
  Set<String> get condensed => _condensed;

  /// Who could share a staff with [partId]: single-staff players with the same clefs, keys
  /// and transposition.
  Set<String> partnersOf(String partId) => _score?.condensing.partners[partId] ?? const {};

  /// The pair [partId] belongs to, if it can condense.
  PlayerPair? condensingGroupOf(String partId) => condensable.where((g) => g.contains(partId)).firstOrNull;

  /// Pairs [first] and [second] (who must be [partnersOf] each other) and condenses them:
  /// one Undo step. A pair either was in goes; the score is engraved again (the future
  /// completes when it is).
  Future<void> addPair(String first, String second) async {
    final pair = _score?.condensing.pair(first, second);
    if (pair == null) return;
    if (condensable.contains(pair)) {
      setCondensed([pair.id], on: true);
      return;
    }
    _pairs = List.unmodifiable(
        [for (final p in _pairs) if (!p.contains(pair.first) && !p.contains(pair.second)) p, pair]);
    _condensed = Set.unmodifiable({..._condensed, pair.id});
    await _pairsChanged();
  }

  /// Removes a pair the user made: one Undo step. Built-in pairs it took players from come
  /// back.
  Future<void> removePair(PlayerPair pair) async {
    if (!_pairs.contains(pair)) return;
    _pairs = List.unmodifiable([for (final p in _pairs) if (p != pair) p]);
    _condensed = Set.unmodifiable({..._condensed}..remove(pair.id));
    await _pairsChanged();
  }

  Future<void> _pairsChanged() {
    lanes._clear();
    _joinLanes();
    final engraved = _reengrave();
    _edited(); // one Undo step, right away
    notifyListeners();
    return engraved;
  }

  /// The pair [partId] belongs to, while it is condensed.
  PlayerPair? condensedGroupOf(String partId) {
    final group = condensingGroupOf(partId);
    return group != null && _condensed.contains(group.id) ? group : null;
  }

  /// One lane per instrument, top to bottom as in the preview ([partOrder]), except that a
  /// condensed pair is one lane: its first player's, standing for both (the second's always
  /// holds the same regions).
  List<ScorePart> get laneParts {
    final parts = {for (final p in _score?.metadata.parts ?? const <ScorePart>[]) p.id: p};
    return [
      for (final id in _partOrder)
        if (condensedGroupOf(id)?.partIds.last != id) parts[id]!,
    ];
  }

  // MARK: Instrument order

  List<String> _partOrder = const [];

  /// Every instrument (part id), top to bottom: the score's order unless the user moved some.
  List<String> get partOrder => _partOrder;

  /// Whether the instruments are in the score's own order.
  bool get isScoreOrder => listEquals(_partOrder, [for (final p in _score!.metadata.parts) p.id]);

  /// Moves [partId]'s lane (and its staff) to lane [to] of [laneParts] (0: the top), one
  /// Undo step. A condensed pair moves as one: its second player goes along with the first.
  void moveLane(String partId, int to) => moveLanes([partId], to);

  /// Moves the lanes [partIds] (and their staves), in their order and next to each other, to
  /// just before the [to]th of the other lanes (their count: after the last): one Undo step.
  void moveLanes(Iterable<String> partIds, int to) {
    final lanes = [for (final p in laneParts) p.id];
    final block = [for (final id in lanes) if (partIds.contains(id)) id];
    if (block.isEmpty) return;
    final others = [for (final id in lanes) if (!block.contains(id)) id];
    to = to.clamp(0, others.length);
    final moving = [for (final id in block) ...(condensedGroupOf(id)?.partIds ?? [id])];
    final order = [for (final id in _partOrder) if (!moving.contains(id)) id];
    final at = to < others.length ? order.indexOf(others[to]) : order.length;
    _setPartOrder(order..insertAll(at, moving));
  }

  /// Puts every instrument back in the score's order: one Undo step.
  void restoreScoreOrder() => _setPartOrder(const []);

  void _setPartOrder(List<String> ids) {
    final next = CuratedScene.orderedPartIds(_score!.metadata.parts, ids);
    if (listEquals(next, _partOrder)) return;
    _partOrder = next;
    _scene?.partOrder = next;
    _edited();
    notifyListeners();
  }

  /// A lane's name: the instrument's, or a condensed pair's shared one ("Flute 1.2").
  String laneName(ScorePart part) {
    final group = condensedGroupOf(part.id);
    return group == null ? partName(part) : pairName(group);
  }

  /// A pair's shared name: "Flute 1.2", "Flute 1 + Oboe 1".
  String pairName(PlayerPair pair) => CondensedGroup.nameFor(partNameOf(pair.first), partNameOf(pair.second));

  /// [partName] by part id.
  String partNameOf(String partId) => partName(_score!.metadata.parts.firstWhere((p) => p.id == partId));

  /// Makes each condensed pair's lanes one (see [Curation.join]).
  void _joinLanes() => _curation?.join({
        for (final g in condensable)
          if (_condensed.contains(g.id)) g.second: g.first,
      });

  /// Condenses the pairs [ids] (or stops, with [on] false): one Undo step. Nothing is
  /// engraved again; the shared staves are always there. A condensed pair is one lane,
  /// shown wherever either player was.
  void setCondensed(Iterable<String> ids, {required bool on}) {
    final next = {..._condensed};
    for (final id in ids) {
      if (!condensable.any((g) => g.id == id)) continue;
      on ? next.add(id) : next.remove(id);
    }
    if (setEquals(next, _condensed)) return;
    _condensed = Set.unmodifiable(next);
    _scene?.condensed = _condensed;
    lanes._clear();
    _joinLanes();
    _edited();
    notifyListeners();
  }

  /// Seconds for a staff to glide in or out, in this project.
  void setTransition(double seconds) => _curation?.transition = seconds;

  void _syncChanged() {
    _scene?.setTimeline(_sync!);
    _edited();
    notifyListeners();
  }

  /// The score's size. While [dragging] (the slider) only the view follows; the project
  /// counts it as one change when the drag ends.
  void setStaffSpace(double value, {bool dragging = false}) {
    value = value.clamp(minStaffSpace, maxStaffSpace);
    if (value != _staffSpace) {
      _staffSpace = value;
      _scene?.setStaffSpace(value);
      _staffSpaceChanged = true;
      playback._markDirty();
      notifyListeners();
    }
    if (!dragging && _staffSpaceChanged) {
      _staffSpaceChanged = false;
      _edited();
    }
  }

  bool _staffSpaceChanged = false;

  // MARK: MIDI tempo map

  MidiTempoMap? _midi;

  /// The anchors tapped (or set) by hand, kept while a MIDI tempo map stands in for them.
  List<SyncAnchor> _tapped = const [];

  /// The MIDI file whose tempo map the sync follows, instead of anchors set by hand.
  MidiTempoMap? get midiTempo => _midi;

  /// Whether the sync follows a MIDI tempo map: its anchors are then derived, and tapping and
  /// editing them is off (the Audio tab shows the tempo map instead of the waveform).
  bool get usesMidiTempo => _midi != null;

  /// The anchors set by hand, whether in use or kept behind a MIDI tempo map.
  List<SyncAnchor> get _ownAnchors => _midi == null ? _sync!.anchors : _tapped;

  /// Reads the tempo map of the MIDI file at [path] and follows it ([useMidiTempo]). Throws
  /// a [FormatException] (changing nothing) when it isn't a MIDI file with a tempo map.
  Future<void> loadMidiTempo(String path) async {
    final map = MidiTempoMap.read(await File(path).readAsBytes(), name: path.split(RegExp(r'[/\\]')).last);
    if (_sync == null) return;
    useMidiTempo(map);
    _tab = BottomTab.audio;
    notifyListeners();
  }

  /// Makes the sync follow [map] (null: the anchors set by hand again, as they were): one
  /// Undo step. The file's start sounds where bar 1 does now (Starts at).
  void useMidiTempo(MidiTempoMap? map) {
    final sync = _sync;
    if (sync == null || map == _midi) return;
    final start = sync.startSeconds;
    if (_midi == null) _tapped = sync.anchors;
    final own = _tapped;
    _midi = map;
    anchors._reset();
    if (map == null) {
      _tapped = const [];
      sync.load(own, leadIn: sync.leadIn);
    } else {
      _followMidi(start);
    }
    notifyListeners();
  }

  /// Puts the derived anchors of the MIDI tempo map in the sync, with its start at [start].
  void _followMidi(double start) {
    start = math.max(0, start);
    _sync!.load(_midi!.anchors(start: start, totalQuarters: _sync!.totalQuarters), leadIn: start);
  }

  // MARK: Audio

  final audio = AudioEngine();
  bool _loadingAudio = false;
  bool get isLoadingAudio => _loadingAudio;
  AudioTrack? get track => audio.track;

  /// The recording's own file, when it has one (what a project links to). A recording
  /// unpacked from a project or copied from the app bundle has none.
  String? get mediaOriginal => _mediaOriginal;
  String? _mediaOriginal;

  /// Loads the recording from [path]. A [temporary] copy (unpacked or bundled) is not the
  /// recording's own file; [originalPath] then says where that is, if known.
  ///
  /// A video's soundtrack becomes the track (and so what a project embeds), while the video
  /// stays the recording's own file (what a project links to).
  Future<void> loadAudio(String path, {bool temporary = false, String? originalPath}) async {
    playback.pause();
    _loadingAudio = true;
    notifyListeners();
    try {
      await audio.load(path);
      _mediaOriginal = temporary ? originalPath : path;
      _edited();
      _tab = BottomTab.audio;
      viewport.requestFit();
    } finally {
      _loadingAudio = false;
      notifyListeners();
    }
  }

  // MARK: Selection and Undo (both tabs)

  /// Nothing selected in either tab.
  void clearSelection() {
    if (lanes._selected.isEmpty && lanes._lanes.isEmpty && anchors._selected.isEmpty) return;
    lanes._clear();
    anchors._selected = {};
    notifyListeners();
  }

  /// Delete: removes what is selected in the tab that is showing.
  void deleteSelection() => _tab == BottomTab.audio ? anchors.delete() : lanes.delete();

  // One history for the whole document: lanes, sync, names, texts, condensing, the instruments'
  // order and the transition. After
  // every change the document's state is compared with the last one recorded; a difference
  // is one Undo step. A gesture (a drag) records only when it ends.

  final _history = EditHistory();

  /// The state as of the last Undo step (what Undo returns to from the next edit).
  EditState? _committed;
  int _gestures = 0;
  bool _restoring = false;

  EditState get _editState => EditState(
        lanes: _curation!.lanes,
        transition: _curation!.transition,
        anchors: _ownAnchors,
        leadIn: _sync!.leadIn,
        midi: _midi,
        partNames: _partNames,
        textEdits: _textEdits,
        condensed: _condensed,
        pairs: _pairs,
        partOrder: _partOrder,
      );

  /// How many steps Undo can go back.
  int get undoLimit => _history.limit;
  set undoLimit(int value) {
    _history.limit = value;
    notifyListeners();
  }

  bool get canUndo => _history.canUndo;
  bool get canRedo => _history.canRedo;

  /// Starts a gesture (a drag): everything it changes becomes one Undo step at [endEdit].
  void beginEdit() => _gestures++;

  /// Ends a gesture: merges what it left overlapping, and records it.
  void endEdit() {
    if (_gestures == 0) return;
    _gestures--;
    _curation?.normalize();
    _record();
  }

  void _record() {
    if (_restoring || _gestures > 0 || _score == null) return;
    final now = _editState, before = _committed;
    if (before == null || now == before) return;
    _history.record(before);
    _committed = now;
    notifyListeners();
  }

  // Nothing open (⌘Z on the start screen) has no state to step from.
  void undo() {
    if (_score != null) _restore(_history.undo(_editState));
  }

  void redo() {
    if (_score != null) _restore(_history.redo(_editState));
  }

  void _restore(EditState? state) {
    if (state == null || _score == null) return;
    _restoring = true;
    try {
      final reengrave = !mapEquals(state.textEdits, _textEdits) || !listEquals(state.pairs, _pairs);
      _textEdits = state.textEdits;
      _pairs = state.pairs;
      _condensed = state.condensed;
      _scene?.condensed = _condensed;
      if (reengrave) unawaited(_reengrave());
      _joinLanes(); // before the lanes, which fit it
      _curation!.load(state.lanes, transition: state.transition);
      _midi = state.midi;
      _tapped = state.midi != null ? state.anchors : const [];
      _sync!.load(_midi?.anchors(start: state.leadIn, totalQuarters: _sync!.totalQuarters) ?? state.anchors,
          leadIn: state.leadIn);
      _partNames = state.partNames;
      _scene?.names = _partNames;
      _partOrder = state.partOrder;
      _scene?.partOrder = _partOrder;
    } finally {
      _restoring = false;
    }
    _committed = state;
    lanes._clear();
    anchors._selected = {};
    _edited();
    notifyListeners();
  }

  // MARK: Projects

  /// Increases with every change that a project saves (not with playback, zoom or selection).
  final editRevision = ValueNotifier<int>(0);

  void _edited() {
    editRevision.value++;
    playback._markDirty();
    _record();
  }

  /// Every edit made in the app, and the view: what a project stores next to the source score.
  ProjectState get projectState => ProjectState(
        lanes: _curation!.lanes,
        transition: _curation!.transition,
        anchors: _ownAnchors,
        leadIn: _sync!.leadIn,
        midi: _midi,
        partNames: _partNames,
        textEdits: _textEdits,
        condensed: _condensed,
        pairs: _pairs,
        partOrder: isScoreOrder ? const [] : _partOrder,
        view: ViewState(
          staffSpace: _staffSpace,
          grid: anchors.grid,
          snapTapsToOnsets: anchors.snapToOnsets,
          time: playback.time.value,
        ),
      );

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _textGeneration++; // an engraving still running finds nothing to update
    playback._dispose();
    _scene?.dispose();
    _curation?.dispose();
    _sync?.dispose();
    unawaited(audio.unload());
    editRevision.dispose();
    viewport.dispose();
    super.dispose();
  }
}
