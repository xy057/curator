import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'condensing.dart';
import 'display_list.dart';
import 'engraving.dart';
import 'engraving_options.dart';
import 'frozen_zone.dart';
import 'beat_grid.dart';
import 'curation.dart';
import 'score_fonts.dart';
import 'score_caption.dart';
import 'score_metadata.dart';
import 'score_motion.dart';
import 'score_patch.dart';
import 'score_renderer.dart';
import 'score_text.dart';
import 'score_typography.dart';
import 'scroll_map.dart';
import 'spacing_plan.dart';
import 'staff_stack.dart';

/// What a score is engraved with besides its MusicXML: the text edits, the user's own pairs of
/// players, the fonts, the engraving options and whether dynamics typed as text are made
/// dynamics. Equal requests engrave a score the same, so a change of any is one to engrave.
@immutable
class EngraveRequest {
  const EngraveRequest({
    this.textEdits = const {},
    this.pairs = const [],
    this.fonts = ScoreFonts.standard,
    this.options = const EngravingOptions(),
    this.textDynamics = true,
    this.typography = ScoreTypography.standard,
  });

  /// Text id → new text ('' removes it).
  final Map<String, String> textEdits;

  /// Pairs of players besides the score's own (see [CondensingOptions.pairs]).
  final List<PlayerPair> pairs;
  final ScoreFonts fonts;
  final EngravingOptions options;

  /// See [TextDynamics].
  final bool textDynamics;

  /// How the engraved texts look; only those count ([ScoreTypography.engravesLike]).
  final ScoreTypography typography;

  @override
  bool operator ==(Object other) =>
      other is EngraveRequest &&
      mapEquals(other.textEdits, textEdits) &&
      listEquals(other.pairs, pairs) &&
      other.fonts == fonts &&
      other.options == options &&
      other.textDynamics == textDynamics &&
      other.typography.engravesLike(typography);

  @override
  int get hashCode => Object.hash(textEdits.length, pairs.length, fonts, options, textDynamics);
}

/// A score that is engraved and ready to show.
class LoadedScore {
  LoadedScore._(this.metadata, this.engraving, this.timeline, this.beats, this.scrollMap,
      {required this.musicXML,
      required this.texts,
      required this.textEdits,
      required this.fonts,
      required this.textFontFound,
      required this.options,
      required this.textDynamics,
      required this.typography,
      required this.condensed,
      required this.condensing,
      required this.pairs});

  final ScoreMetadata metadata;
  final EngravingData engraving;
  final ScoreTimeline timeline;
  final ScrollMap scrollMap;

  /// Where the beats fall in each bar, following the time signatures.
  final BeatGrid beats;

  /// The file as opened (edits are applied on top of it when engraving).
  final String musicXML;

  /// Every editable text in the score, as written in the file.
  final List<ScoreText> texts;

  /// Text edits in effect: text id → new text ('' removes it).
  final Map<String, String> textEdits;

  /// The fonts it was engraved with.
  final ScoreFonts fonts;

  /// False when [fonts]' text font isn't installed here: Academico stands in for it.
  final bool textFontFound;

  /// False when [fonts]' music font isn't here ([MusicFont.missing]): Bravura stands in for it.
  bool get musicFontFound => !fonts.music.isMissing;

  /// The families the renderer draws it with.
  String get musicFontFamily => fonts.music.family;
  String get textFontFamily => TextFonts.familyOf(textFontFound ? fonts.text : TextFonts.academico);

  /// The engraving options it was engraved with.
  final EngravingOptions options;

  /// Whether dynamics written as text were engraved as dynamics ([TextDynamics]).
  final bool textDynamics;

  /// How its engraved texts look (its drawn ones are the scene's, [CuratedScene.typography]).
  final ScoreTypography typography;

  /// The pairs of players that can share a staff, each engraved on one of its own (the
  /// scene shows it while both are shown and the pair is condensed).
  final List<CondensedGroup> condensed;

  /// Who could share a staff with whom, and the built-in pairs.
  final CondensingOptions condensing;

  /// The user's own pairs this was engraved with (see [CondensingOptions.pairs]).
  final List<PlayerPair> pairs;

  double get duration => scrollMap.duration;

  /// What the engraving left out or doesn't support (see [EngravingData.warnings]).
  List<String> get warnings => engraving.warnings;

  /// The text as currently shown (after edits).
  String currentText(ScoreText text) => textEdits[text.id] ?? text.text;

  /// What it was engraved with.
  EngraveRequest get request =>
      EngraveRequest(
          textEdits: textEdits,
          pairs: pairs,
          fonts: fonts,
          options: options,
          textDynamics: textDynamics,
          typography: typography);

  /// Engraves [musicXML] as [request] asks.
  static Future<LoadedScore> engrave(String musicXML, EngraveRequest request, {String? resourceDirectory, double? tempo}) =>
      load(musicXML,
          resourceDirectory: resourceDirectory,
          tempo: tempo,
          fonts: request.fonts,
          textEdits: request.textEdits,
          pairs: request.pairs,
          options: request.options,
          textDynamics: request.textDynamics,
          typography: request.typography);

  static Future<LoadedScore> load(
    String musicXML, {
    String? resourceDirectory,
    ScoreFonts fonts = ScoreFonts.standard,
    double? tempo,
    Map<String, String> textEdits = const {},
    List<PlayerPair> pairs = const [],
    EngravingOptions options = const EngravingOptions(),
    bool textDynamics = true,
    ScoreTypography typography = ScoreTypography.standard,
  }) async {
    final doc = ScoreMetadata.parse(musicXML);
    final metadata = ScoreMetadata.fromDocument(doc);
    final prepared = PreparedScore.prepare(doc, textEdits,
        metadata: metadata,
        pairs: pairs,
        textDynamics: textDynamics,
        typography: typography,
        textSize: (options.valueOf(EngraveOption.byKey('lyricSize')!) as num).toDouble());
    final resources = await prepareFonts(fonts, resourceDirectory: resourceDirectory);
    final engraving = await Engraver.engrave(
      prepared.musicXML,
      resourceDirectory: resources.directory,
      font: fonts.music.isMissing ? MusicFont.bravura : fonts.music,
      options: options,
      verovioOptions: typography.verovioOptions,
    );
    final timeline = ConstantTempoTimeline(engraving.measures,
        quarterNotesPerMinute: tempo ?? metadata.tempo ?? 100);
    final beats = BeatGrid(timeline.measureStarts, meters: metadata.meters, pickups: metadata.pickups);
    return LoadedScore._(metadata, engraving, timeline, beats, ScrollMap(engraving, timeline, beats: beats),
        musicXML: musicXML,
        texts: prepared.texts,
        textEdits: Map.unmodifiable(textEdits),
        fonts: fonts,
        textFontFound: resources.textFound,
        options: options,
        textDynamics: textDynamics,
        typography: typography,
        condensed: prepared.condensed,
        condensing: prepared.condensing!,
        pairs: List.unmodifiable(pairs));
  }

  /// Gets [fonts] ready to engrave with and draw: their Verovio metrics (measured once) and
  /// the added music font and installed text font registered. Throws (a [FormatException])
  /// when a font can't be read, so a caller can try fonts before taking them on.
  static Future<({String directory, bool textFound})> prepareFonts(ScoreFonts fonts, {String? resourceDirectory}) async {
    final base = resourceDirectory ?? engineResourceDirectory(), work = FontResources.workDirectory;
    final textFaces = fonts.text == TextFonts.academico ? null : await TextFonts.faces(fonts.text);
    final resources = fonts == ScoreFonts.standard
        ? (directory: base, textFound: true)
        : await Isolate.run(() => FontResources.prepare(fonts, base: base, work: work, textFaces: textFaces));
    await fonts.music.load();
    if (textFaces != null) await TextFonts.load(fonts.text, textFaces);
    return resources;
  }

  static Future<LoadedScore> open(String path, {ScoreFonts fonts = ScoreFonts.standard}) async =>
      load(await ScoreFile.readMusicXML(path), fonts: fonts);

  /// Re-engraves with different text edits (the structure, and so the curation and sync, stay
  /// valid).
  Future<LoadedScore> withTextEdits(Map<String, String> edits) => withEdits(textEdits: edits);

  /// Re-engraves as [request] asks (the structure, and so the curation and sync, stay valid).
  Future<LoadedScore> withRequest(EngraveRequest request) => engrave(musicXML, request, tempo: metadata.tempo);

  /// Re-engraves with different text edits, pairs of players, fonts, engraving options,
  /// [textDynamics] or [typography]; what isn't given stays.
  Future<LoadedScore> withEdits(
          {Map<String, String>? textEdits,
          List<PlayerPair>? pairs,
          ScoreFonts? fonts,
          EngravingOptions? options,
          bool? textDynamics,
          ScoreTypography? typography}) =>
      withRequest(EngraveRequest(
          textEdits: textEdits ?? this.textEdits,
          pairs: pairs ?? this.pairs,
          fonts: fonts ?? this.fonts,
          options: options ?? this.options,
          textDynamics: textDynamics ?? this.textDynamics,
          typography: typography ?? this.typography));
}

/// Where Verovio's font metrics live on disk (bundled as package assets).
String engineResourceDirectory() {
  const relative = 'packages/score_engine/assets/verovio';
  final exe = File(Platform.resolvedExecutable).parent;
  final candidates = [
    // macOS app bundle
    '${exe.parent.path}/Frameworks/App.framework/Resources/flutter_assets/$relative',
    // Windows / Linux
    '${exe.path}/data/flutter_assets/$relative',
    // `flutter test` inside the package or the app
    '${Directory.current.path}/assets/verovio',
    '${Directory.current.path}/../packages/score_engine/assets/verovio',
  ];
  return candidates.firstWhere((p) => File('$p/Bravura.xml').existsSync(), orElse: () => candidates.first);
}

/// What a scene shows besides its score, the time, the curation and the tempo track: what the
/// editor sets on it, as one value, so a video's scene is the preview's by taking its settings.
@immutable
class SceneSettings {
  const SceneSettings({
    this.names = const {},
    this.condensed = const {},
    this.partOrder = const [],
    this.scrollFollow = 1,
    this.patches = const [],
    this.captions = const [],
    this.captionStyle = const CaptionStyle(),
    this.sections = false,
    this.sectionOverrides = const {},
    this.barNumbers = false,
    this.nameColors = const {},
    this.motion = ScoreMotion.standard,
    this.typography = ScoreTypography.standard,
  });

  /// See [CuratedScene.names], [CuratedScene.condensed] and so on.
  final Map<String, ({String name, String abbreviation})> names;
  final Set<String> condensed;
  final List<String> partOrder;
  final double scrollFollow;
  final List<ScenePatch> patches;
  final List<Caption> captions;
  final CaptionStyle captionStyle;
  final bool sections;
  final Map<String, String?> sectionOverrides;
  final bool barNumbers;
  final Map<String, ui.Color> nameColors;
  final ScoreMotion motion;
  final ScoreTypography typography;
}

/// Turns "time + the curation" into one frame.
class CuratedScene {
  CuratedScene(this.score, {RenderStyle style = const RenderStyle()})
      : _style = style.copyWith(musicFontFamily: score.musicFontFamily, textFontFamily: score.textFontFamily) {
    for (final (i, staff) in score.engraving.staves.indexed) {
      _staffIndex[staff.n] = i;
    }
    for (final part in score.metadata.parts) {
      final staves = [for (final n in part.shownStaffNumbers) ?_staffIndex[n]];
      for (var k = 1; k < staves.length; k++) {
        _barlinesThrough[staves[k - 1]] = staves[k];
      }
    }
  }

  /// Staff index → the next staff of the same instrument: a piano's barlines run on between them.
  final _barlinesThrough = <int, int>{};

  final LoadedScore score;

  RenderStyle get style => _style;
  RenderStyle _style;

  /// Draws at another size: only the renderer (its tile cache and the frozen zone) starts
  /// over; the display list, the expensive part, is sized in engraving units and stays.
  void setStaffSpace(double staffSpace) {
    if (staffSpace == _style.staffSpace) return;
    _style = _style.copyWith(staffSpace: staffSpace);
    _renderer?.dispose();
    _renderer = null;
    _frozen?.dispose(); // made for the old size, before any renderer took it
    _frozen = null;
    _plan = null;
    _fitPlan = null;
    _liftKey = Object(); // the row's rises were for the old size: never a plan's key
    _disposeBarNumbers(); // laid out for the old size
  }

  /// How the score lines up with the recording (the tempo track). Defaults to the score's
  /// own tempo; set a SyncMap to follow a performance.
  ScoreTimeline get timeline => _timeline ?? score.timeline;
  ScoreTimeline? _timeline;
  late ScrollMap scrollMap = score.scrollMap;
  int _timelineVersion = 0;

  /// Follows a new or edited tempo track: rebuilds the scroll mapping and the layout plan.
  void setTimeline(ScoreTimeline timeline) {
    _timeline = timeline;
    scrollMap = ScrollMap(score.engraving, timeline, beats: score.beats, follow: scrollFollow, motion: _motion);
    _timelineVersion++;
  }

  /// How closely the scroll follows the notes (see [ScrollMap.follow]): 0 glides from beat
  /// to beat, 1 puts every onset under the pointer as it sounds. Changing it re-plans the
  /// layout; the anchors stay.
  double get scrollFollow => scrollMap.follow;
  set scrollFollow(double value) {
    final next = scrollMap.withFollow(value);
    if (identical(next, scrollMap)) return;
    scrollMap = next;
    _timelineVersion++;
  }
  /// The engraving as drawable items: made when first drawn, again when [barNumbers] sets the
  /// tempo marks apart or puts them back.
  ScoreDisplayList get display => _display ??= ScoreDisplayList.build(
        score.engraving,
        _style,
        withoutKeySignatures: {
          for (final part in score.metadata.parts)
            if (part.isUnpitchedPercussion) ...part.staffNumbers,
        },
        hiddenCommands: _openingCommands,
        apart: barNumbers ? _tempoIds : const {},
      );
  ScoreDisplayList? _display;
  int _displayVersion = 0;

  ScoreRenderer get renderer => _renderer ??= () {
        final display = this.display;
        final frozen = _frozen ?? FrozenZone(score.engraving, _style);
        _frozen = null; // the renderer's now
        return ScoreRenderer(display, _style, frozen: frozen, barlinesThrough: _barlinesThrough)
          ..names = _typography[TextKind.names];
      }();
  ScoreRenderer? _renderer;

  /// A frozen zone made for its opening commands, kept for the first renderer.
  FrozenZone? _frozen;
  late final Set<int> _openingCommands = (_frozen ??= FrozenZone(score.engraving, _style)).openingCommands;
  final _staffIndex = <int, int>{};

  /// Instrument names chosen by the user (part id → name / short name), shown in the name column.
  Map<String, ({String name, String abbreviation})> names = const {};

  /// Everything set on the scene ([names], [condensed], [partOrder], [scrollFollow],
  /// [patches], [captions], [captionStyle], [sections], [sectionOverrides], [barNumbers],
  /// [nameColors], [motion]);
  /// setting it changes only what differs.
  SceneSettings get settings => SceneSettings(
      names: names,
      condensed: condensed,
      partOrder: partOrder,
      scrollFollow: scrollFollow,
      patches: patches,
      captions: captions,
      captionStyle: captionStyle,
      sections: sections,
      sectionOverrides: sectionOverrides,
      barNumbers: barNumbers,
      nameColors: nameColors,
      motion: motion,
      typography: typography);
  set settings(SceneSettings value) {
    names = value.names;
    condensed = value.condensed;
    partOrder = value.partOrder;
    scrollFollow = value.scrollFollow;
    patches = value.patches;
    captions = value.captions;
    captionStyle = value.captionStyle;
    sections = value.sections;
    sectionOverrides = value.sectionOverrides;
    barNumbers = value.barNumbers;
    nameColors = value.nameColors;
    motion = value.motion;
    typography = value.typography;
  }

  /// How the score moves (Project Settings ▸ Advanced): staves' glides and fades, the scroll's
  /// coming to rest, the ending's fade, captions, the bar numbers' row and the tempo at the left.
  ScoreMotion get motion => _motion;
  ScoreMotion _motion = ScoreMotion.standard;
  set motion(ScoreMotion value) {
    if (value == _motion) return;
    _motion = value;
    final next = scrollMap.withMotion(value);
    if (!identical(next, scrollMap)) {
      scrollMap = next;
      _timelineVersion++;
    }
  }

  /// How the texts the scene draws look (Project Settings ▸ Typography): the names, the bar
  /// numbers, the tempo at the left, captions. The engraved ones are the score's
  /// ([LoadedScore.typography]); a change here only redraws.
  ScoreTypography get typography => _typography;
  ScoreTypography _typography = ScoreTypography.standard;
  set typography(ScoreTypography value) {
    if (value == _typography) return;
    final old = _typography;
    _typography = value;
    _renderer?.names = value[TextKind.names];
    if (value[TextKind.barNumbers] != old[TextKind.barNumbers]) _disposeBarNumbers();
    if (value[TextKind.tempoRow] != old[TextKind.tempoRow]) _disposeTempoTexts();
    if (value[TextKind.captions] != old[TextKind.captions]) {
      _captionBar.dispose();
      _captionBar = CaptionBar(_style.textFontFamily, _captionBar.style, value[TextKind.captions]);
    }
  }

  /// The colour some instruments are named in, by part id (a pair in its first player's); one
  /// left out is named in the ink.
  Map<String, ui.Color> nameColors = const {};

  /// Whether the instruments are grouped in sections as a printed score groups them: each
  /// section ([sectionOf]: the woodwinds, the brass… or a group of the user's) bracketed, its
  /// barlines run on between its staves (not a choir's, which leave room for the words), and
  /// the starting line through every staff. A section is a run of its instruments in
  /// [partOrder]; one moved away from the rest starts a section of its own.
  /// Only drawn: nothing is planned or engraved again.
  bool sections = false;

  /// The user's choice of section for some instruments (part id → section; null: none, standing
  /// alone) over their own ([ScorePart.section]'s name). A section is any name: a family's
  /// joins that family's instruments, another one only those given it. A pair takes its first
  /// player's.
  Map<String, String?> get sectionOverrides => _sectionOverrides;
  Map<String, String?> _sectionOverrides = const {};
  set sectionOverrides(Map<String, String?> value) {
    if (mapEquals(value, _sectionOverrides)) return;
    _sectionOverrides = Map.unmodifiable(value);
    _sectionRuns = _sectionRunsOf(_order);
  }

  /// Whether the user put [part] in a section other than its own.
  bool _ownSection(ScorePart part) {
    final section = _sectionOverrides[part.id];
    return section != null && section != part.section?.name;
  }

  /// [part]'s section: the user's choice, else its own family's name; null: none.
  String? sectionOf(ScorePart part) =>
      _sectionOverrides.containsKey(part.id) ? _sectionOverrides[part.id] : part.section?.name;

  /// The pairs of players (ids from [LoadedScore.condensed]) that share a staff while both
  /// are shown. Changing it re-plans the layout; nothing is engraved again.
  Set<String> get condensed => _condensed;
  Set<String> _condensed = const {};
  set condensed(Set<String> ids) {
    if (setEquals(ids, _condensed)) return;
    _condensed = Set.unmodifiable(ids);
    _condensedVersion++;
  }

  int _condensedVersion = 0;
  late final _groups = {for (final g in score.condensed) g.id: g};
  late final _groupOf = {for (final g in score.condensed) for (final id in g.partIds) id: g};
  CondensedGroup? _activeGroupOf(String partId) {
    final group = _groupOf[partId];
    return group != null && _condensed.contains(group.id) ? group : null;
  }

  /// Free space above the first and below the last staff.
  double verticalMargin = 36;
  double minGap = 24;
  double maxGap = 140;

  SpacingPlan? _plan;
  KeyColumnPlan? _keyPlan;
  Object? _planKey;

  /// [overflowing]'s plan, for a size the frames aren't painted at.
  SpacingPlan? _fitPlan;
  Object? _fitKey;

  /// The instruments from top to bottom (part ids): the score's order unless the user moved
  /// some. Changing it re-plans the layout; nothing is engraved again (every staff is drawn
  /// on its own). Ids it lacks keep their score order after the others; unknown ones are
  /// dropped.
  List<String> get partOrder => _partOrder;
  late List<String> _partOrder = [for (final p in score.metadata.parts) p.id];
  set partOrder(List<String> ids) {
    final next = orderedPartIds(score.metadata.parts, ids);
    if (listEquals(next, _partOrder)) return;
    _partOrder = next;
    _order = _plannedOrder();
    _twins = _twinsOf(_order);
    _sectionRuns = _sectionRunsOf(_order);
    _orderVersion++;
  }

  int _orderVersion = 0;

  /// Every part of [parts] once: those in [ids] in that order, then the rest in score order.
  static List<String> orderedPartIds(List<ScorePart> parts, Iterable<String> ids) {
    final known = {for (final p in parts) p.id};
    final ordered = <String>{for (final id in ids) if (known.contains(id)) id};
    return List.unmodifiable([...ordered, for (final p in parts) if (!ordered.contains(p.id)) p.id]);
  }

  /// Every shown staff in [partOrder] (empty divisi staves are left out entirely), a pair's
  /// shared staff just above its first player's.
  late List<PlannedStaff> _order = _plannedOrder();

  List<PlannedStaff> _plannedOrder() {
    final parts = {for (final p in score.metadata.parts) p.id: p};
    return [
      for (final id in _partOrder) ...[
        for (final g in score.condensed)
          if (g.partIds.first == id && _staffIndex[g.staffNumber] != null)
            (staffIndex: _staffIndex[g.staffNumber]!, partId: g.id),
        for (final n in parts[id]!.shownStaffNumbers)
          if (_staffIndex[n] != null) (staffIndex: _staffIndex[n]!, partId: id),
      ],
    ];
  }

  /// The sections in [_order]: runs of its staves (start and end, inclusive) whose instruments
  /// are of one section, two instruments or more, or one the user put in it (bracketed even
  /// while only one shows); [outset] when one of them is on more than one
  /// staff (its brace takes the room beside the staves).
  late List<({int start, int end, bool barlines, bool outset})> _sectionRuns = _sectionRunsOf(_order);

  List<({int start, int end, bool barlines, bool outset})> _sectionRunsOf(List<PlannedStaff> order) {
    final parts = {for (final p in score.metadata.parts) p.id: p};
    ScorePart partOf(String id) => parts[id] ?? parts[_groups[id]!.partIds.first]!; // a pair: its first player
    final runs = <({int start, int end, bool barlines, bool outset})>[];
    var start = 0;
    for (var i = 1; i <= order.length; i++) {
      final section = sectionOf(partOf(order[start].partId));
      if (i < order.length && section != null && sectionOf(partOf(order[i].partId)) == section) continue;
      final run = [for (var j = start; j < i; j++) partOf(order[j].partId)];
      if (section != null && ({for (final p in run) p.id}.length > 1 || run.any(_ownSection))) {
        runs.add((
          start: start,
          end: i - 1,
          barlines: [for (var j = start; j < i; j++) partOf(order[j].partId)].any((p) => p.family != InstrumentFamily.voices),
          outset: [for (var j = start; j < i; j++) partOf(order[j].partId)].any((p) => p.shownStaffNumbers.length > 1),
        ));
      }
      start = i;
    }
    return runs;
  }

  /// A shared staff and its players' own take each other's place: when one is hidden while
  /// the other is shown, it waits right there, so swapping them is a cross-fade in place.
  late Map<int, List<int>> _twins = _twinsOf(_order);

  Map<int, List<int>> _twinsOf(List<PlannedStaff> order) {
    final at = {for (final (i, s) in order.indexed) s.partId: i};
    final twins = <int, List<int>>{};
    for (final g in score.condensed) {
      final shared = at[g.id];
      final players = [for (final id in g.partIds) ?at[id]];
      if (shared == null) continue;
      twins[shared] = players;
      for (final p in players) {
        twins[p] = [shared];
      }
    }
    return twins;
  }

  /// Whether the staff planned for [id] (a part, or a pair's shared staff) is shown.
  bool _isShown(Curation curation, String id, double seconds) {
    bool shown(String partId) => curation.isShownAt(partId, seconds, timeline);
    final group = _groups[id];
    if (group != null) return _condensed.contains(id) && group.partIds.every(shown);
    final active = _activeGroupOf(id);
    if (active == null) return shown(id);
    return shown(id) && !active.partIds.every(shown);
  }

  /// 0…1 for every planned staff: a pair's shared staff is as visible as its less visible
  /// player, and each player's own staff has what is left, so one fades as the other comes.
  Map<String, double> _visibilityAt(double time, Curation curation) {
    final v = {...curation.visibilityAt(time, timeline, curve: _motion.fade)};
    for (final g in score.condensed) {
      if (!_condensed.contains(g.id)) continue;
      final a = v[g.partIds[0]] ?? 0, b = v[g.partIds[1]] ?? 0;
      v[g.id] = math.min(a, b);
      v[g.partIds[0]] = math.max(0, a - b);
      v[g.partIds[1]] = math.max(0, b - a);
    }
    return v;
  }

  StackMetrics _metrics(ui.Size size) => StackMetrics(
        availableHeight: (size.height - 2 * verticalMargin - _captionReserve).clamp(0, double.infinity),
        minGap: minGap,
        maxGap: maxGap,
      );

  /// What a plan for this curation and frame size is made from: a new key, a new plan.
  Object _planKeyFor(Curation curation, ui.Size size) =>
      (curation, curation.revision, curation.transition, size, verticalMargin, minGap, maxGap, _timelineVersion, _condensedVersion, _orderVersion, _captionReserve, _displayVersion, _motion.glide);

  SpacingPlan _buildPlan(Curation curation, ui.Size size) {
    final pointerX = renderer.pointerX(size.width);
    final top = verticalMargin; // the plan's 0 in the frame
    return SpacingPlan.build(
      staves: display.staves,
      order: _order,
      scrollMap: scrollMap,
      edges: curation.edgesInSeconds(timeline),
      isShown: (id, seconds) => _isShown(curation, id, seconds),
      twins: _twins,
      visibleLeft: pointerX / renderer.scale,
      visibleRight: (size.width - pointerX) / renderer.scale,
      transition: curation.transition,
      glide: _motion.glide,
      scale: renderer.scale,
      metrics: _metrics(size),
      musicLeft: (pointerX - renderer.musicLeft) / renderer.scale,
      screen: (top: -top, bottom: size.height - top),
    );
  }

  /// When something drawn is off the top or bottom of a frame of [size]
  /// ([SpacingPlan.overflowing]), in playback time. Planned apart from the frames painted, so asking at another size (the
  /// video's) never makes the preview plan again.
  List<({double start, double end})> overflowing(Curation curation, ui.Size size) {
    final key = _planKeyFor(curation, size);
    if (_plan != null && _planKey == key) return _plan!.overflowing;
    if (_fitPlan == null || _fitKey != key) {
      _fitPlan = _buildPlan(curation, size);
      _fitKey = key;
    }
    return _fitPlan!.overflowing;
  }

  /// The layout plan for this curation and frame size, rebuilt only when either changes.
  SpacingPlan _planFor(Curation curation, ui.Size size) {
    final key = _planKeyFor(curation, size);
    if (_plan == null || _planKey != key) {
      final pointerX = renderer.pointerX(size.width);
      _plan = _buildPlan(curation, size);
      final zone = renderer.frozen;
      _keyPlan = zone == null
          ? null
          : KeyColumnPlan.build(
              zone: zone,
              staves: display.staves,
              order: _order,
              scrollMap: scrollMap,
              edges: curation.edgesInSeconds(timeline),
              isShown: (id, seconds) => _isShown(curation, id, seconds),
              minReach: (pointerX - renderer.musicLeftFor(0)) / renderer.scale,
              maxReach: (pointerX - renderer.musicLeft) / renderer.scale,
              transition: curation.transition,
              glide: _motion.glide,
            );
      _planKey = key;
    }
    return _plan!;
  }

  /// The frozen zone's key column at [time], staff spaces: as wide as the widest key
  /// signature of the staves shown (see [KeyColumnPlan]).
  double keyColumnAt(double time, Curation curation, ui.Size size) {
    _planFor(curation, size);
    return _keyPlan?.columnAt(time) ?? 0;
  }

  /// Prepares the GPU for frames on see-through paper (see [ScoreRenderer.warmUp]); call it
  /// once while nothing moves.
  static Future<void> warmUp() => ScoreRenderer.warmUp();

  /// When a performance (and its video) ends: the score comes to rest after the final
  /// barline ([ScoreMotion.settle]), then fades out ([ScoreMotion.endFade]).
  static double endOf(ScoreTimeline timeline, [ScoreMotion motion = ScoreMotion.standard]) =>
      timeline.endSeconds + motion.ending;

  /// Draws the frame at [time]. [paper] and [ink] override the style's colours (a dark
  /// theme); changing them costs nothing (see ScoreRenderer). Over the last
  /// [ScoreMotion.endFade] seconds before [end] everything fades to paper (on see-through
  /// paper, out to nothing).
  void paint(ui.Canvas canvas, ui.Size size,
      {required double time,
      required Curation curation,
      required double devicePixelRatio,
      double end = double.infinity,
      ui.Color? paper,
      ui.Color? ink}) {
    final frame = layoutAt(time, curation, size);
    final rowShift = barNumbers ? _rowShiftAt(time, curation, size) : 0.0;
    final scrollX = scrollMap.xAt(time);
    final paperColor = paper ?? style.paper;
    final fadeOut = _motion.endFade;
    final faded = fadeOut > 0 ? ((time - (end - fadeOut)) / fadeOut).clamp(0.0, 1.0) : (time >= end ? 1.0 : 0.0);
    // Eased, so it leaves gently and settles into the paper.
    final fade = _motion.endCurve.inside(faded);
    // Paper painted over see-through paper would show nothing: the whole frame fades instead.
    final fadeLayer = fade > 0 && paperColor.a < 1;
    if (fadeLayer) canvas.saveLayer(ui.Offset.zero & size, ui.Paint()..color = ui.Color.fromRGBO(0, 0, 0, 1 - fade));
    renderer.paint(canvas, size,
        scrollX: scrollX,
        placements: frame.placements,
        labels: frame.labels,
        braces: frame.braces,
        brackets: frame.brackets,
        joins: frame.joins,
        outsetBrackets: sections && _sectionRuns.any((r) => r.outset),
        devicePixelRatio: devicePixelRatio,
        keyColumn: keyColumnAt(time, curation, size),
        paper: paper,
        ink: ink,
        overlay: patches.isEmpty && !barNumbers
            ? null
            : (canvas, musicLeft) {
                canvas
                  ..save()
                  ..clipRect(ui.Rect.fromLTRB(musicLeft, 0, size.width, size.height));
                if (barNumbers) _paintBarNumbers(canvas, size, scrollX, ink ?? style.ink, rowShift);
                for (final patch in patches) {
                  final rect = _patchRect(patch, scrollX, size);
                  if (rect.right < musicLeft || rect.left > size.width) continue;
                  patch.paint(canvas, rect, inkColor: ink ?? style.ink);
                }
                canvas.restore();
              });
    if (barNumbers) _paintTempo(canvas, size, scrollX, ink ?? style.ink, rowShift);
    if (captions.isNotEmpty) _captionBar.paint(canvas, size, time, _captionSpans, captions, ink ?? style.ink, motion: _motion);
    if (fadeLayer) {
      canvas.restore();
    } else if (fade > 0) {
      canvas.drawRect(ui.Offset.zero & size, ui.Paint()..color = paperColor.withValues(alpha: fade));
    }
  }

  // MARK: Captions

  /// Captions shown in a bar under the staves (the Captions extension), which leave room for
  /// it while there are any.
  List<Caption> get captions => _captions;
  List<Caption> _captions = const [];
  set captions(List<Caption> value) {
    if (listEquals(value, _captions)) return;
    _captions = List.unmodifiable(value);
    _spansKey = null;
  }

  /// How captions look; a change only redraws.
  CaptionStyle get captionStyle => _captionBar.style;
  set captionStyle(CaptionStyle value) {
    if (value == _captionBar.style) return;
    _captionBar.dispose();
    _captionBar = CaptionBar(_style.textFontFamily, value, _typography[TextKind.captions]);
  }

  late CaptionBar _captionBar = CaptionBar(_style.textFontFamily);

  /// Room the staves leave for the caption bar: none without captions.
  double get _captionReserve => captions.isEmpty ? 0 : _captionBar.reserve;
  Object? _spansKey;
  List<CaptionSpan> _spans = const [];

  /// When each caption shows, following the timeline.
  List<CaptionSpan> get _captionSpans {
    final key = (_captions, _timelineVersion, timeline);
    if (_spansKey != key) {
      _spans = captionSpans(_captions, timeline);
      _spansKey = key;
    }
    return _spans;
  }

  /// The caption showing at [time] (an index into [captions]); null: none.
  int? captionShowingAt(double time) {
    for (final s in _captionSpans) {
      if (time >= s.start && time < s.end) return s.caption;
    }
    return null;
  }

  /// Where caption [index]'s text is drawn in a frame of [size] (points).
  ui.Rect captionRect(int index, ui.Size size) => _captionBar.rectOf(_captions[index].text, size);

  // MARK: Bar numbers

  /// Whether every bar's number is shown at its top left, small, grey and italic, in a row
  /// above the staves that stays put as they come and go, and the tempo marks at the frame's
  /// left in that row (set apart from the music: the display list is made again).
  bool get barNumbers => _barNumbers;
  bool _barNumbers = false;
  set barNumbers(bool value) {
    if (value == _barNumbers) return;
    _barNumbers = value;
    if (_tempoIds.isEmpty || _display == null) return;
    _renderer?.dispose();
    _renderer = null;
    _display!.dispose();
    _display = null;
    _displayVersion++;
    _inkAboveOf.clear();
    _tempoSpans = null;
  }

  /// What every text that speaks of the speed says ([ScoreText.tempoRole]), by id, with its
  /// words as shown.
  late final _tempoRoles = {
    for (final text in score.texts)
      if (text.tempoRole(score.currentText(text)) case final role when role != TempoRole.none)
        text.id: (role: role, words: score.currentText(text), extended: text.extended),
  };

  /// Each of those texts' source id, and its copy's on a pair's shared staff → its own: set
  /// apart from the music.
  late final _tempoIds = {
    for (final id in _tempoRoles.keys) ...{id: id, '${Condenser.idPrefix}$id': id},
  };

  final _barNumberText = <String, ui.Paragraph>{};

  /// A bar's number ([ScoreMetadata.barNumbers]) laid out, as [TextKind.barNumbers] looks.
  ui.Paragraph _barNumber(String number) => _barNumberText.putIfAbsent(number, () {
        final look = _typography[TextKind.barNumbers], fontSize = _style.staffSpace * 1.3 * look.size;
        final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
            fontFamily: _style.textFontFamily,
            fontSize: fontSize,
            fontStyle: look.face.fontStyle,
            fontWeight: look.face.fontWeight,
            maxLines: 1))
          ..pushStyle(ui.TextStyle(color: const ui.Color(0xFF000000), letterSpacing: look.spacingAt(fontSize)))
          ..addText(number);
        return builder.build()..layout(const ui.ParagraphConstraints(width: double.infinity));
      });

  void _disposeBarNumbers() {
    for (final p in _barNumberText.values) {
      p.dispose();
    }
    _barNumberText.clear();
  }

  /// The row's bottom in a frame, before any move: just above the room the staves have.
  double get _rowBottom => verticalMargin - 6;

  /// The highest the row's top may go: near the top.
  static const _rowTopLimit = 4.0;

  /// How far the row is lifted at [time]: none, unless staves squeezed into a full frame reach
  /// up into it. It only ever rises, to the most needed so far, never settling back, and each
  /// rise is eased in over the [ScoreMotion.rowLead] seconds before the staves get there: the
  /// highest needed so far ([_liftFor], a step at each [_liftStep]) averaged over the time ahead
  /// with the slope of [ScoreMotion.rowCurve] as the weight (smoothstep's bell: the move starts
  /// and ends at rest). Still a function of time.
  double _rowShiftAt(double time, Curation curation, ui.Size size) {
    final lead = _motion.rowLead, curve = _motion.rowCurve;
    double eased(double x) => curve.at(x / lead);

    var shift = 0.0;
    final first = (time / _liftStep).floor(), last = ((time + lead) / _liftStep).floor();
    final lift = _liftFor(curation, size, last);
    for (var i = first; i <= last; i++) {
      final weight = eased((i + 1) * _liftStep - time) - eased(math.max(i * _liftStep, time) - time);
      shift += lift[i.clamp(0, lift.length - 1)] * weight;
    }
    final room = _rowBottom - _style.staffSpace * 1.6 - _rowTopLimit;
    return shift.clamp(0.0, math.max(0.0, room));
  }

  static const _liftStep = 0.1;

  /// The most the row has had to rise up to each [_liftStep] of the playback, worked out once
  /// per plan and only as far as [upTo] (and the first step): an edit late in a long score costs
  /// the steps up to the playhead, not the whole piece, and what a step holds never depends on
  /// how far it was asked before. While [holdBarRow] the steps worked out are kept.
  Float64List _liftFor(Curation curation, ui.Size size, int upTo) {
    final key = _planKeyFor(curation, size);
    if (_liftKey != key && !(holdBarRow && _liftDone > 0)) {
      _liftKey = key;
      _lift = Float64List((endOf(timeline, _motion) / _liftStep).ceil() + 1);
      _liftDone = 0;
    }
    final end = math.max(0, math.min(upTo, _lift.length - 1));
    for (; _liftDone <= end; _liftDone++) {
      final i = _liftDone;
      _lift[i] = math.max(i > 0 ? _lift[i - 1] : 0.0, _rowNeedAt(i * _liftStep, curation, size));
    }
    return _lift;
  }

  Object? _liftKey;
  Float64List _lift = Float64List(0);

  /// How many of [_lift]'s steps are worked out.
  int _liftDone = 0;

  /// Whether the bar numbers' row keeps the rises worked out before, whatever changes: while a
  /// gesture lasts (a region dragged, the score size slid), when working them out again at every
  /// move would cost a long score's frames. It catches up when let go; a video never holds.
  bool holdBarRow = false;

  /// How far the row would have to rise at [time] to stay clear of the top staves' ink.
  double _rowNeedAt(double time, Curation curation, ui.Size size) {
    final tops = _planFor(curation, size).topsAt(time);
    final scale = renderer.scale, clear = _rowBottom + 3 - verticalMargin;
    double? left, right;
    var need = 0.0, checked = 0;
    for (var i = 0; i < _order.length && checked < 2; i++) {
      // Shown or not, no fade: cheaper, and a staff only fading in counts a little early.
      if (!_isShown(curation, _order[i].partId, time)) continue;
      checked++;
      final staff = display.staves[_order[i].staffIndex];
      if (tops[i] - _inkAbove(_order[i].staffIndex) * scale >= clear) continue; // clear wherever it is
      if (left == null) (left, right) = renderer.visibleRange(scrollMap.xAt(time), size.width);
      need = math.max(need, clear - (tops[i] - staff.maxInk(left, right!).above * scale));
    }
    return need;
  }

  /// How far a staff's ink reaches above its top line anywhere, device units, by staff index.
  double _inkAbove(int staffIndex) => _inkAboveOf.putIfAbsent(staffIndex,
      () => display.staves[staffIndex].maxInk(-1e9, 1e9).above);
  final _inkAboveOf = <int, double>{};

  void _paintBarNumbers(ui.Canvas canvas, ui.Size size, double scrollX, ui.Color ink, double shift) {
    final measures = score.engraving.measures, numbers = score.metadata.barNumbers;
    final scale = renderer.scale, sp = _style.staffSpace;
    final originX = renderer.pointerX(size.width) - scrollX * scale;
    final (left, right) = renderer.visibleRange(scrollX, size.width);
    canvas.saveLayer(
        null,
        ui.Paint()
          ..color = ui.Color.fromRGBO(0, 0, 0, _typography[TextKind.barNumbers].opacity)
          ..colorFilter = ui.ColorFilter.mode(ink, ui.BlendMode.srcIn));
    for (var m = 0; m < measures.length; m++) {
      final bar = measures[m];
      if (bar.right < left) continue;
      if (bar.left > right) break;
      final number = m < numbers.length ? numbers[m] : '${m + 1}';
      if (number == null) continue; // an upbeat, a split bar's second half
      final text = _barNumber(number);
      canvas.drawParagraph(text, ui.Offset(originX + bar.left * scale + sp * 0.3, _rowBottom - shift - text.height));
    }
    canvas.restore();
  }

  /// What the frame's left shows from each score x on, left to right (null: nothing): the
  /// tempo mark the playhead last passed, or a change of speed ("rit.") in its stead from where
  /// it is written until its dashes end, "a tempo" or another mark comes.
  List<({double x, String? words})> get _tempoSpanList {
    if (_tempoSpans case final spans?) return spans;
    final events = <({double x, int order, String id, bool end})>[];
    for (final mark in display.apart) {
      final role = _tempoRoles[mark.id];
      if (role == null) continue;
      events.add((x: mark.bounds.left, order: 1, id: mark.id, end: false));
      if (role.role == TempoRole.change && role.extended) {
        events.add((x: mark.bounds.right, order: 0, id: mark.id, end: true)); // where its dashes stop
      }
    }
    events.sort((a, b) => a.x != b.x ? a.x.compareTo(b.x) : a.order.compareTo(b.order));
    final spans = <({double x, String? words})>[];
    String? tempo, change;
    for (final e in events) {
      final role = _tempoRoles[e.id]!;
      if (e.end) {
        if (change == e.id) change = null;
      } else {
        switch (role.role) {
          case TempoRole.tempo:
            tempo = e.id;
            change = null;
          case TempoRole.change:
            change = e.id;
          case TempoRole.back:
            change = null;
          case TempoRole.none:
        }
      }
      final words = switch (change ?? tempo) { final id? => _tempoRoles[id]!.words, null => null };
      if (spans.isEmpty ? words != null : spans.last.words != words) spans.add((x: e.x, words: words));
    }
    return _tempoSpans = spans;
  }

  List<({double x, String? words})>? _tempoSpans;

  /// [_tempoSpanList]'s words at the frame's left in the bar numbers' row, on their baseline,
  /// in the text font's italic at the names' size, cut short to fit their width. One gives way
  /// to the next over [ScoreMotion.tempoFade] staff spaces of scroll.
  void _paintTempo(ui.Canvas canvas, ui.Size size, double scrollX, ui.Color ink, double shift) {
    final spans = _tempoSpanList;
    if (spans.isEmpty) return;
    final fade = _motion.tempoFade * display.data.staffSpace, curve = _motion.tempoCurve;
    double arrived(int i) {
      final past = scrollX - spans[i].x;
      return fade > 0 ? curve.inside(past / fade + 0.5) : (past >= 0 ? 1.0 : 0.0);
    }

    final number = _barNumber('1');
    final baseline = _rowBottom - shift - number.height + number.alphabeticBaseline;
    for (var i = 0; i < spans.length; i++) {
      final opacity = arrived(i) * (i + 1 < spans.length ? 1 - arrived(i + 1) : 1);
      final words = spans[i].words;
      if (opacity <= 0.001 || words == null || words.isEmpty) continue;
      final text = _tempoText(words);
      canvas
        ..saveLayer(
            null,
            ui.Paint()
              ..color = ui.Color.fromRGBO(0, 0, 0, opacity * _typography[TextKind.tempoRow].opacity)
              ..colorFilter = ui.ColorFilter.mode(ink, ui.BlendMode.srcIn))
        ..drawParagraph(text, ui.Offset(8, baseline - text.alphabeticBaseline))
        ..restore();
    }
  }

  final _tempoParagraphs = <String, ui.Paragraph>{};

  /// [words] laid out as [TextKind.tempoRow] looks.
  ui.Paragraph _tempoText(String words) => _tempoParagraphs.putIfAbsent(words, () {
        final look = _typography[TextKind.tempoRow], fontSize = _style.labelFontSize * look.size;
        final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
            fontFamily: _style.textFontFamily,
            fontSize: fontSize,
            fontStyle: look.face.fontStyle,
            fontWeight: look.face.fontWeight,
            maxLines: 1,
            ellipsis: '…'))
          ..pushStyle(ui.TextStyle(color: const ui.Color(0xFF000000), letterSpacing: look.spacingAt(fontSize)))
          ..addText(words);
        return builder.build()..layout(ui.ParagraphConstraints(width: _style.headerWidth - 16));
      });

  void _disposeTempoTexts() {
    for (final p in _tempoParagraphs.values) {
      p.dispose();
    }
    _tempoParagraphs.clear();
  }

  // MARK: Images

  /// Images on the score, drawn over the music (under the names, the frozen zone and the
  /// pointer), scrolling with it.
  List<ScenePatch> patches = const [];

  /// Score quarters ↔ engraving x.
  late final ScoreAxis axis = ScoreAxis(score.engraving, score.timeline.measureStarts);

  /// Where [patch] is drawn at [time] in a frame of [size] (points).
  ui.Rect patchRect(ScenePatch patch, double time, ui.Size size) => _patchRect(patch, scrollMap.xAt(time), size);

  ui.Rect _patchRect(ScenePatch patch, double scrollX, ui.Size size) {
    final sp = style.staffSpace;
    return ui.Rect.fromLTWH(renderer.pointerX(size.width) + (axis.xAt(patch.quarter) - scrollX) * renderer.scale,
        patch.top * sp, patch.width * sp, patch.height * sp);
  }

  /// The score quarter under frame x [x] (points) at [time]: where a patch's left edge there
  /// is pinned.
  double quarterAtFrameX(double x, double time, ui.Size size) =>
      axis.quarterAt(scrollMap.xAt(time) + (x - renderer.pointerX(size.width)) / renderer.scale);

  /// The frame at [time] as an image of [width] × [height] pixels, laid out at
  /// [devicePixelRatio] pixels per logical pixel (a video frame). It is [paint] drawn
  /// offscreen, so a video looks exactly like the preview.
  ui.Image renderFrame(int width, int height,
      {required double time,
      required Curation curation,
      required double devicePixelRatio,
      double end = double.infinity,
      ui.Color? paper,
      ui.Color? ink}) {
    final size = ui.Size(width / devicePixelRatio, height / devicePixelRatio);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)
      ..scale(devicePixelRatio)
      ..clipRect(ui.Offset.zero & size);
    paint(canvas, size,
        time: time, curation: curation, devicePixelRatio: devicePixelRatio, end: end, paper: paper, ink: ink);
    final picture = recorder.endRecording();
    try {
      return picture.toImageSync(width, height);
    } finally {
      picture.dispose();
    }
  }

  /// Where every visible staff and label sits at [time]: a lookup into the plan. With
  /// [sections], the sections' brackets and the joins between staves too.
  ({
    List<StaffPlacement> placements,
    List<StaffLabel> labels,
    List<StaffBrace> braces,
    List<StaffBracket> brackets,
    List<StaffJoin> joins,
  }) layoutAt(double time, Curation curation, ui.Size size) {
    final visibility = _visibilityAt(time, curation);
    final tops = [for (final y in _planFor(curation, size).topsAt(time)) y + verticalMargin];
    final parts = {for (final p in score.metadata.parts) p.id: p};

    final placements = <StaffPlacement>[];
    final labels = <StaffLabel>[];
    final braces = <StaffBrace>[];
    final placed = <int, StaffPlacement>{}; // order index → its placement
    for (var i = 0; i < _order.length; i++) {
      final (:staffIndex, :partId) = _order[i];
      final v = (visibility[partId] ?? 0).clamp(0.0, 1.0);
      if (v <= 0) continue;
      final opacity = _motion.inkFor(v);
      placements.add(placed[i] = StaffPlacement(staffIndex: staffIndex, y: tops[i], opacity: opacity));

      final group = _groups[partId];
      if (group != null) {
        String name(String id, {bool short = false}) {
          final part = parts[id]!;
          return short ? names[id]?.abbreviation ?? part.abbreviation : names[id]?.name ?? part.name;
        }

        final [a, b] = group.partIds;
        labels.add(StaffLabel(
            text: CondensedGroup.nameFor(name(a), name(b)), // follows the players' names
            shortText: CondensedGroup.nameFor(name(a, short: true), name(b, short: true)),
            centerY: tops[i] + display.staves[staffIndex].info.height * renderer.scale / 2,
            opacity: opacity,
            partId: group.id,
            color: nameColors[a]));
        continue;
      }
      final part = parts[partId]!;
      final staves = part.shownStaffNumbers;
      if (staves.first == display.staves[staffIndex].info.n) {
        final last = i + staves.length - 1;
        final bottom = tops[last] + display.staves[_order[last].staffIndex].info.height * renderer.scale;
        final named = names[part.id];
        labels.add(StaffLabel(
            text: named?.name ?? part.name,
            shortText: named?.abbreviation ?? part.abbreviation,
            centerY: (tops[i] + bottom) / 2,
            opacity: opacity,
            partId: part.id,
            color: nameColors[part.id]));
        if (staves.length > 1) {
          braces.add(StaffBrace(staves: [
            for (var j = i; j <= last; j++)
              (top: tops[j], height: display.staves[_order[j].staffIndex].info.height * renderer.scale),
          ], opacity: opacity));
        }
      }
    }
    if (!sections) return (placements: placements, labels: labels, braces: braces, brackets: const [], joins: const []);

    final brackets = <StaffBracket>[];
    final joins = <StaffJoin>[];
    double heightOf(StaffPlacement p) => display.staves[p.staffIndex].info.height * renderer.scale;
    // A staff of fewer lines (a snare drum's one) is bracketed as a five-line staff about its middle.
    ({double top, double bottom}) extentOf(StaffPlacement p) {
      final height = heightOf(p), room = math.max(height, 4 * _style.staffSpace);
      final middle = p.y + height / 2;
      return (top: middle - room / 2, bottom: middle + room / 2);
    }
    final runOf = <int, ({int start, int end, bool barlines, bool outset})>{
      for (final run in _sectionRuns)
        for (var i = run.start; i <= run.end; i++) i: run,
    };
    final shown = placed.keys.toList();
    for (var k = 1; k < shown.length; k++) {
      final above = placed[shown[k - 1]]!, below = placed[shown[k]]!;
      if (renderer.barlinesThrough[above.staffIndex] == below.staffIndex) continue; // one instrument's: its brace has it
      final run = runOf[shown[k - 1]];
      joins.add(StaffJoin(above: above, below: below, barlines: run != null && run == runOf[shown[k]] && run.barlines));
    }
    for (final run in _sectionRuns) {
      final staves = [for (var i = run.start; i <= run.end; i++) ?placed[i]];
      if (staves.isEmpty) continue;
      // Bracketed while any of its staves shows, one alone too. A staff coming or going at either
      // end takes the bracket's end with it as it fades, and the bracket fades with the last.
      final first = staves.first, last = staves.last;
      final second = staves.length > 1 ? staves[1] : first, next = staves.length > 1 ? staves[staves.length - 2] : last;
      final firstTop = extentOf(first).top, secondTop = extentOf(second).top;
      final nextBottom = extentOf(next).bottom, lastBottom = extentOf(last).bottom;
      brackets.add(StaffBracket(
          top: secondTop + (firstTop - secondTop) * first.opacity,
          bottom: nextBottom + (lastBottom - nextBottom) * last.opacity,
          opacity: staves.map((p) => p.opacity).reduce(math.max),
          outset: run.outset));
    }
    return (placements: placements, labels: labels, braces: braces, brackets: brackets, joins: joins);
  }

  // MARK: Hit testing

  /// The part whose name is under [point] in the name column.
  String? partLabelAt(ui.Offset point, double time, Curation curation, ui.Size size) {
    if (point.dx > style.headerWidth) return null;
    for (final label in layoutAt(time, curation, size).labels) {
      if (label.opacity > 0.5 && (label.centerY - point.dy).abs() < style.labelFontSize * _typography[TextKind.names].size) {
        return label.partId;
      }
    }
    return null;
  }

  void dispose() {
    _renderer?.dispose();
    _display?.dispose();
    _frozen?.dispose();
    _captionBar.dispose();
    _disposeBarNumbers();
    _disposeTempoTexts();
  }
}
