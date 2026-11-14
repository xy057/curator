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
import 'lilypond_score.dart';
import 'pdf_score.dart';
import 'auto_curate.dart';
import 'beat_grid.dart';
import 'curation.dart';
import 'score_fonts.dart';
import 'score_caption.dart';
import 'score_metadata.dart';
import 'score_motion.dart';
import 'score_patch.dart';
import 'score_renderer.dart';
import 'score_text.dart';
import 'score_band.dart';
import 'score_typography.dart';
import 'scroll_map.dart';
import 'search.dart';
import 'spacers.dart';
import 'spacing_plan.dart';
import 'staff_stack.dart';

/// What a score is engraved with besides its MusicXML: the text edits, the user's own pairs of
/// players, the fonts, the engraving options, whether dynamics typed as text are made
/// dynamics, whether syllables are centred under their notes, and the spacers. Equal requests engrave a score the same, so a change of any is one to engrave.
@immutable
class EngraveRequest {
  const EngraveRequest({
    this.textEdits = const {},
    this.pairs = const [],
    this.fonts = ScoreFonts.standard,
    this.options = const EngravingOptions(),
    this.textDynamics = true,
    this.typography = ScoreTypography.standard,
    this.centeredLyrics = false,
    this.spacers = const [],
    this.gaps = const [],
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

  /// Each syllable centred under its notehead, but one an extender follows (Verovio sets
  /// them at the note's left).
  final bool centeredLyrics;

  /// Vertical spacers, each a part of its own; only what they engrave counts
  /// ([VerticalSpacer.engravesLike]).
  final List<VerticalSpacer> spacers;

  /// Horizontal spacers: blanks opened between beats.
  final List<HorizontalSpacer> gaps;

  @override
  bool operator ==(Object other) =>
      other is EngraveRequest &&
      other.spacers.length == spacers.length &&
      [for (var i = 0; i < spacers.length; i++) other.spacers[i].engravesLike(spacers[i])].every((same) => same) &&
      listEquals(other.gaps, gaps) &&
      mapEquals(other.textEdits, textEdits) &&
      listEquals(other.pairs, pairs) &&
      other.fonts == fonts &&
      other.options == options &&
      other.textDynamics == textDynamics &&
      other.centeredLyrics == centeredLyrics &&
      other.typography.engravesLike(typography);

  @override
  int get hashCode => Object.hash(textEdits.length, pairs.length, fonts, options, textDynamics, centeredLyrics, spacers.length, gaps.length);
}

/// How far opening a score has got ([LoadedScore.engrave]'s `onStage`): its file read and
/// prepared, engraved (a PDF's laid out as printed), then what it plays measured.
enum LoadStage { reading, engraving, measuring }

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
      required this.centeredLyrics,
      required this.condensed,
      required this.condensing,
      required this.pairs,
      required this.spacers,
      required this.gaps,
      this.pdf,
      this.lilypond,
      this._salience});

  final ScoreMetadata metadata;

  /// A score read from a PDF: drawn from its pages ([PdfScoreArt]), not engraved. Its
  /// [musicXML] is the score written for it ([PdfScoreLayout.musicXML]).
  final PdfScoreArt? pdf;

  /// A score LilyPond engraved: drawn as it drew it ([LilyPondScore.engraving]), not by Verovio.
  /// Its [musicXML] is the score written for it ([LilyPondScore.musicXML]).
  final LilyPondScore? lilypond;
  final EngravingData engraving;
  final ScoreTimeline timeline;
  final ScrollMap scrollMap;

  /// Where the beats fall in each bar, following the time signatures.
  final BeatGrid beats;

  /// The file as opened (edits are applied on top of it when engraving).
  final String musicXML;

  /// Every editable text in the score, as written in the file.
  final List<ScoreText> texts;

  /// How much each part's bars ask to be heard ([fittedCuratedLanes] hides the least first).
  late final BarSalience salience = _salience ?? BarSalience.of(musicXML, metadata, timeline.measureStarts);

  /// [salience] worked out while it was engraved (off the main isolate), if it was.
  final BarSalience? _salience;

  /// Text edits in effect: text id → new text ('' removes it).
  final Map<String, String> textEdits;

  /// The fonts it was engraved with.
  final ScoreFonts fonts;

  /// False when [fonts]' text font isn't installed here: Academico stands in for it.
  final bool textFontFound;

  /// The families the renderer draws it with.
  String get musicFontFamily => fonts.music.family;
  String get textFontFamily => TextFonts.familyOf(textFontFound ? fonts.text : TextFonts.academico);

  /// The engraving options it was engraved with.
  final EngravingOptions options;

  /// Whether dynamics written as text were engraved as dynamics ([TextDynamics]).
  final bool textDynamics;

  /// How its engraved texts look (its drawn ones are the scene's, [CuratedScene.typography]).
  final ScoreTypography typography;

  /// Whether its syllables were centred under their notes ([EngraveRequest.centeredLyrics]).
  final bool centeredLyrics;

  /// The pairs of players that can share a staff, each engraved on one of its own (the
  /// scene shows it while both are shown and the pair is condensed).
  final List<CondensedGroup> condensed;

  /// Who could share a staff with whom, and the built-in pairs.
  final CondensingOptions condensing;

  /// The user's own pairs this was engraved with (see [CondensingOptions.pairs]).
  final List<PlayerPair> pairs;

  /// The vertical spacers engraved as parts (their looks, but for [VerticalSpacer.key], are
  /// the scene's: [CuratedScene.spacers]) and the horizontal ones opened in the engraving.
  final List<VerticalSpacer> spacers;
  final List<HorizontalSpacer> gaps;

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
          typography: typography,
          centeredLyrics: centeredLyrics,
          spacers: spacers,
          gaps: gaps);

  /// Engraves [musicXML] as [request] asks; with [pdf], lays out that PDF score instead
  /// ([fromPdf]); with [lilypond], takes the score LilyPond engraved ([fromLilyPond]).
  ///
  /// Reading the file is done on other isolates, so a large score keeps the app drawing
  /// meanwhile; with [measure], what each bar plays ([salience], for auto-curation) is worked
  /// out there too, after (beside the engraving, its garbage would stop this isolate). [onStage]
  /// hears each step as it starts.
  static Future<LoadedScore> engrave(String musicXML, EngraveRequest request,
          {String? resourceDirectory,
          double? tempo,
          PdfScoreArt? pdf,
          LilyPondScore? lilypond,
          bool measure = false,
          void Function(LoadStage stage)? onStage}) async =>
      pdf != null
          ? await prepareFonts(request.fonts)
              .then((_) => _fromPdfApart(pdf, request, tempo: tempo, measure: measure, onStage: onStage))
          : lilypond != null
          ? await prepareFonts(request.fonts).then((fonts) => _fromLilyPondApart(lilypond, request,
              tempo: tempo, measure: measure, onStage: onStage, textFontFound: fonts.textFound))
          : await load(musicXML,
          measure: measure,
          onStage: onStage,
          resourceDirectory: resourceDirectory,
          tempo: tempo,
          fonts: request.fonts,
          textEdits: request.textEdits,
          pairs: request.pairs,
          options: request.options,
          textDynamics: request.textDynamics,
          typography: request.typography,
          centeredLyrics: request.centeredLyrics,
          spacers: request.spacers,
          gaps: request.gaps);

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
    bool centeredLyrics = false,
    List<VerticalSpacer> spacers = const [],
    List<HorizontalSpacer> gaps = const [],
    bool measure = false,
    void Function(LoadStage stage)? onStage,
  }) async {
    onStage?.call(LoadStage.reading);
    final (:metadata, :prepared, :barLengths) =
        await Isolate.run(() => _prepare(musicXML, textEdits, pairs, textDynamics, typography, options, spacers));
    // What each bar plays, from the file's bar lengths (kept only where they are the
    // engraving's).
    Future<({List<double> starts, BarSalience salience})> measured() => Isolate.run(() {
      final starts = [0.0];
      for (final length in barLengths) {
        starts.add(starts.last + length);
      }
      return (starts: starts, salience: BarSalience.of(musicXML, metadata, starts));
    });
    final resources = await prepareFonts(fonts, resourceDirectory: resourceDirectory);
    onStage?.call(LoadStage.engraving);
    final engraving = await Engraver.engrave(
      prepared.musicXML,
      resourceDirectory: resources.directory,
      font: fonts.music.isMissing ? MusicFont.bravura : fonts.music,
      options: options,
      verovioOptions: {
        ...typography.verovioOptions,
        if (centeredLyrics) 'curatedLyricCentre': true,
        if (gaps.isNotEmpty) 'curatedSpacers': ?Spacers.verovioOption(gaps, barLengths),
      },
    );
    ({List<double> starts, BarSalience salience})? salience;
    if (measure) {
      onStage?.call(LoadStage.measuring);
      salience = await measured().then<({List<double> starts, BarSalience salience})?>((s) => s, onError: (_) => null);
    }
    return _of(musicXML, metadata, prepared, engraving,
        salience: salience,
        tempo: tempo,
        textEdits: textEdits,
        fonts: fonts,
        textFontFound: resources.textFound,
        options: options,
        textDynamics: textDynamics,
        typography: typography,
        centeredLyrics: centeredLyrics,
        pairs: pairs,
        spacers: spacers,
        gaps: gaps);
  }

  /// The score [pdf] is: the score written for it ([PdfScoreLayout.musicXML]), laid out as its
  /// pages are printed ([PdfEngraving]). Of [request] only what a PDF can show counts: the
  /// spacers (a vertical one is an empty staff; horizontal ones open nothing).
  static LoadedScore fromPdf(PdfScoreArt pdf, EngraveRequest request, {double? tempo}) {
    final musicXML = pdf.layout.musicXML();
    final r = request;
    final (:metadata, :prepared, barLengths: _) =
        _prepare(musicXML, const {}, const [], false, r.typography, r.options, r.spacers);
    return _of(musicXML, metadata, prepared, PdfEngraving.of(pdf.layout, metadata),
        tempo: tempo,
        textEdits: const {},
        fonts: r.fonts,
        textFontFound: true,
        options: r.options,
        textDynamics: r.textDynamics,
        typography: r.typography,
        centeredLyrics: r.centeredLyrics,
        pairs: const [],
        spacers: r.spacers,
        gaps: r.gaps,
        pdf: pdf);
  }

  /// [fromPdf], read and laid out on another isolate (the main one only waits).
  static Future<LoadedScore> _fromPdfApart(PdfScoreArt pdf, EngraveRequest request,
      {double? tempo, bool measure = false, void Function(LoadStage stage)? onStage}) async {
    final layout = pdf.layout, r = request;
    onStage?.call(LoadStage.reading);
    final read = await Isolate.run(() {
      final musicXML = layout.musicXML();
      final (:metadata, :prepared, barLengths: _) =
          _prepare(musicXML, const {}, const [], false, r.typography, r.options, r.spacers);
      return (musicXML: musicXML, metadata: metadata, prepared: prepared, engraving: PdfEngraving.of(layout, metadata));
    });
    final starts = ConstantTempoTimeline(read.engraving.measures, quarterNotesPerMinute: 100).measureStarts;
    BarSalience? salience;
    if (measure) {
      onStage?.call(LoadStage.measuring);
      salience = await Isolate.run(() => BarSalience.of(read.musicXML, read.metadata, starts))
          .then<BarSalience?>((s) => s, onError: (_) => null);
    }
    return _of(read.musicXML, read.metadata, read.prepared, read.engraving,
        tempo: tempo,
        textEdits: const {},
        fonts: r.fonts,
        textFontFound: true,
        options: r.options,
        textDynamics: r.textDynamics,
        typography: r.typography,
        centeredLyrics: r.centeredLyrics,
        pairs: const [],
        spacers: r.spacers,
        gaps: r.gaps,
        pdf: pdf,
        salience: salience == null ? null : (starts: starts, salience: salience));
  }

  /// The score LilyPond engraved ([LilyPondScore]): the score written for it, drawn as LilyPond
  /// drew it, with a staff for each vertical spacer. Of [request] only what doesn't engrave
  /// counts, and the spacers; text edits and shared staves don't (the source says what is drawn).
  /// Its fonts must be loaded already ([prepareFonts]).
  static LoadedScore fromLilyPond(LilyPondScore lilypond, EngraveRequest request, {double? tempo}) {
    final r = request;
    final (:metadata, :prepared, barLengths: _) =
        _prepare(lilypond.musicXML, const {}, const [], false, r.typography, r.options, r.spacers);
    return _of(lilypond.musicXML, metadata, prepared, lilypond.engravingWith(metadata, r.spacers),
        tempo: tempo,
        textEdits: const {},
        fonts: r.fonts,
        textFontFound: true,
        options: r.options,
        textDynamics: r.textDynamics,
        typography: r.typography,
        centeredLyrics: r.centeredLyrics,
        pairs: const [],
        spacers: r.spacers,
        gaps: r.gaps,
        lilypond: lilypond);
  }

  /// [fromLilyPond], read on another isolate (the main one only waits); with [measure], what
  /// each bar plays measured there too. [textFontFound] false: the text font isn't installed
  /// here, and Academico draws the text (as LilyPond then sets it).
  static Future<LoadedScore> _fromLilyPondApart(LilyPondScore lilypond, EngraveRequest request,
      {double? tempo, bool measure = false, void Function(LoadStage stage)? onStage, bool textFontFound = true}) async {
    final r = request;
    onStage?.call(LoadStage.reading);
    final read = await Isolate.run(() {
      final (:metadata, :prepared, barLengths: _) =
          _prepare(lilypond.musicXML, const {}, const [], false, r.typography, r.options, r.spacers);
      return (metadata: metadata, prepared: prepared, engraving: lilypond.engravingWith(metadata, r.spacers));
    });
    final starts = ConstantTempoTimeline(read.engraving.measures, quarterNotesPerMinute: 100).measureStarts;
    BarSalience? salience;
    if (measure) {
      onStage?.call(LoadStage.measuring);
      final musicXML = lilypond.musicXML, metadata = read.metadata;
      salience = await Isolate.run(() => BarSalience.of(musicXML, metadata, starts)).then<BarSalience?>((s) => s, onError: (_) => null);
    }
    return _of(lilypond.musicXML, read.metadata, read.prepared, read.engraving,
        tempo: tempo,
        textEdits: const {},
        fonts: r.fonts,
        textFontFound: textFontFound,
        options: r.options,
        textDynamics: r.textDynamics,
        typography: r.typography,
        centeredLyrics: r.centeredLyrics,
        pairs: const [],
        spacers: r.spacers,
        gaps: r.gaps,
        lilypond: lilypond,
        salience: salience == null ? null : (starts: starts, salience: salience));
  }

  /// [musicXML] engraved beforehand with [request] as [engraving] ([EngravingFile]): where there is
  /// no engraver. Its fonts must be loaded already ([MusicFont.load], [TextFonts]).
  static LoadedScore engraved(String musicXML, EngraveRequest request, EngravingData engraving,
      {double? tempo, bool textFontFound = true}) {
    final r = request;
    final (:metadata, :prepared, barLengths: _) =
        _prepare(musicXML, r.textEdits, r.pairs, r.textDynamics, r.typography, r.options, r.spacers);
    return _of(musicXML, metadata, prepared, engraving,
        tempo: tempo,
        textEdits: r.textEdits,
        fonts: r.fonts,
        textFontFound: textFontFound,
        options: r.options,
        textDynamics: r.textDynamics,
        typography: r.typography,
        centeredLyrics: r.centeredLyrics,
        pairs: r.pairs,
        spacers: r.spacers,
        gaps: r.gaps);
  }

  /// What Verovio is given for [musicXML]: the spacers' parts written in, the edits applied.
  static ({ScoreMetadata metadata, PreparedScore prepared, List<double> barLengths}) _prepare(
      String musicXML,
      Map<String, String> textEdits,
      List<PlayerPair> pairs,
      bool textDynamics,
      ScoreTypography typography,
      EngravingOptions options,
      List<VerticalSpacer> spacers) {
    final doc = ScoreMetadata.parse(musicXML);
    Spacers.write(doc, spacers);
    final metadata = ScoreMetadata.fromDocument(doc);
    final prepared = PreparedScore.prepare(doc, textEdits,
        metadata: metadata,
        pairs: pairs,
        textDynamics: textDynamics,
        typography: typography,
        textSize: (options.valueOf(EngraveOption.byKey('lyricSize')!) as num).toDouble());
    return (metadata: metadata, prepared: prepared, barLengths: Spacers.barLengths(doc));
  }

  static LoadedScore _of(String musicXML, ScoreMetadata metadata, PreparedScore prepared, EngravingData engraving,
      {required double? tempo,
      required Map<String, String> textEdits,
      required ScoreFonts fonts,
      required bool textFontFound,
      required EngravingOptions options,
      required bool textDynamics,
      required ScoreTypography typography,
      required bool centeredLyrics,
      required List<PlayerPair> pairs,
      required List<VerticalSpacer> spacers,
      required List<HorizontalSpacer> gaps,
      PdfScoreArt? pdf,
      LilyPondScore? lilypond,
      ({List<double> starts, BarSalience salience})? salience}) {
    final timeline = ConstantTempoTimeline(engraving.measures,
        quarterNotesPerMinute: tempo ?? metadata.tempo ?? 100);
    final starts = timeline.measureStarts;
    final measured = salience != null &&
        salience.starts.length == starts.length &&
        [for (var i = 0; i < starts.length; i++) (salience.starts[i] - starts[i]).abs() < 1e-6].every((same) => same);
    final beats = BeatGrid(timeline.measureStarts, meters: metadata.meters, pickups: metadata.pickups);
    return LoadedScore._(metadata, engraving, timeline, beats, ScrollMap(engraving, timeline, beats: beats),
        musicXML: musicXML,
        texts: prepared.texts,
        textEdits: Map.unmodifiable(textEdits),
        fonts: fonts,
        textFontFound: textFontFound,
        options: options,
        textDynamics: textDynamics,
        typography: typography,
        centeredLyrics: centeredLyrics,
        // A PDF has no staff two players could share, nor has LilyPond drawn one.
        condensed: pdf != null || lilypond != null ? const [] : prepared.condensed,
        condensing: prepared.condensing!,
        pairs: List.unmodifiable(pairs),
        spacers: List.unmodifiable(spacers),
        gaps: List.unmodifiable(gaps),
        pdf: pdf,
        lilypond: lilypond,
        salience: measured ? salience.salience : null);
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

  /// Re-engraves as [request] asks (the structure, and so the curation and sync, stay valid).
  Future<LoadedScore> withRequest(EngraveRequest request) =>
      engrave(musicXML, request, tempo: metadata.tempo, pdf: pdf, lilypond: lilypond);
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
    this.instrumentSpacing = const {},
    this.barNumbers = false,
    this.rehearsalInRow = true,
    this.nameColors = const {},
    this.pointerColor,
    this.motion = ScoreMotion.standard,
    this.typography = ScoreTypography.standard,
    this.spacers = const [],
    this.bands = const [],
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
  final Map<String, ({double above, double below})> instrumentSpacing;
  final bool barNumbers;
  final bool rehearsalInRow;
  final Map<String, ui.Color> nameColors;
  final ui.Color? pointerColor;
  final ScoreMotion motion;
  final ScoreTypography typography;
  final List<VerticalSpacer> spacers;
  final List<ScoreBand> bands;
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
      if (part.staffNumbers.length > 1) {
        for (final (j, n) in part.staffNumbers.indexed) {
          if (_staffIndex[n] case final i?) _staffOfPart[i] = j + 1;
        }
      }
    }
  }

  /// Staff index → which staff of its instrument it is (1 the top one), for instruments on
  /// more than one staff: what a region's [Region.hiddenStaves] name.
  final _staffOfPart = <int, int>{};

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
    _disposeKeyNames();
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
  ScoreDisplayList get display => _display ??= score.pdf != null
      ? PdfEngraving.displayList(score.pdf!, score.engraving, score.metadata, spacers: {
          for (final MapEntry(key: n, value: look) in _spacerStaves.entries) n: (height: look.shownHeight, lines: look.lines),
        })
      : ScoreDisplayList.build(
        score.engraving,
        _style,
        withoutKeySignatures: {
          for (final part in score.metadata.parts)
            if (part.isUnpitchedPercussion) ...part.staffNumbers,
        },
        hiddenCommands: _openingCommands,
        apart: barNumbers ? {..._tempoIds, if (rehearsalInRow) ..._rehearsalIds} : const {},
        spacers: {
          for (final MapEntry(key: n, value: look) in _spacerStaves.entries) n: (height: look.shownHeight, lines: look.lines),
        },
      );
  ScoreDisplayList? _display;
  int _displayVersion = 0;

  ScoreRenderer get renderer => _renderer ??= () {
        final display = this.display;
        final frozen = _frozen ?? FrozenZone(score.engraving, _style, typography: score.typography);
        _frozen = null; // the renderer's now
        return ScoreRenderer(display, _style, frozen: frozen, barlinesThrough: _barlinesThrough, bare: _bareStaves)
          ..names = _typography[TextKind.names];
      }();
  ScoreRenderer? _renderer;

  /// A frozen zone made for its opening commands, kept for the first renderer.
  FrozenZone? _frozen;
  late final Set<int> _openingCommands =
      (_frozen ??= FrozenZone(score.engraving, _style, typography: score.typography)).openingCommands;
  final _staffIndex = <int, int>{};

  /// Instrument names chosen by the user (part id → name / short name), shown in the name column.
  Map<String, ({String name, String abbreviation})> names = const {};

  /// Everything set on the scene ([names], [condensed], [partOrder], [scrollFollow],
  /// [patches], [captions], [captionStyle], [sections], [sectionOverrides], [instrumentSpacing], [barNumbers],
  /// [rehearsalInRow], [nameColors], [pointerColor], [motion], [typography], [spacers], [bands]);
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
      instrumentSpacing: instrumentSpacing,
      barNumbers: barNumbers,
      rehearsalInRow: rehearsalInRow,
      nameColors: nameColors,
      pointerColor: pointerColor,
      motion: motion,
      typography: typography,
      spacers: spacers,
      bands: bands);
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
    instrumentSpacing = value.instrumentSpacing;
    barNumbers = value.barNumbers;
    rehearsalInRow = value.rehearsalInRow;
    nameColors = value.nameColors;
    pointerColor = value.pointerColor;
    motion = value.motion;
    typography = value.typography;
    spacers = value.spacers;
    bands = value.bands;
  }

  /// How the vertical spacers look (their height, lines and frozen zone; their key is the
  /// score's, [LoadedScore.spacers]). A change makes the display list again.
  List<VerticalSpacer> get spacers => _spacers;
  List<VerticalSpacer> _spacers = const [];
  set spacers(List<VerticalSpacer> value) {
    if (listEquals(value, _spacers)) return;
    final before = _spacerStaves;
    _spacers = List.unmodifiable(value);
    _spacerStaves = _spacerStavesOf(value);
    if (!mapEquals(before, _spacerStaves)) _remakeDisplay();
  }

  /// Each engraved vertical spacer's staff number → how it looks.
  late Map<int, VerticalSpacer> _spacerStaves = _spacerStavesOf(_spacers);

  Map<int, VerticalSpacer> _spacerStavesOf(List<VerticalSpacer> looks) {
    final byId = {for (final s in looks) s.id: s};
    return {
      for (final p in score.metadata.parts)
        if (Spacers.isSpacer(p.id)) p.staffNumbers.first: byId[p.id] ?? VerticalSpacer(id: p.id),
    };
  }

  /// Staff indices of the spacers whose clef, key and time the frozen zone doesn't draw: not
  /// shown there, or without lines.
  Set<int> get _bareStaves => {
        for (final MapEntry(key: n, value: look) in _spacerStaves.entries)
          if ((!look.frozen || !look.lines) && _staffIndex[n] != null) _staffIndex[n]!,
        // A PDF score's blank lanes ([PdfInstrument.blank]).
        if (score.pdf?.layout case final layout?)
          for (final p in score.metadata.parts)
            if (layout.playerOf(p.id)?.$1.blank ?? false)
              for (final n in p.staffNumbers)
                if (_staffIndex[n] != null) _staffIndex[n]!,
      };

  /// Whether [partId] is a vertical spacer the frozen zone doesn't name, or a PDF score's blank
  /// lane.
  bool _unnamed(String partId) =>
      (Spacers.isSpacer(partId) && !(_spacers.where((s) => s.id == partId).firstOrNull?.frozen ?? false)) ||
      (score.pdf?.layout.playerOf(partId)?.$1.blank ?? false);

  /// How the score moves (Project Settings ▸ Animation): the staves' spacing, glides and fades, the scroll's
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
    if (value[TextKind.barNumbers] != old[TextKind.barNumbers] || value[TextKind.rehearsal] != old[TextKind.rehearsal]) {
      _disposeBarNumbers();
    }
    if (value[TextKind.tempoRow] != old[TextKind.tempoRow]) _disposeTempoTexts();
    if (value[TextKind.tonality] != old[TextKind.tonality]) _disposeKeyNames();
    if (value[TextKind.captions] != old[TextKind.captions]) {
      _captionBar.dispose();
      _captionBar = CaptionBar(_style.textFontFamily, _captionBar.style, value[TextKind.captions]);
    }
  }

  /// The colour some instruments are named in, by part id (a pair in its first player's); one
  /// left out is named in the ink.
  Map<String, ui.Color> nameColors = const {};

  /// The playback line's colour; null: [RenderStyle.pointer].
  ui.Color? pointerColor;

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

  /// Room added above and below an instrument (negative: taken away), staff spaces, by part
  /// id: the user's, over what its ink needs. Changing it re-plans the layout.
  Map<String, ({double above, double below})> get instrumentSpacing => _instrumentSpacing;
  Map<String, ({double above, double below})> _instrumentSpacing = const {};
  set instrumentSpacing(Map<String, ({double above, double below})> value) {
    if (mapEquals(value, _instrumentSpacing)) return;
    _instrumentSpacing = Map.unmodifiable(value);
    _spacingVersion++;
  }

  int _spacingVersion = 0;

  /// Free space above the first and below the last staff ([ScoreMotion.margin]).
  double get verticalMargin => _motion.margin;

  /// Where the staves' room starts in a frame: under the top margin, and under the tonality
  /// band while there is one.
  double get _top => verticalMargin + _bandReserve;

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

  /// Whether staff [k] of [_order] is shown at [seconds]: its instrument ([_isShown]), and not
  /// left out by the region showing it ([Region.hiddenStaves]).
  bool _isStaffShown(Curation curation, int k, double seconds) {
    final (:staffIndex, :partId) = _order[k];
    if (!_isShown(curation, partId, seconds)) return false;
    final n = _staffOfPart[staffIndex];
    return n == null || !curation.hiddenStavesAt(partId, seconds, timeline).contains(n);
  }

  /// 0…1: how much of staff [k] of [_order] its instrument's regions show ([Curation.staffVisibilityAt]).
  double _staffVisibility(Curation curation, int k, double time) {
    final (:staffIndex, :partId) = _order[k];
    final n = _staffOfPart[staffIndex];
    return n == null ? 1 : curation.staffVisibilityAt(partId, n, time, timeline, curve: _motion.fade);
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
        availableHeight: (size.height - 2 * verticalMargin - _captionReserve - _bandReserve).clamp(0, double.infinity),
        minGap: _motion.minGap,
        maxGap: math.max(_motion.minGap, _motion.maxGap),
      );

  /// What a plan for this curation and frame size is made from: a new key, a new plan.
  Object _planKeyFor(Curation curation, ui.Size size) =>
      (curation, curation.revision, curation.transition, size, verticalMargin, _motion.minGap, _motion.maxGap, _timelineVersion, _condensedVersion, _orderVersion, _spacingVersion, _captionReserve, _bandReserve, _displayVersion, _motion.glide);

  SpacingPlan _buildPlan(Curation curation, ui.Size size) {
    final pointerX = renderer.pointerX(size.width);
    final top = _top; // the plan's 0 in the frame
    return SpacingPlan.build(
      staves: display.staves,
      order: _order,
      scrollMap: scrollMap,
      edges: curation.edgesInSeconds(timeline),
      isShown: (k, seconds) => _isStaffShown(curation, k, seconds),
      spacing: {
        for (final MapEntry(key: id, value: (:above, :below)) in _instrumentSpacing.entries)
          id: (above: above * display.data.staffSpace * renderer.scale, below: below * display.data.staffSpace * renderer.scale),
      },
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

  /// [partIds]' lanes as auto-curation fills them, cut back where notation would run off a
  /// frame of [size] ([fittedCuratedLanes]); the other lanes of [curation] stay as they are.
  /// [activeMeasures] and [salience] are the lanes' own (a pair's: either player's).
  Map<String, List<Region>> curatedToFit(Curation curation, ui.Size size,
      {required Iterable<String> partIds, required Map<String, List<bool>> activeMeasures, required BarSalience salience}) {
    final ids = partIds.toSet();
    final trial = Curation(curation.partIds)
      ..load({for (final id in curation.partIds) id: curation.lane(id)}, transition: curation.transition)
      ..join(curation.joined);
    return fittedCuratedLanes(
      partIds: ids,
      activeMeasures: activeMeasures,
      measureStarts: timeline.measureStarts,
      salience: salience,
      timeline: timeline,
      others: {
        for (final id in curation.partIds)
          if (!ids.contains(id) && !ids.contains(curation.joined[id])) id: curation.lane(id), // a follower follows
      },
      overflowing: (lanes) => overflowing(trial..setLanes(lanes), size),
    );
  }

  /// The layout plan for this curation and frame size, rebuilt only when either changes.
  SpacingPlan _planFor(Curation curation, ui.Size size) {
    final key = _planKeyFor(curation, size);
    if (_plan == null || _planKey != key) {
      final pointerX = renderer.pointerX(size.width);
      _plan = _buildPlan(curation, size);
      final zone = renderer.frozen, bare = renderer.bare;
      final kept = [for (final (k, s) in _order.indexed) if (!bare.contains(s.staffIndex)) k];
      _keyPlan = zone == null
          ? null
          : KeyColumnPlan.build(
              zone: zone,
              staves: display.staves,
              order: [for (final s in _order) if (!bare.contains(s.staffIndex)) s],
              scrollMap: scrollMap,
              edges: curation.edgesInSeconds(timeline),
              isShown: (k, seconds) => _isStaffShown(curation, kept[k], seconds),
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
    final keyColumn = keyColumnAt(time, curation, size);
    renderer.paint(canvas, size,
        scrollX: scrollX,
        placements: frame.placements,
        labels: frame.labels,
        braces: frame.braces,
        brackets: frame.brackets,
        joins: frame.joins,
        outsetBrackets: sections && _sectionRuns.any((r) => r.outset),
        devicePixelRatio: devicePixelRatio,
        keyColumn: keyColumn,
        paper: paper,
        ink: ink,
        pointer: pointerColor,
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
                  patch.paint(canvas, rect, inkColor: ink ?? style.ink, time: time);
                }
                canvas.restore();
              });
    if (barNumbers) _paintTempo(canvas, size, scrollX, ink ?? style.ink, rowShift);
    if (captions.isNotEmpty) {
      _captionBar.paint(canvas, size, time, _captionSpans, captions, ink ?? style.ink, motion: _motion, paper: paperColor);
    }
    if (_bands.isNotEmpty) _paintBand(canvas, size, scrollX, renderer.musicLeftFor(keyColumn));
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

  // MARK: Tonality

  /// The band along the frame's top (an extension's `band` socket; Tonality's key areas), which
  /// the staves leave room for while it has any stretch. Each is drawn in its [ScoreBand.color]
  /// from its start to its end (a sliver of paper between two that meet; none where none is),
  /// named at its start by its [ScoreBand.label]. Over the names and the frozen zone the band
  /// shows the stretch the music at their right is in, named at the frame's left, as the zone
  /// shows that music's key signature; one gives way to the next (or to none) over
  /// [ScoreMotion.tempoFade] staff spaces of scroll, as the tempo at the left does.
  List<ScoreBand> get bands => _bands;
  List<ScoreBand> _bands = const [];
  set bands(List<ScoreBand> value) {
    if (listEquals(value, _bands)) return;
    _bands = List.unmodifiable(value);
    _keyXs = null;
  }

  /// Where each stretch of the band starts and ends, engraving x: at a bar's start its barline (the bar's
  /// left is past a key signature it starts with), else the score x of its place.
  List<({double start, double end})>? _keyXs;

  /// The band's text size, points: as the bar numbers', [TextKind.tonality]'s size times.
  double get _bandFont => _style.staffSpace * 1.25 * _typography[TextKind.tonality].size;

  /// The band's height, points.
  double get _bandHeight => (_bandFont * 1.9).roundToDouble();

  /// Room the staves leave for the band: none while it is empty.
  double get _bandReserve => _bands.isEmpty ? 0 : _bandHeight;

  double _xOfPlace(double at) {
    final starts = score.timeline.measureStarts, measures = score.engraving.measures;
    final m = segmentAt(starts.length, at + 1e-9, (i) => starts[i]);
    if (m < measures.length && (starts[m] - at).abs() < 1e-6) return m > 0 ? measures[m - 1].right : measures[0].left;
    return axis.xAt(at);
  }

  final _keyNames = <String, ui.Paragraph>{};

  /// [text] laid out as [TextKind.tonality] looks, in the paper's white.
  ui.Paragraph _keyName(String text) {
    if (_keyNames[text] case final name?) return name;
    if (_keyNames.length >= 64) _disposeKeyNames(); // markings of the user's, typed one by one
    final look = _typography[TextKind.tonality], fontSize = _bandFont;
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
        fontFamily: _style.textFontFamily,
        fontSize: fontSize,
        fontStyle: look.face.fontStyle,
        fontWeight: look.face.fontWeight,
        maxLines: 1))
      ..pushStyle(ui.TextStyle(color: ui.Color.fromRGBO(255, 255, 255, look.opacity), letterSpacing: look.spacingAt(fontSize)))
      ..addText(text);
    return _keyNames[text] = builder.build()..layout(const ui.ParagraphConstraints(width: double.infinity));
  }

  void _disposeKeyNames() {
    for (final p in _keyNames.values) {
      p.dispose();
    }
    _keyNames.clear();
  }

  void _paintBand(ui.Canvas canvas, ui.Size size, double scrollX, double musicLeft) {
    final areas = _bands, xs = _keyXs ??= [for (final a in areas) (start: _xOfPlace(a.start), end: _xOfPlace(a.end))];
    if (score.engraving.measures.isEmpty) return;
    final scale = renderer.scale, sp = _style.staffSpace;
    final height = _bandHeight, gap = math.max(1.0, sp * 0.12), pad = sp * 0.6;
    final pointerX = renderer.pointerX(size.width), originX = pointerX - scrollX * scale;

    void area(int i, ui.Rect rect, double nameX) {
      canvas
        ..save()
        ..clipRect(rect)
        ..drawRect(rect, ui.Paint()..color = areas[i].color);
      final name = _keyName(areas[i].label);
      canvas
        ..drawParagraph(name, ui.Offset(nameX, (height - name.height) / 2))
        ..restore();
    }

    // The music's part, scrolling with it: each area named at its start.
    canvas
      ..save()
      ..clipRect(ui.Rect.fromLTRB(musicLeft, 0, size.width, height));
    for (var i = 0; i < areas.length; i++) {
      // Paper between two that meet, so two areas of one key are two.
      final meets = i + 1 < areas.length && (areas[i + 1].start - areas[i].end).abs() < 1e-6;
      final left = originX + xs[i].start * scale, right = originX + xs[i].end * scale - (meets ? gap : 0);
      if (right <= math.max(left, musicLeft) || left >= size.width) continue;
      area(i, ui.Rect.fromLTRB(left, 0, right, height), left + pad);
    }
    canvas.restore();

    // Over the names and the frozen zone: the key the music is in where it starts.
    final edgeX = scrollX - (pointerX - musicLeft) / scale;
    final fade = _motion.tempoFade * display.data.staffSpace, curve = _motion.tempoCurve;
    double arrived(double x) {
      final past = edgeX - x;
      return fade > 0 ? curve.inside(past / fade + 0.5) : (past >= 0 ? 1.0 : 0.0);
    }

    for (var i = 0; i < areas.length; i++) {
      final opacity = arrived(xs[i].start) * (1 - arrived(xs[i].end));
      if (opacity <= 0.001) continue;
      if (opacity < 0.999) canvas.saveLayer(null, ui.Paint()..color = ui.Color.fromRGBO(0, 0, 0, opacity));
      area(i, ui.Rect.fromLTRB(0, 0, musicLeft, height), pad + 2);
      if (opacity < 0.999) canvas.restore();
    }

    // The playhead runs on through the band.
    canvas.drawRect(ui.Rect.fromLTWH(pointerX - _style.pointerWidth / 2, 0, _style.pointerWidth, height),
        ui.Paint()..color = pointerColor ?? _style.pointer);
  }

  // MARK: Bar numbers

  /// Whether every bar's number is shown at its top left, small, grey and italic, in a row
  /// above the staves that stays put as they come and go, the rehearsal marks in it at their bars,
  /// and the tempo marks at the frame's left in that row (both set apart from the music: the
  /// display list is made again).
  bool get barNumbers => _barNumbers;
  bool _barNumbers = false;
  set barNumbers(bool value) {
    if (value == _barNumbers) return;
    _barNumbers = value;
    if (_tempoIds.isNotEmpty || (rehearsalInRow && _rehearsalIds.isNotEmpty)) _remakeDisplay();
  }

  /// Whether, while [barNumbers] shows the row, the rehearsal marks leave the music for their
  /// bars in it (Project Settings ▸ Flags).
  bool get rehearsalInRow => _rehearsalInRow;
  bool _rehearsalInRow = true;
  set rehearsalInRow(bool value) {
    if (value == _rehearsalInRow) return;
    _rehearsalInRow = value;
    if (barNumbers && _rehearsalIds.isNotEmpty) _remakeDisplay();
  }

  /// The display list made again, lazily, with what is set apart now (and the plan with it).
  void _remakeDisplay() {
    if (_display == null) return;
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

  /// Each bar's rehearsal mark as shown, by measure index: drawn in the bar numbers' row.
  late final _rehearsals = <int, String>{
    for (final text in score.texts.reversed)
      if (text.kind == ScoreTextKind.rehearsal && score.currentText(text).trim().isNotEmpty)
        text.measure: score.currentText(text).trim(),
  };

  /// Every rehearsal mark's id, and its copy's on a pair's shared staff → its own: set apart
  /// from the music while the row shows them.
  late final _rehearsalIds = {
    for (final text in score.texts)
      if (text.kind == ScoreTextKind.rehearsal) ...{text.id: text.id, '${Condenser.idPrefix}${text.id}': text.id},
  };

  final _barNumberText = <String, ui.Paragraph>{};
  final _rehearsalText = <String, ui.Paragraph>{};

  /// A rehearsal mark laid out as [TextKind.rehearsal] looks: bold unless the user chose a
  /// face, larger than the bar numbers.
  ui.Paragraph _rehearsal(String mark) => _rehearsalText.putIfAbsent(mark, () {
        final look = _typography[TextKind.rehearsal], fontSize = _style.staffSpace * 1.8 * look.size;
        final face = look.face == TextFace.asWritten ? TextFace.bold : look.face;
        final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
            fontFamily: _style.textFontFamily,
            fontSize: fontSize,
            fontStyle: face.fontStyle,
            fontWeight: face.fontWeight,
            maxLines: 1))
          ..pushStyle(ui.TextStyle(color: const ui.Color(0xFF000000), letterSpacing: look.spacingAt(fontSize)))
          ..addText(mark);
        return builder.build()..layout(const ui.ParagraphConstraints(width: double.infinity));
      });

  /// Where a rehearsal mark's box is drawn with its left at [x], its bottom at the row's.
  ({ui.Rect box, ui.Offset text}) _rehearsalBox(ui.Paragraph text, double x, double bottom) {
    final fontSize = _style.staffSpace * 1.8 * _typography[TextKind.rehearsal].size;
    final pad = fontSize * 0.28, capHeight = fontSize * 0.7;
    final height = capHeight + 2 * pad, width = math.max(text.longestLine + 2 * pad, height);
    final box = ui.Rect.fromLTWH(x, bottom - height, width, height);
    final baseline = bottom - pad;
    return (box: box, text: ui.Offset(box.center.dx - text.longestLine / 2, baseline - text.alphabeticBaseline));
  }

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
    for (final p in [..._barNumberText.values, ..._rehearsalText.values]) {
      p.dispose();
    }
    _barNumberText.clear();
    _rehearsalText.clear();
  }

  /// The row's bottom in a frame, before any move: just above the room the staves have.
  double get _rowBottom => _top - 6;

  /// The highest the row's top may go: near the top, under the tonality band.
  double get _rowTopLimit => _bandReserve + 4.0;

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
    final scale = renderer.scale, clear = _rowBottom + 3 - _top;
    double? left, right;
    var need = 0.0, checked = 0;
    for (var i = 0; i < _order.length && checked < 2; i++) {
      // Shown or not, no fade: cheaper, and a staff only fading in counts a little early.
      if (!_isStaffShown(curation, i, time)) continue;
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
    // A rehearsal mark, in full ink, stands at its bar's left; the bar's number goes after it.
    final marks = <int, ({ui.Rect box, ui.Offset text})>{};
    for (var m = 0; m < measures.length; m++) {
      final bar = measures[m];
      if (bar.right < left) continue;
      if (bar.left > right) break;
      if (rehearsalInRow ? _rehearsals[m] : null case final mark?) {
        marks[m] = _rehearsalBox(_rehearsal(mark), originX + bar.left * scale + sp * 0.3, _rowBottom - shift + 1);
      }
    }
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
      final x = marks[m]?.box.right ?? originX + bar.left * scale;
      canvas.drawParagraph(text, ui.Offset(x + sp * 0.3, _rowBottom - shift - text.height));
    }
    canvas.restore();
    if (marks.isEmpty) return;
    final line = ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = sp * 0.16 * _typography[TextKind.rehearsal].size
      ..color = ink;
    for (final MapEntry(key: m, value: (:box, :text)) in marks.entries) {
      final mark = _rehearsal(_rehearsals[m]!);
      canvas
        ..drawRect(box, line)
        ..saveLayer(null, ui.Paint()..colorFilter = ui.ColorFilter.mode(ink, ui.BlendMode.srcIn))
        ..drawParagraph(mark, text)
        ..restore();
    }
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

  /// Frame x (points) of score quarter [quarter] at [time]: [quarterAtFrameX] the other way.
  double frameXAtQuarter(double quarter, double time, ui.Size size) =>
      renderer.pointerX(size.width) + (axis.xAt(quarter) - scrollMap.xAt(time)) * renderer.scale;

  // MARK: Spacers

  /// Where each vertical spacer shown at [time] is in a frame of [size] (points): its height,
  /// from where the music starts to the frame's right edge. The editor outlines them.
  List<({String id, ui.Rect rect, double opacity})> spacerRects(double time, Curation curation, ui.Size size) =>
      [for (final r in staffRects(time, curation, size)) if (Spacers.isSpacer(r.id)) r];

  /// Where each staff shown at [time] is in a frame of [size] (points), top to bottom, by part id
  /// (a pair's shared staff by its own): its lines (a spacer's height), from where the music
  /// starts to the frame's right edge.
  List<({String id, ui.Rect rect, double opacity})> staffRects(double time, Curation curation, ui.Size size) {
    final frame = layoutAt(time, curation, size);
    final ids = {for (final s in _order) s.staffIndex: s.partId};
    final left = renderer.musicLeftFor(keyColumnAt(time, curation, size)), scale = renderer.scale;
    return [
      for (final p in frame.placements)
        if (ids[p.staffIndex] case final id?)
          (
            id: id,
            rect: ui.Rect.fromLTRB(left, p.y - display.staves[p.staffIndex].reach * scale, size.width,
                p.y + (display.staves[p.staffIndex].info.height + display.staves[p.staffIndex].reach) * scale),
            opacity: p.opacity,
          ),
    ]..sort((a, b) => a.rect.top.compareTo(b.rect.top));
  }

  /// Where each horizontal spacer ([LoadedScore.gaps], by index) is at [time] in a frame of
  /// [size] (points): the stretch it widens, between the margins. The editor outlines them.
  List<({int index, ui.Rect rect})> gapRects(double time, ui.Size size) {
    final starts = score.timeline.measureStarts;
    return [
      for (final (i, gap) in score.gaps.indexed)
        if (gap.bar >= 0 && gap.bar < starts.length - 1)
          (
            index: i,
            rect: ui.Rect.fromLTRB(frameXAtQuarter(starts[gap.bar] + gap.offset, time, size), _top,
                frameXAtQuarter(starts[gap.bar] + gap.offset + gap.length, time, size), size.height - verticalMargin),
          ),
    ];
  }

  /// Reads ahead what a frame of [size] at [time] and the next screenful draw (a PDF score's
  /// systems, [PdfScoreArt]), so playing on finds them ready; asks and doesn't wait. An
  /// engraved score's always are.
  void buffer(double time, ui.Size size) {
    final pdf = score.pdf;
    if (pdf == null) return;
    final (left, right) = renderer.visibleRange(scrollMap.xAt(time), size.width);
    pdf.load(PdfEngraving.systemsIn(pdf.layout, score.engraving, left, right + (right - left)), holder: this).ignore();
  }

  /// The frame at [time] as an image of [width] × [height] pixels, laid out at
  /// [devicePixelRatio] pixels per logical pixel (a video frame). It is [paint] drawn
  /// offscreen, so a video looks exactly like the preview.
  /// Waits until everything a frame of [size] at [time] draws is ready: a PDF score's systems
  /// read ([PdfScoreArt.load]), the ones just ahead too. An engraved score's always are.
  /// They are kept for [holder] (this scene, when none is given) until it asks again or lets
  /// go ([PdfScoreArt.release]): frames got ready side by side each hold their own.
  Future<void> ready(double time, ui.Size size, {Object? holder}) async {
    final pdf = score.pdf;
    if (pdf == null) return;
    final (left, right) = renderer.visibleRange(scrollMap.xAt(time), size.width);
    await pdf.load(PdfEngraving.systemsIn(pdf.layout, score.engraving, left, right + (right - left) * 0.25), holder: holder ?? this);
  }

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
    final tops = [for (final y in _planFor(curation, size).topsAt(time)) y + _top];
    final parts = {for (final p in score.metadata.parts) p.id: p};

    final placements = <StaffPlacement>[];
    final labels = <StaffLabel>[];
    final braces = <StaffBrace>[];
    final placed = <int, StaffPlacement>{}; // order index → its placement
    // How much of each staff its regions show: a staff left out fades within its instrument.
    final staffShown = [for (var i = 0; i < _order.length; i++) _staffVisibility(curation, i, time)];
    for (var i = 0; i < _order.length; i++) {
      final (:staffIndex, :partId) = _order[i];
      final v = (visibility[partId] ?? 0).clamp(0.0, 1.0);
      if (v <= 0) continue;
      final opacity = _motion.inkFor(v);
      if (staffShown[i] > 0) {
        placements.add(placed[i] = StaffPlacement(staffIndex: staffIndex, y: tops[i], opacity: _motion.inkFor(v * staffShown[i])));
      }

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
      if (staves.first == display.staves[staffIndex].info.n && !_unnamed(part.id)) {
        final last = i + staves.length - 1;
        double heightOf(int j) => display.staves[_order[j].staffIndex].info.height * renderer.scale;
        // Named and braced over the staves its regions show, a staff fading in or out counting
        // as much as it shows (the brace closing onto the rest as it goes).
        var weight = 0.0, centre = 0.0, most = 0.0;
        for (var j = i; j <= last; j++) {
          weight += staffShown[j];
          centre += (tops[j] + heightOf(j) / 2) * staffShown[j];
          most = math.max(most, staffShown[j]);
        }
        if (weight <= 0) continue;
        final named = names[part.id];
        labels.add(StaffLabel(
            text: named?.name ?? part.name,
            shortText: named?.abbreviation ?? part.abbreviation,
            centerY: centre / weight,
            opacity: opacity,
            partId: part.id,
            color: nameColors[part.id]));
        final braced = (weight - most).clamp(0.0, 1.0);
        if (staves.length > 1 && braced > 0) {
          braces.add(StaffBrace(staves: [
            for (var j = i; j <= last; j++)
              if (staffShown[j] > 0) (top: tops[j], height: heightOf(j) * staffShown[j]),
          ], opacity: opacity * braced));
        }
      }
    }
    // An instrument's barlines run on between its staves shown (a PDF's are in its pictures).
    final joins = <StaffJoin>[];
    if (display.strokes == null) {
      final shownStaves = placed.keys.toList();
      for (var k = 1; k < shownStaves.length; k++) {
        final (a, b) = (shownStaves[k - 1], shownStaves[k]);
        if (_order[a].partId != _order[b].partId || _staffOfPart[_order[a].staffIndex] == null) continue;
        joins.add(StaffJoin(above: placed[a]!, below: placed[b]!, barlines: true, start: false));
      }
    }
    if (!sections) return (placements: placements, labels: labels, braces: braces, brackets: const [], joins: joins);

    final brackets = <StaffBracket>[];
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
      if (_order[shown[k - 1]].partId == _order[shown[k]].partId) continue; // one instrument's: joined above
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
    score.pdf?.release(this); // the systems it drew may go
    _renderer?.dispose();
    _display?.dispose();
    _frozen?.dispose();
    _captionBar.dispose();
    _disposeBarNumbers();
    _disposeTempoTexts();
    _disposeKeyNames();
  }
}
