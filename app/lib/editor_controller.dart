import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:score_engine/score_engine.dart';

import 'audio_track.dart';
import 'edit_history.dart';
import 'error_text.dart';
import 'file_names.dart';
import 'image_patch.dart';
import 'latest.dart';
import 'project_state.dart';
import 'score_replacement.dart';
import 'time_viewport.dart';

part 'editor/caption_editing.dart';
part 'editor/commands.dart';
part 'editor/image_editing.dart';
part 'editor/lane_editing.dart';
part 'editor/playback.dart';
part 'editor/sync_editing.dart';

enum BottomTab { instruments, audio }

/// Where a MIDI tempo map just read took its warps from ([EditorController.loadMidiTempo]):
/// the file it replaced, the anchors set by hand, or the score's repeats.
enum MidiWarpsFrom { file, anchors, score }

/// The warps a MIDI tempo map just read took: from where, how many, and the file it replaced
/// (with [MidiWarpsFrom.file]).
typedef MidiWarpsTaken = ({MidiWarpsFrom from, int count, String? file});

/// The open score and everything done to it: the engraving, the recording, the curation
/// (when each instrument is shown), the sync (where the score sits in the recording), names
/// and texts. Loading, saving state and Undo (one history for all of it) live here; the rest
/// is split by job:
///
///  * [playback]: the clock, play / pause / seek;
///  * [lanes]: editing in the Instruments tab (tools, the region selection, tidying);
///  * [anchors]: editing in the Audio tab (tapping, the anchor selection);
///  * [images]: images on the score (the Attach Image extension);
///  * [captions]: captions under the score (the Captions extension);
///  * [commands]: what the Edit menu and the keys do in the tab showing.
///
/// All of them notify through this controller, so a widget listens to one thing.
class EditorController extends ChangeNotifier {
  EditorController({required TickerProvider vsync}) {
    playback = Playback._(this, vsync);
  }

  late final Playback playback;
  late final lanes = LaneEditing._(this);
  late final anchors = SyncEditing._(this);
  late final images = ImageEditing._(this);
  late final captions = CaptionEditing._(this);
  late final commands = EditCommands._(this);

  /// Zoom and scroll shared by both tabs of the bottom panel.
  final viewport = TimeViewport();

  LoadedScore? _score;

  /// The edits the controller keeps itself: names, texts, pairs of players and condensing, the
  /// instruments' order, fonts, engraving options, and the MIDI tempo map (with the anchors set
  /// by hand kept behind it, as its anchors). The rest of a project's edits live in their models
  /// (the curation, the sync, the images, the captions); [_editState] takes them from there, so
  /// this state's own copies of those are never read.
  EditState _doc = const EditState();
  CuratedScene? _scene;
  Curation? _curation;
  SyncMap? _sync;
  String? _fileName;
  bool _loading = false;
  double _staffSpace = 9;

  LoadedScore? get score => _score;
  CuratedScene? get scene {
    _applyTimeline();
    return _scene;
  }

  /// The sync changed since the scene last followed it: an anchor dragged changes it at every
  /// move, and the scene follows once, when next asked (painting, once a frame).
  bool _timelineStale = false;

  void _applyTimeline() {
    if (!_timelineStale) return;
    _timelineStale = false;
    if (_sync case final sync?) _scene?.setTimeline(sync);
  }

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

  /// For the parts ([Playback], [LaneEditing], [SyncEditing], [ImageEditing], [CaptionEditing]), which can't
  /// call the protected [notifyListeners] themselves.
  void _changed() => notifyListeners();

  // MARK: Loading

  /// The score file as opened, byte for byte: projects keep it so the source is never lost.
  ({String name, Uint8List bytes})? get source => _source;
  ({String name, Uint8List bytes})? _source;

  /// Opens (imports) a score file: MusicXML, or compressed .mxl. If it can't be read, what
  /// was open stays open.
  Future<void> openFile(String path) async {
    final bytes = await File(path).readAsBytes();
    var edits = await _newProjectEdits();
    LoadedScore score;
    try {
      score = await _engrave(ScoreFile.decodeMusicXML(bytes), _requestFor(edits));
    } on FormatException {
      if (edits.fonts == ScoreFonts.standard) rethrow;
      edits = edits.copyWith(fonts: ScoreFonts.standard); // a default font that can't be read: the standard ones
      score = await _engrave(ScoreFile.decodeMusicXML(bytes), _requestFor(edits));
    }
    await _install(fileNameOf(path), bytes, score, ProjectState(edits: edits));
  }

  /// The fonts a newly imported score starts with (Settings ▸ Fonts), by name.
  ({String music, String text, bool embed}) newProjectFonts =
      (music: MusicFont.bravura.name, text: TextFonts.academico, embed: true);

  /// [newProjectFonts] as found here: one not installed is Bravura or Academico.
  Future<EditState> _newProjectEdits() async {
    final wanted = newProjectFonts;
    final music = await findInstalledMusicFont(wanted.music) ?? MusicFont.bravura;
    final text = wanted.text == TextFonts.academico || await TextFonts.faces(wanted.text) != null ? wanted.text : TextFonts.academico;
    return EditState(fonts: ScoreFonts(music: music, text: text), embedFont: wanted.embed);
  }

  /// The music font installed here as [name]; null when there is none, or it can't be read
  /// (Bravura stands in, as for one not installed).
  Future<MusicFont?> findInstalledMusicFont(String name) async {
    try {
      return await lookUpMusicFont(name);
    } on Exception {
      return null;
    }
  }

  /// How [findInstalledMusicFont] reads one: a test's stands in for a damaged font.
  @visibleForTesting
  Future<MusicFont?> Function(String name) lookUpMusicFont = MusicFont.findInstalled;

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
    var edits = state.edits;
    // A font the project only names is looked for here; not found, Bravura stands in.
    if (edits.fonts.music.isMissing) {
      if (await findInstalledMusicFont(edits.fonts.music.name) case final found?) {
        edits = edits.copyWith(fonts: edits.fonts.copyWith(music: found));
        state = ProjectState(edits: edits, images: state.images, view: state.view);
      }
    }
    final score = await _engrave(ScoreFile.decodeMusicXML(scoreBytes), _requestFor(edits));
    final arts = await ImageEditing._decodeAll(state.images);
    await _install(name, scoreBytes, score, state, arts: arts);
    if (mediaPath == null || _disposed) return null; // nothing to play it in: the window closed
    try {
      await loadAudio(mediaPath, temporary: true, originalPath: mediaOriginal);
      return null;
    } catch (e) {
      return 'Couldn’t load the recording.\n${describeError(e)}';
    } finally {
      _tab = BottomTab.instruments;
      notifyListeners();
    }
  }

  /// Score ▸ Replace Score…: engraves the score file at [path] with this project's edits
  /// carried over to it ([ScoreSwap]), and says what differs. Nothing changes until
  /// [replaceScore].
  Future<ScoreReplacement> prepareReplacement(String path) async {
    final before = _score!;
    final bytes = await File(path).readAsBytes();
    // Read once for what it holds (its texts as written: the edits are carried by them), and
    // once more as engraved.
    final xml = ScoreFile.decodeMusicXML(bytes), doc = ScoreMetadata.parse(xml);
    final metadata = ScoreMetadata.fromDocument(doc);
    final swap = ScoreSwap(
      before: before.metadata,
      after: metadata,
      textsBefore: before.texts,
      textsAfter: PreparedScore.prepare(doc, const {}, metadata: metadata).texts,
    );
    final score =
        await _engrave(xml, _requestFor(_editState.copyWith(textEdits: swap.textEdits(_doc.textEdits), pairs: swap.pairs(_doc.pairs))));
    if (_score != before) throw StateError('Another score was opened meanwhile.');
    final state = projectState;
    final measures = (before: before.timeline.measureStarts, after: score.timeline.measureStarts);
    final (state: carried, :lost) =
        swap.carry(state, condensable: condensable, measuresBefore: measures.before, measuresAfter: measures.after);
    return ScoreReplacement(
      name: fileNameOf(path),
      bytes: bytes,
      score: score,
      state: carried,
      differences: swap.differences(
          measuresBefore: measures.before, measuresAfter: measures.after, edits: _doc.textEdits, lost: lost),
      replacing: before,
    );
  }

  /// Puts [replacement] in place of the score, keeping the recording; Undo starts again from
  /// here. Does nothing if another score was opened since it was made.
  Future<void> replaceScore(ScoreReplacement replacement) async {
    if (replacement.replacing != _score) return;
    final arts = await ImageEditing._decodeAll(replacement.state.images);
    if (replacement.replacing != _score) return arts.values.forEach(ImageEditing._dispose);
    await _install(replacement.name, replacement.bytes, replacement.score, replacement.state,
        arts: arts, keepRecording: true);
    _edited(); // unsaved
  }

  /// Engraves a score (the slow part, and the one that can fail) without touching what is open.
  Future<LoadedScore> _engrave(String musicXML, EngraveRequest request) async {
    _loading = true;
    notifyListeners();
    try {
      return await LoadedScore.engrave(musicXML, request);
    } finally {
      _loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Replaces what is open with [score] and the edits and view in [state], all at once
  /// (the recording too, unless [keepRecording]). Nothing in here fails, so a project is
  /// never left half open.
  Future<void> _install(String name, Uint8List bytes, LoadedScore score, ProjectState state,
      {Map<String, PatchArt> arts = const {}, bool keepRecording = false}) async {
    if (_disposed) return arts.values.forEach(ImageEditing._dispose); // the window closed while engraving
    playback.pause();
    final mediaOriginal = _mediaOriginal, tab = _tab;
    if (!keepRecording) await audio.unload();
    _closeDocument();
    if (keepRecording) {
      _mediaOriginal = mediaOriginal;
      _tab = tab;
    }
    final edits = state.edits, view = state.view;
    _score = score;
    _source = (name: name, bytes: bytes);
    _fileName = name;
    _staffSpace = (view.staffSpace ?? _staffSpace).clamp(minStaffSpace, maxStaffSpace);
    _doc = edits.copyWith(
      partNames: Map.unmodifiable(edits.partNames),
      textEdits: Map.unmodifiable(edits.textEdits),
      pairs: List.unmodifiable({for (final p in edits.pairs) ?score.condensing.pair(p.first, p.second)}),
      partOrder: CuratedScene.orderedPartIds(score.metadata.parts, edits.partOrder),
    );
    // The pairs that can condense follow the score and the pairs just taken on.
    _doc = _doc.copyWith(condensed: Set.unmodifiable({for (final g in condensable) if (edits.condensed.contains(g.id)) g.id}));
    if (_doc.fonts.music case final music when music.isAdded && !_addedFonts.contains(music)) _addedFonts = [..._addedFonts, music];
    images._load(edits.patches, state.images, arts);
    _sync = SyncMap(measureStarts: score.timeline.measureStarts, defaultTempo: score.metadata.tempo ?? 100, beats: score.beats)
      ..load(_doc.midi?.anchors(start: edits.leadIn, totalQuarters: score.timeline.measureStarts.last) ?? edits.anchors,
          leadIn: edits.leadIn)
      ..addListener(_syncChanged);
    final parts = [for (final p in score.metadata.parts) p.id];
    _curation = Curation(parts)
      ..load(edits.lanes ?? Curation.autoCuratedLanes(parts, score.metadata.activeMeasures, score.timeline.measureStarts),
          transition: edits.transition ?? defaultTransition);
    _joinLanes();
    _curation!.addListener(_curationEdited);
    _scene = _makeScene(score);
    // Last: working out their style can notify at once, and listeners must find all of it open.
    captions._load(edits.captions, edits.captionFont);
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
    _engravings.cancel(); // an edit still engraving is for this document: drop it
    _reengraving = false;
    engravingFailure.value = null;
    _history.clear();
    _committed = null;
    _gestures = 0;
    anchors._reset();
    lanes._reset();
    images._reset();
    captions._reset();
    _scene?.dispose();
    _scene = null;
    _curation?.removeListener(_curationEdited);
    _curation?.dispose();
    _curation = null;
    _sync?.removeListener(_syncChanged);
    _sync?.dispose();
    _sync = null;
    _score = null;
    _source = null;
    _fileName = null;
    _mediaOriginal = null;
    _doc = const EditState();
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
    _showSettings();
    playback._markDirty(); // only the score shows it: nothing to rebuild
  }

  CuratedScene _makeScene(LoadedScore score) {
    final scene = CuratedScene(score, style: RenderStyle(staffSpace: _staffSpace))..settings = sceneSettings;
    if (_sync != null) scene.setTimeline(_sync!);
    return scene;
  }

  /// What the scene shows besides the score, the time, the curation and the sync: the names,
  /// condensing, order, scroll, and the extensions' images and captions (none while off).
  SceneSettings get sceneSettings => SceneSettings(
      names: _doc.partNames,
      condensed: _doc.condensed,
      partOrder: _doc.partOrder,
      scrollFollow: _scrollFollow,
      patches: images._scenePatches,
      captions: captions._sceneCaptions,
      captionStyle: captions._style);

  /// Gives the scene [sceneSettings] again, after a change of any of them.
  void _showSettings() => _scene?.settings = sceneSettings;

  // MARK: Editing names and texts

  String partName(ScorePart part) => _doc.partNames[part.id]?.name ?? part.name;
  String partAbbreviation(ScorePart part) => _doc.partNames[part.id]?.abbreviation ?? part.abbreviation;

  /// Renames an instrument (shown in the name column and the lanes). Empty values fall back
  /// to the names in the file.
  void renamePart(ScorePart part, {required String name, required String abbreviation}) {
    final next = {..._doc.partNames};
    if (name.trim().isEmpty && abbreviation.trim().isEmpty) {
      next.remove(part.id);
    } else {
      next[part.id] = (
        name: name.trim().isEmpty ? part.name : name.trim(),
        abbreviation: abbreviation.trim().isEmpty ? part.abbreviation : abbreviation.trim(),
      );
    }
    _doc = _doc.copyWith(partNames: Map.unmodifiable(next));
    _showSettings();
    _edited();
  }

  /// The latest engraving asked for (a text edit, a pair, fonts or options changed): the one
  /// whose result is shown.
  final _engravings = Latest();
  bool _reengraving = false;

  /// True while a text edit (a new pair of players, new engraving options, new fonts) is being
  /// engraved, fonts being got ready included.
  bool get isReengraving => _reengraving || _preparingFonts > 0;
  int _preparingFonts = 0;

  /// The Verovio options scores are engraved with (Settings ▸ Engraving, for every project; under [projectEngraving]). Not
  /// an edit: changing them re-engraves what is open, and the project stays as it was.
  EngravingOptions get engravingOptions => _engravingOptions;
  EngravingOptions _engravingOptions = const EngravingOptions();
  set engravingOptions(EngravingOptions value) {
    if (value == _engravingOptions) return;
    _engravingOptions = value;
    if (_score != null) unawaited(_reengrave());
  }

  /// Whether dynamics written as text ("f" in a music font) are engraved as dynamics
  /// (Settings ▸ Flags, [TextDynamics]). Not an edit: changing it re-engraves what is open.
  bool get textDynamics => _textDynamics;
  bool _textDynamics = true;
  set textDynamics(bool value) {
    if (value == _textDynamics) return;
    _textDynamics = value;
    if (_score != null) unawaited(_reengrave());
  }

  /// The options this project sets over [engravingOptions] (Project Settings ▸ Engraving):
  /// an edit, saved with the project.
  EngravingOptions get projectEngraving => _doc.engraving;

  /// Engraves the score with [options] over the app's: one Undo step. The future completes
  /// when it is engraved.
  Future<void> setProjectEngraving(EngravingOptions options) async {
    if (_score == null || options == _doc.engraving) return;
    _doc = _doc.copyWith(engraving: options);
    final engraved = _reengrave();
    _edited(); // one Undo step, right away
    await engraved;
  }

  /// Changes score texts (id → new text; '' removes it; null restores the original) and
  /// re-engraves. Curation and sync are kept: text never changes the bars.
  Future<void> editTexts(Map<String, String?> changes) async {
    final score = _score;
    if (score == null || changes.isEmpty) return;
    final originals = {for (final t in score.texts) t.id: t.text};
    final edits = {..._doc.textEdits};
    for (final MapEntry(:key, :value) in changes.entries) {
      if (value == null || value == originals[key]) {
        edits.remove(key);
      } else {
        edits[key] = value;
      }
    }
    if (mapEquals(edits, _doc.textEdits)) return;
    _doc = _doc.copyWith(textEdits: Map.unmodifiable(edits));
    final engraved = _reengrave();
    _edited(); // one Undo step, right away
    await engraved;
  }

  /// Engraves the score again with the texts and pairs of players edited so far, and the
  /// engraving options. Only the latest request is shown when several overlap (quick Undos).
  ///
  /// Never throws: a failure leaves the score as it was engraved before and is told through
  /// [engravingFailure] (several callers don't wait for it, Undo and the engraving options).
  Future<void> _reengrave() async {
    final score = _score!;
    final turn = _engravings.start();
    _reengraving = true;
    notifyListeners();
    try {
      final edited = await engraveAgain(score);
      if (!turn.isLatest) return; // superseded, or another score was opened
      _score = edited;
      _scene?.dispose();
      _scene = _makeScene(edited);
      playback._markDirty();
      engravingFailure.value = null;
    } catch (e) {
      if (turn.isLatest && !_disposed) engravingFailure.value = e;
    } finally {
      if (turn.isLatest) {
        _reengraving = false;
        notifyListeners();
      }
    }
  }

  /// [score] engraved with the edits made so far and the engraving options ([_wanted]).
  @protected
  @visibleForTesting
  Future<LoadedScore> engraveAgain(LoadedScore score) => score.withRequest(_wanted);

  /// What a score with [edits] is engraved with: their texts, pairs of players, fonts and
  /// engraving options (over the app's), and the app's flags.
  EngraveRequest _requestFor(EditState edits) => EngraveRequest(
      textEdits: edits.textEdits,
      pairs: edits.pairs,
      fonts: edits.fonts,
      options: edits.engraving.over(_engravingOptions),
      textDynamics: _textDynamics);

  /// What the score is to be engraved with now (an engraving may still be catching up).
  EngraveRequest get _wanted =>
      _requestFor(_doc);

  /// Why the latest re-engraving failed, the score showing as it was before; null once one
  /// succeeds. Undo can step back from the edit that caused it.
  final engravingFailure = ValueNotifier<Object?>(null);

  Future<void> editText(String id, String? text) => editTexts({id: text});

  /// The text with [id] as the file has it, and as it is shown now.
  ({ScoreText original, String current})? textById(String id) {
    final text = _score?.texts.where((t) => t.id == id).firstOrNull;
    if (text == null) return null;
    return (original: text, current: currentText(text));
  }

  /// A text as it reads with the edits made so far.
  String currentText(ScoreText text) => _doc.textEdits[text.id] ?? text.text;

  // MARK: Fonts

  /// The music and text fonts the score is engraved in (Project Settings ▸ Fonts). The engraving
  /// catches up a moment later ([isReengraving]).
  ScoreFonts get fonts => _doc.fonts;

  /// Music fonts the user added in this session, or that came with a project: offered beside
  /// the bundled ones.
  List<MusicFont> get addedFonts => _addedFonts;
  List<MusicFont> _addedFonts = const [];

  /// Engraves the score in [fonts]: one Undo step. The future completes when it is engraved.
  /// A font that can't be read throws, and changes nothing: a project never keeps a font it
  /// couldn't be engraved in (it would not open again).
  ///
  /// With [embed], whether the font is embedded is set too, in the same step.
  Future<void> setFonts(ScoreFonts fonts, {bool? embed}) async {
    final score = _score;
    if (score == null) return;
    if (fonts == _doc.fonts) {
      if (embed != null) embedFont = embed;
      return;
    }
    _preparingFonts++;
    notifyListeners();
    try {
      await LoadedScore.prepareFonts(fonts);
    } finally {
      _preparingFonts--;
      if (!_disposed) notifyListeners();
    }
    if (_score != score || fonts == _doc.fonts) return; // closed, or another score opened, meanwhile
    if (fonts.music.isAdded && !_addedFonts.contains(fonts.music)) _addedFonts = [..._addedFonts, fonts.music];
    _doc = _doc.copyWith(fonts: fonts, embedFont: embed);
    if (!canEmbedFont) _doc = _doc.copyWith(embedFont: false); // as it will be saved
    final engraved = _reengrave();
    _edited(); // one Undo step, right away
    await engraved;
  }

  /// Whether an added music font is saved inside the project (Project Settings ▸ Fonts): an
  /// edit. Off, only its name is saved and the font is looked for where the project opens.
  /// A missing font has nothing to embed: it can't be switched on ([canEmbedFont]).
  bool get embedFont => _doc.embedFont;

  bool get canEmbedFont => !_doc.fonts.music.isMissing;

  set embedFont(bool value) {
    if (value == _doc.embedFont || _score == null || (value && !canEmbedFont)) return;
    _doc = _doc.copyWith(embedFont: value);
    _edited();
  }

  // MARK: Condensing

  /// The pairs of players that can share a staff: the score's own (Flute 1 and 2, Horn 3
  /// and 4…) and those the user made ([pairs]), which win over them. Known at once; the
  /// shared staff of a new pair is engraved a moment later ([isReengraving]).
  ///
  /// Worked out once for each score and [pairs] (both are replaced, never changed): the lanes
  /// ask for every instrument at every paint, through [condensedGroupOf] and [laneParts].
  List<PlayerPair> get condensable {
    final score = _score;
    if (score == null) return const [];
    if (_condensable case (final s, final p, final pairs) when identical(s, score) && identical(p, _doc.pairs)) return pairs;
    final pairs = List<PlayerPair>.unmodifiable(score.condensing.pairs(_doc.pairs));
    _condensable = (score, _doc.pairs, pairs);
    return pairs;
  }

  (LoadedScore, List<PlayerPair>, List<PlayerPair>)? _condensable;

  /// The pairs the user made (Flute 1 + Oboe 1), in score order.
  List<PlayerPair> get pairs => _doc.pairs;

  /// The pairs that do: their shared staff is shown while both players are.
  Set<String> get condensed => _doc.condensed;

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
    _doc = _doc.copyWith(
      pairs: List.unmodifiable([for (final p in _doc.pairs) if (!p.contains(pair.first) && !p.contains(pair.second)) p, pair]),
      condensed: Set.unmodifiable({..._doc.condensed, pair.id}),
    );
    await _pairsChanged();
  }

  /// Removes a pair the user made: one Undo step. Built-in pairs it took players from come
  /// back.
  Future<void> removePair(PlayerPair pair) async {
    if (!_doc.pairs.contains(pair)) return;
    _doc = _doc.copyWith(
      pairs: List.unmodifiable([for (final p in _doc.pairs) if (p != pair) p]),
      condensed: Set.unmodifiable({..._doc.condensed}..remove(pair.id)),
    );
    await _pairsChanged();
  }

  Future<void> _pairsChanged() {
    lanes._clear();
    _joinLanes();
    final engraved = _reengrave();
    _edited(); // one Undo step, right away
    return engraved;
  }

  /// The pair [partId] belongs to, while it is condensed.
  PlayerPair? condensedGroupOf(String partId) {
    final group = condensingGroupOf(partId);
    return group != null && _doc.condensed.contains(group.id) ? group : null;
  }

  /// One lane per instrument, top to bottom as in the preview ([partOrder]), except that a
  /// condensed pair is one lane: its first player's, standing for both (the second's always
  /// holds the same regions).
  ///
  /// Worked out again only when the score, the order, the pairs or what is condensed is
  /// replaced (none is ever changed in place): the lanes read it for every lane they paint.
  List<ScorePart> get laneParts {
    final key = (_score, _doc.partOrder, _doc.condensed, condensable);
    if (_laneParts case (final k, final lanes) when identical(k.$1, key.$1) && identical(k.$2, key.$2) &&
        identical(k.$3, key.$3) && identical(k.$4, key.$4)) {
      return lanes;
    }
    final parts = {for (final p in _score?.metadata.parts ?? const <ScorePart>[]) p.id: p};
    final lanes = List<ScorePart>.unmodifiable([
      for (final id in _doc.partOrder)
        if (condensedGroupOf(id)?.partIds.last != id) parts[id]!,
    ]);
    _laneParts = (key, lanes);
    return lanes;
  }

  ((LoadedScore?, List<String>, Set<String>, List<PlayerPair>), List<ScorePart>)? _laneParts;

  // MARK: Instrument order

  /// Every instrument (part id), top to bottom: the score's order unless the user moved some.
  List<String> get partOrder => _doc.partOrder;

  /// Whether the instruments are in the score's own order.
  bool get isScoreOrder => listEquals(_doc.partOrder, [for (final p in _score!.metadata.parts) p.id]);

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
    final order = [for (final id in _doc.partOrder) if (!moving.contains(id)) id];
    final at = to < others.length ? order.indexOf(others[to]) : order.length;
    _setPartOrder(order..insertAll(at, moving));
  }

  /// Puts every instrument back in the score's order: one Undo step.
  void restoreScoreOrder() => _setPartOrder(const []);

  void _setPartOrder(List<String> ids) {
    final next = CuratedScene.orderedPartIds(_score!.metadata.parts, ids);
    if (listEquals(next, _doc.partOrder)) return;
    _doc = _doc.copyWith(partOrder: next);
    _showSettings();
    _edited();
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
          if (_doc.condensed.contains(g.id)) g.second: g.first,
      });

  /// Condenses the pairs [ids] (or stops, with [on] false): one Undo step. Nothing is
  /// engraved again; the shared staves are always there. A condensed pair is one lane,
  /// shown wherever either player was.
  void setCondensed(Iterable<String> ids, {required bool on}) {
    final next = {..._doc.condensed};
    for (final id in ids) {
      if (!condensable.any((g) => g.id == id)) continue;
      on ? next.add(id) : next.remove(id);
    }
    if (setEquals(next, _doc.condensed)) return;
    _doc = _doc.copyWith(condensed: Set.unmodifiable(next));
    _showSettings();
    lanes._clear();
    _joinLanes();
    _edited();
  }

  /// Seconds for a staff to glide in or out, in this project.
  void setTransition(double seconds) => _curation?.transition = seconds;

  void _syncChanged() {
    _timelineStale = true;
    _edited();
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


  /// The MIDI file whose tempo map the sync follows, instead of anchors set by hand.
  MidiTempoMap? get midiTempo => _doc.midi;

  /// Whether the sync follows a MIDI tempo map: its anchors are then derived, and tapping and
  /// editing them is off (the Audio tab shows the tempo map, edited instead, see [editMidiTempo]).
  bool get usesMidiTempo => _doc.midi != null;

  /// The anchors set by hand, whether in use or kept behind a MIDI tempo map.
  List<SyncAnchor> get _ownAnchors => _doc.midi == null ? _sync!.anchors : _doc.anchors;

  /// Reads the tempo map of the MIDI file at [path] and follows it ([useMidiTempo]). Throws
  /// a [FormatException] (changing nothing) when it isn't a MIDI file with a tempo map. It
  /// keeps the warps the sync has (see [MidiTempoMap.warps]); with none, a file as long as the
  /// score played with its repeats gets the score's ([scoreWarps]). Returns where the warps
  /// came from, so the window can say so: null when it has none.
  Future<MidiWarpsTaken?> loadMidiTempo(String path) async {
    final bytes = await File(path).readAsBytes();
    final read = MidiTempoMap.read(bytes, name: fileNameOf(path));
    final sync = _sync;
    if (sync == null) return null;
    // The score's form stays: the warps of the file it replaces, or those set by hand.
    final replaced = _doc.midi;
    final kept = replaced?.warps ?? MidiTempoMap.warpsOf(sync.anchors);
    final MidiWarpsTaken? taken = kept.isNotEmpty
        ? (from: replaced == null ? MidiWarpsFrom.anchors : MidiWarpsFrom.file, count: kept.length, file: replaced?.name)
        : _playsRepeats(MidiTempoMap.lengthOf(bytes))
            ? (from: MidiWarpsFrom.score, count: scoreWarps.length, file: null)
            : null;
    useMidiTempo(read.withWarps(switch (taken?.from) { MidiWarpsFrom.score => scoreWarps, _ => kept }));
    _tab = BottomTab.audio;
    notifyListeners();
    return taken;
  }

  /// The warps a MIDI file playing the score's repeats, endings and jumps needs (none when it
  /// is played straight through).
  List<MidiWarp> get scoreWarps {
    final score = _score;
    return score == null ? const [] : score.metadata.form.warps(score.timeline.measureStarts);
  }

  /// Whether a MIDI file [quarters] long is nearer the score played with its repeats than
  /// straight through.
  bool _playsRepeats(double quarters) {
    final score = _score;
    if (score == null || scoreWarps.isEmpty) return false;
    final starts = score.timeline.measureStarts;
    return (quarters - score.metadata.form.playedQuarters(starts)).abs() < (quarters - starts.last).abs();
  }

  /// Gives the MIDI tempo map being followed the score's warps ([scoreWarps]) in place of its
  /// own: one Undo step. False, changing nothing, without a MIDI tempo map or score warps.
  bool useScoreWarps() {
    final warps = scoreWarps;
    return warps.isNotEmpty && setMidiWarps(warps);
  }

  /// Makes the sync follow [map] (null: the anchors set by hand again, as they were): one
  /// Undo step. The file's start sounds where bar 1 does now (Starts at).
  void useMidiTempo(MidiTempoMap? map) {
    final sync = _sync;
    if (sync == null || map == _doc.midi) return;
    final start = sync.startSeconds, own = _ownAnchors;
    _doc = _doc.copyWith(midi: map, anchors: own); // the anchors set by hand, kept behind the map
    anchors._reset();
    if (map == null) {
      sync.load(own, leadIn: sync.leadIn);
    } else {
      _followMidi(start);
    }
    notifyListeners();
  }

  /// Follows [map], an edit of the MIDI tempo map being followed (its points dragged or
  /// drawn), from where it starts now. Inside [beginEdit] / [endEdit], one Undo step.
  void editMidiTempo(MidiTempoMap map) {
    if (_doc.midi == null || _sync == null || map == _doc.midi) return;
    _doc = _doc.copyWith(midi: map);
    _followMidi(_sync!.startSeconds);
  }

  /// Gives the MIDI tempo map being followed [warps] instead (one Undo step). False, changing
  /// nothing, when they don't all fit the score (see [MidiTempoMap.arrivals]).
  bool setMidiWarps(List<MidiWarp> warps) {
    final midi = _doc.midi, sync = _sync;
    if (midi == null || sync == null) return false;
    final map = midi.withWarps(warps);
    if (!map.fits(sync.totalQuarters)) return false;
    editMidiTempo(map);
    return true;
  }

  /// Puts the derived anchors of the MIDI tempo map in the sync, with its start at [start].
  void _followMidi(double start) {
    start = math.max(0, start);
    _sync!.load(_doc.midi!.anchors(start: start, totalQuarters: _sync!.totalQuarters), leadIn: start);
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
    if (lanes._selected.isEmpty &&
        lanes._lanes.isEmpty &&
        anchors._isEmpty &&
        images._selected == null &&
        captions._selected == null) {
      return;
    }
    images._deselect();
    captions._selected = null;
    lanes._clear();
    anchors._deselect();
    notifyListeners();
  }

  // One history for the whole document: every edit a project saves ([EditState]). After
  // every change the document's state is compared with the last one recorded; a difference
  // is one Undo step. A gesture (a drag) records only when it ends.

  final _history = EditHistory();

  /// The state as of the last Undo step (what Undo returns to from the next edit).
  EditState? _committed;
  int _gestures = 0;
  bool _restoring = false;

  EditState get _editState => _doc.copyWith(
        lanes: _curation!.lanes,
        transition: _curation!.transition,
        anchors: _ownAnchors,
        leadIn: _sync!.leadIn,
        patches: images._patches,
        captions: captions._captions,
        captionFont: captions._font,
      );

  /// How many steps Undo can go back.
  int get undoLimit => _history.limit;
  set undoLimit(int value) {
    if (value == _history.limit) return;
    _history.limit = value;
    notifyListeners();
  }

  bool get canUndo => _history.canUndo;
  bool get canRedo => _history.canRedo;

  /// Starts a gesture (a drag): everything it changes becomes one Undo step at [endEdit].
  void beginEdit() => _gestures++;

  /// Ends a gesture: merges what it left overlapping, and records it.
  void endEdit() {
    if (_gestures == 0 || _disposed) return;
    _gestures--;
    _curation?.normalize();
    if (_record()) notifyListeners();
  }

  /// Records an Undo step if the document changed since the last (not inside a gesture);
  /// whether it did.
  bool _record() {
    if (_restoring || _gestures > 0 || _score == null) return false;
    final now = _editState, before = _committed;
    if (before == null || now == before) return false;
    _history.record(before);
    _committed = now;
    return true;
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
      final engraved = _wanted;
      _doc = state;
      if (_wanted != engraved) unawaited(_reengrave());
      _joinLanes(); // before the lanes, which fit it
      _curation!.load(state.lanes!, transition: state.transition!); // Undo's states have both
      _sync!.load(_doc.midi?.anchors(start: state.leadIn, totalQuarters: _sync!.totalQuarters) ?? state.anchors,
          leadIn: state.leadIn);
      images._restore(state.patches);
      captions._restore(state.captions, state.captionFont);
      _showSettings();
    } finally {
      _restoring = false;
    }
    _committed = state;
    lanes._clear();
    anchors._deselect();
    _edited();
  }

  // MARK: Projects

  /// Increases with every change that a project saves (not with playback, zoom or selection).
  final editRevision = ValueNotifier<int>(0);

  /// Something a project saves changed: counts it, repaints, records an Undo step (see
  /// [_record]) and tells the listeners. Without [notify] (a model telling its own listeners,
  /// at every move of a drag) they are told only of a step recorded.
  void _edited({bool notify = true}) {
    editRevision.value++;
    playback._markDirty();
    if (_record() || notify) notifyListeners();
  }

  void _curationEdited() => _edited(notify: false);

  /// Every edit made in the app, and the view: what a project stores next to the source score.
  ProjectState get projectState => ProjectState(
        edits: isScoreOrder ? _editState.copyWith(partOrder: const []) : _editState,
        images: images._used,
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
    _engravings.cancel(); // an engraving still running finds nothing to update
    playback._dispose();
    _scene?.dispose();
    _curation?.dispose();
    _sync?.dispose();
    unawaited(audio.unload());
    editRevision.dispose();
    engravingFailure.dispose();
    viewport.dispose();
    super.dispose();
  }
}
