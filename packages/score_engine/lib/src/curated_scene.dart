import 'dart:io';
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
import 'score_metadata.dart';
import 'score_renderer.dart';
import 'score_text.dart';
import 'scroll_map.dart';
import 'spacing_plan.dart';
import 'staff_stack.dart';

/// A score that is engraved and ready to show.
class LoadedScore {
  LoadedScore._(this.metadata, this.engraving, this.timeline, this.beats, this.scrollMap,
      {required this.musicXML,
      required this.texts,
      required this.textEdits,
      required this.font,
      required this.options,
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
  final MusicFont font;

  /// The engraving options it was engraved with.
  final EngravingOptions options;

  /// The pairs of players that can share a staff, each engraved on one of its own (the
  /// scene shows it while both are shown and the pair is condensed).
  final List<CondensedGroup> condensed;

  /// Who could share a staff with whom, and the built-in pairs.
  final CondensingOptions condensing;

  /// The user's own pairs this was engraved with (see [CondensingOptions.pairs]).
  final List<PlayerPair> pairs;

  double get duration => scrollMap.duration;

  /// The text as currently shown (after edits).
  String currentText(ScoreText text) => textEdits[text.id] ?? text.text;

  static Future<LoadedScore> load(
    String musicXML, {
    String? resourceDirectory,
    MusicFont font = MusicFont.bravura,
    double? tempo,
    Map<String, String> textEdits = const {},
    List<PlayerPair> pairs = const [],
    EngravingOptions options = const EngravingOptions(),
  }) async {
    final doc = ScoreMetadata.parse(musicXML);
    final metadata = ScoreMetadata.fromDocument(doc);
    final prepared = PreparedScore.prepare(doc, textEdits, metadata: metadata, pairs: pairs);
    final engraving = await Engraver.engrave(
      prepared.musicXML,
      resourceDirectory: resourceDirectory ?? engineResourceDirectory(),
      font: font,
      options: options,
    );
    final timeline = ConstantTempoTimeline(engraving.measures,
        quarterNotesPerMinute: tempo ?? metadata.tempo ?? 100);
    final beats = BeatGrid(timeline.measureStarts, meters: metadata.meters, pickups: metadata.pickups);
    return LoadedScore._(metadata, engraving, timeline, beats, ScrollMap(engraving, timeline),
        musicXML: musicXML,
        texts: prepared.texts,
        textEdits: Map.unmodifiable(textEdits),
        font: font,
        options: options,
        condensed: prepared.condensed,
        condensing: prepared.condensing!,
        pairs: List.unmodifiable(pairs));
  }

  static Future<LoadedScore> open(String path, {MusicFont font = MusicFont.bravura}) async =>
      load(await ScoreFile.readMusicXML(path), font: font);

  /// Re-engraves with different text edits (the structure, and so the curation and sync, stay
  /// valid).
  Future<LoadedScore> withTextEdits(Map<String, String> edits) => withEdits(textEdits: edits);

  /// Re-engraves with different text edits, pairs of players or engraving options; what isn't
  /// given stays.
  Future<LoadedScore> withEdits({Map<String, String>? textEdits, List<PlayerPair>? pairs, EngravingOptions? options}) =>
      load(musicXML,
          font: font,
          tempo: metadata.tempo,
          textEdits: textEdits ?? this.textEdits,
          pairs: pairs ?? this.pairs,
          options: options ?? this.options);
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

/// Turns "time + the curation" into one frame.
class CuratedScene {
  CuratedScene(this.score, {RenderStyle style = const RenderStyle()}) : _style = style {
    final frozen = FrozenZone(score.engraving, style);
    display = ScoreDisplayList.build(
      score.engraving,
      style,
      withoutKeySignatures: {
        for (final part in score.metadata.parts)
          if (part.isUnpitchedPercussion) ...part.staffNumbers,
      },
      hiddenCommands: frozen.openingCommands,
    );
    renderer = ScoreRenderer(display, style, frozen: frozen);
    for (final (i, staff) in score.engraving.staves.indexed) {
      _staffIndex[staff.n] = i;
    }
  }

  final LoadedScore score;

  RenderStyle get style => _style;
  RenderStyle _style;

  /// Draws at another size: only the renderer (its tile cache and the frozen zone) starts
  /// over; the display list, the expensive part, is sized in engraving units and stays.
  void setStaffSpace(double staffSpace) {
    if (staffSpace == _style.staffSpace) return;
    _style = _style.copyWith(staffSpace: staffSpace);
    renderer.dispose();
    renderer = ScoreRenderer(display, _style, frozen: FrozenZone(score.engraving, _style));
    _plan = null;
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
    scrollMap = ScrollMap(score.engraving, timeline);
    _timelineVersion++;
  }
  late final ScoreDisplayList display;
  late ScoreRenderer renderer;
  final _staffIndex = <int, int>{};

  /// Instrument names chosen by the user (part id → name / short name), shown in the name column.
  Map<String, ({String name, String abbreviation})> names = const {};

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
    final v = {...curation.visibilityAt(time, timeline)};
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
        availableHeight: (size.height - 2 * verticalMargin).clamp(0, double.infinity),
        minGap: minGap,
        maxGap: maxGap,
      );

  /// The layout plan for this curation and frame size, rebuilt only when either changes.
  SpacingPlan _planFor(Curation curation, ui.Size size) {
    final key =
        (curation, curation.revision, curation.transition, size, verticalMargin, minGap, maxGap, _timelineVersion, _condensedVersion, _orderVersion);
    if (_plan == null || _planKey != key) {
      final pointerX = renderer.pointerX(size.width);
      _plan = SpacingPlan.build(
        staves: display.staves,
        order: _order,
        scrollMap: scrollMap,
        edges: curation.edgesInSeconds(timeline),
        isShown: (id, seconds) => _isShown(curation, id, seconds),
        twins: _twins,
        visibleLeft: pointerX / renderer.scale,
        visibleRight: (size.width - pointerX) / renderer.scale,
        transition: curation.transition,
        scale: renderer.scale,
        metrics: _metrics(size),
      );
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

  /// Draws the frame at [time]. [paper] and [ink] override the style's colours (a dark
  /// theme); changing them costs nothing (see ScoreRenderer).
  void paint(ui.Canvas canvas, ui.Size size,
      {required double time,
      required Curation curation,
      required double devicePixelRatio,
      ui.Color? paper,
      ui.Color? ink}) {
    final frame = layoutAt(time, curation, size);
    renderer.paint(canvas, size,
        scrollX: scrollMap.xAt(time),
        placements: frame.placements,
        labels: frame.labels,
        devicePixelRatio: devicePixelRatio,
        keyColumn: keyColumnAt(time, curation, size),
        paper: paper,
        ink: ink);
  }

  /// The frame at [time] as an image of [width] × [height] pixels, laid out at
  /// [devicePixelRatio] pixels per logical pixel (a video frame). It is [paint] drawn
  /// offscreen, so a video looks exactly like the preview.
  ui.Image renderFrame(int width, int height,
      {required double time,
      required Curation curation,
      required double devicePixelRatio,
      ui.Color? paper,
      ui.Color? ink}) {
    final size = ui.Size(width / devicePixelRatio, height / devicePixelRatio);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)
      ..scale(devicePixelRatio)
      ..clipRect(ui.Offset.zero & size);
    paint(canvas, size, time: time, curation: curation, devicePixelRatio: devicePixelRatio, paper: paper, ink: ink);
    final picture = recorder.endRecording();
    try {
      return picture.toImageSync(width, height);
    } finally {
      picture.dispose();
    }
  }

  /// Where every visible staff and label sits at [time]: a lookup into the plan.
  ({List<StaffPlacement> placements, List<StaffLabel> labels}) layoutAt(
      double time, Curation curation, ui.Size size) {
    final visibility = _visibilityAt(time, curation);
    final tops = [for (final y in _planFor(curation, size).topsAt(time)) y + verticalMargin];
    final parts = {for (final p in score.metadata.parts) p.id: p};

    final placements = <StaffPlacement>[];
    final labels = <StaffLabel>[];
    for (var i = 0; i < _order.length; i++) {
      final (:staffIndex, :partId) = _order[i];
      final v = (visibility[partId] ?? 0).clamp(0.0, 1.0);
      if (v <= 0) continue;
      final opacity = fadeFor(v);
      placements.add(StaffPlacement(staffIndex: staffIndex, y: tops[i], opacity: opacity));

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
            partId: group.id));
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
            partId: part.id));
      }
    }
    return (placements: placements, labels: labels);
  }

  // MARK: Hit testing (for editing in the preview)

  /// The editable score text under [point] (e.g. "arco", a tempo mark) and where it is drawn.
  ({String id, ui.Rect rect})? textAt(ui.Offset point, double time, Curation curation, ui.Size size) {
    final s = renderer.scale;
    final pointerX = renderer.pointerX(size.width);
    if (point.dx < renderer.musicLeftFor(keyColumnAt(time, curation, size))) return null;
    final scrollX = scrollMap.xAt(time);
    final x = scrollX + (point.dx - pointerX) / s;
    for (final placement in layoutAt(time, curation, size).placements) {
      final staff = display.staves[placement.staffIndex];
      final y = staff.info.top + (point.dy - placement.y) / s;
      for (final item in staff.itemsIn(x - 1, x + 1)) {
        if (item is! ParagraphItem || item.sourceId == null) continue;
        final b = item.bounds.inflate(display.data.staffSpace * 0.3);
        if (!b.contains(ui.Offset(x, y))) continue;
        final r = item.bounds;
        return (
          id: Condenser.sourceTextId(item.sourceId!), // a shared staff's copy edits the original
          rect: ui.Rect.fromLTWH(pointerX + (r.left - scrollX) * s, placement.y + (r.top - staff.info.top) * s,
              r.width * s, r.height * s),
        );
      }
    }
    return null;
  }

  /// The part whose name is under [point] in the name column.
  String? partLabelAt(ui.Offset point, double time, Curation curation, ui.Size size) {
    if (point.dx > style.headerWidth) return null;
    for (final label in layoutAt(time, curation, size).labels) {
      if (label.opacity > 0.5 && (label.centerY - point.dy).abs() < style.labelFontSize) return label.partId;
    }
    return null;
  }

  /// Ink fades in just behind the space opening up, so a staff lands in room already made.
  static double fadeFor(double v) {
    final t = ((v - 0.1) / 0.9).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  void dispose() {
    renderer.dispose();
    display.dispose();
  }
}
