import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:score_engine/score_engine.dart';

import 'project_state.dart';

/// Score ▸ Replace Score…: how a project made for one score file reads against another, and
/// what differs between them.
///
/// Instruments are matched by name and id ([parts]), so a part that moved (an instrument
/// added above it renumbers it) keeps its lane, name, pair and place; texts by where they are
/// and what they say ([textEdits]); positions by bar and the distance into it ([quarterAt]),
/// so a bar that changed length keeps what starts in it. What has no place in the new file is
/// left out and counted ([differences]).
class ScoreSwap {
  ScoreSwap({required this.before, required this.after, required this.textsBefore, required this.textsAfter})
    : parts = _matchParts(before.parts, after.parts);

  final ScoreMetadata before, after;

  /// Every editable text of each file, as written.
  final List<ScoreText> textsBefore, textsAfter;

  /// Old part id → new part id, for every instrument found in both files.
  final Map<String, String> parts;

  /// Matched by id and name, then by name (in score order), then by id alone (renamed).
  static Map<String, String> _matchParts(List<ScorePart> before, List<ScorePart> after) {
    final out = <String, String>{};
    final taken = <String>{};
    void match(bool Function(ScorePart a, ScorePart b) same) {
      for (final a in before) {
        if (out.containsKey(a.id)) continue;
        final b = after.where((b) => !taken.contains(b.id) && same(a, b)).firstOrNull;
        if (b == null) continue;
        out[a.id] = b.id;
        taken.add(b.id);
      }
    }

    match((a, b) => a.id == b.id && a.name == b.name);
    match((a, b) => a.name == b.name);
    match((a, b) => a.id == b.id);
    return out;
  }

  /// Instruments only in the new file.
  List<ScorePart> get added => [
    for (final p in after.parts)
      if (!parts.containsValue(p.id)) p,
  ];

  /// Instruments only in the old file: their lanes and names go.
  List<ScorePart> get removed => [
    for (final p in before.parts)
      if (!parts.containsKey(p.id)) p,
  ];

  /// Instruments matched by id whose name changed.
  List<(ScorePart, ScorePart)> get renamed => [
    for (final a in before.parts)
      if (parts[a.id] case final id?)
        if (after.parts.firstWhere((p) => p.id == id) case final b when b.name != a.name) (a, b),
  ];

  // MARK: Texts

  /// [edits] (old text id → text) by the new file's ids. A text is the same one where the
  /// same instrument has the same words, of the same kind: by id, else in the same bar (ids the
  /// app gives in document order shift when a direction is added before them).
  Map<String, String> textEdits(Map<String, String> edits) {
    final out = <String, String>{};
    final taken = <String>{};
    for (final MapEntry(key: id, value: edit) in edits.entries) {
      final old = textsBefore.where((t) => t.id == id).firstOrNull;
      if (old == null) continue;
      bool same(ScoreText t) =>
          !taken.contains(t.id) && t.partId == parts[old.partId] && t.text == old.text && t.kind == old.kind;
      final match =
          textsAfter.where((t) => same(t) && t.id == id).firstOrNull ??
          textsAfter.where((t) => same(t) && t.measure == old.measure).firstOrNull;
      if (match == null) continue;
      out[match.id] = edit;
      taken.add(match.id);
    }
    return out;
  }

  /// [pairs] by the new ids; a pair missing a player goes.
  List<PlayerPair> pairs(List<PlayerPair> pairs) => [
    for (final p in pairs)
      if ((parts[p.first], parts[p.second]) case (final a?, final b?)) PlayerPair(a, b),
  ];

  // MARK: Positions

  /// Where score quarter [q] of the old file falls in the new: the same bar, as far into it
  /// (no further than its end); null past the new file's last bar. A barline is the same
  /// barline, the old file's end included.
  static double? quarterAt(double q, List<double> before, List<double> after) {
    var m = 0;
    while (m + 1 < before.length && before[m + 1] <= q) {
      m++;
    }
    if (m + 1 == before.length) return m < after.length ? after[m] : null; // the end
    if (m + 1 >= after.length) return null;
    return after[m] + math.min(q - before[m], after[m + 1] - after[m]);
  }

  /// [state] carried to the new file: everything kept by the new part ids and positions,
  /// [condensable] (the old file's pairs, which [ProjectState.condensed] names) included.
  /// An instrument only in the new file is curated as an imported score is. Also returns what
  /// was lost past the new file's end.
  ({ProjectState state, Lost lost}) carry(
    ProjectState state, {
    required List<PlayerPair> condensable,
    required List<double> measuresBefore,
    required List<double> measuresAfter,
  }) {
    double? at(double q) => quarterAt(q, measuresBefore, measuresAfter);

    /// A stretch's new bounds: cut at the new end; null when nothing of it is left.
    (double, double)? span(double start, double end) {
      final s = at(start), e = at(end) ?? measuresAfter.last;
      return s == null || e <= s ? null : (s, e);
    }

    var lostRegions = 0;
    Map<String, List<Region>>? lanes;
    if (state.lanes case final old?) {
      lanes = {};
      for (final MapEntry(key: id, value: lane) in old.entries) {
        final to = parts[id];
        if (to == null) continue;
        lanes[to] = [];
        for (final r in lane) {
          if (span(r.start, r.end) case (final s, final e)) {
            lanes[to]!.add(r.withBounds(s, e));
          } else {
            lostRegions++;
          }
        }
      }
      lanes.addAll(Curation.autoCuratedLanes([for (final p in added) p.id], after.activeMeasures, measuresAfter));
    }

    final anchors = <SyncAnchor>[];
    for (final a in state.anchors) {
      final q = at(a.quarter), jump = a.jumpTo == null ? null : at(a.jumpTo!);
      if (q != null && (a.jumpTo == null) == (jump == null)) anchors.add(SyncAnchor(q, a.seconds, jumpTo: jump));
    }

    final patches = [
      for (final p in state.patches)
        if (at(p.quarter) case final q?) p.copyWith(quarter: q),
    ];

    final captions = [
      for (final c in state.captions)
        if (span(c.start, c.end) case (final s, final e)) Caption(s, e, c.text),
    ];

    String? condensedId(String id) {
      final pair = condensable.where((p) => p.id == id).firstOrNull;
      if (pair == null) return null;
      return switch ((parts[pair.first], parts[pair.second])) {
        (final a?, final b?) => PlayerPair(a, b).id,
        _ => null,
      };
    }

    return (
      state: ProjectState(
        lanes: lanes,
        transition: state.transition,
        anchors: anchors,
        leadIn: state.leadIn,
        midi: state.midi,
        partNames: {for (final MapEntry(key: id, value: name) in state.partNames.entries) ?parts[id]: name},
        textEdits: textEdits(state.textEdits),
        condensed: {for (final id in state.condensed) ?condensedId(id)},
        pairs: pairs(state.pairs),
        partOrder: [for (final id in state.partOrder) ?parts[id]],
        patches: patches,
        images: {for (final p in patches) p.image: state.images[p.image]!},
        captions: separateCaptions(captions),
        captionFont: state.captionFont,
        fonts: state.fonts,
        view: state.view,
      ),
      lost: (
        regions: lostRegions,
        anchors: state.anchors.length - anchors.length,
        captions: state.captions.length - captions.length,
        images: state.patches.length - patches.length,
      ),
    );
  }

  // MARK: Differences

  /// What differs between the two files, one line each, for the warning before replacing;
  /// empty when they agree. [lost] is from [carry], [edits] the old project's text edits.
  List<String> differences({
    required List<double> measuresBefore,
    required List<double> measuresAfter,
    required Map<String, String> edits,
    Lost lost = const (regions: 0, anchors: 0, captions: 0, images: 0),
  }) {
    String names(Iterable<ScorePart> parts) => parts.map((p) => p.name).join(', ');
    final barsBefore = measuresBefore.length - 1, barsAfter = measuresAfter.length - 1;
    final bars = math.min(barsBefore, barsAfter);
    final meter = _firstDifference(bars, (m) => _meter(before, m)?.label != _meter(after, m)?.label);
    final length = _firstDifference(
      bars,
      (m) => (measuresBefore[m + 1] - measuresBefore[m] - measuresAfter[m + 1] + measuresAfter[m]).abs() > 1e-6,
    );
    final known = {for (final t in textsBefore) t.id};
    final dropped = edits.keys.where(known.contains).length - textEdits(edits).length;
    final lostItems = [
      if (lost.regions > 0) _count(lost.regions, 'region'),
      if (lost.anchors > 0) _count(lost.anchors, 'anchor'),
      if (lost.captions > 0) _count(lost.captions, 'caption'),
      if (lost.images > 0) _count(lost.images, 'image'),
    ];
    return [
      if (added.isNotEmpty) 'Added: ${names(added)}',
      if (removed.isNotEmpty) 'Removed: ${names(removed)}',
      for (final (a, b) in renamed) 'Renamed: ${a.name} → ${b.name}',
      if (barsBefore != barsAfter) 'Bars: $barsBefore → $barsAfter',
      if (meter != null) 'Time signature differs from bar ${meter + 1}',
      if (length != null && (meter == null || length < meter)) 'Bar length differs from bar ${length + 1}',
      if (before.tempo != after.tempo) 'Tempo: ${_tempo(before.tempo)} → ${_tempo(after.tempo)}',
      if (dropped > 0) 'Text edits lost: $dropped',
      if (lostItems.isNotEmpty) 'Lost past bar $barsAfter: ${lostItems.join(', ')}',
    ];
  }

  static int? _firstDifference(int count, bool Function(int m) differs) {
    for (var m = 0; m < count; m++) {
      if (differs(m)) return m;
    }
    return null;
  }

  static Meter? _meter(ScoreMetadata score, int m) => m < score.meters.length ? score.meters[m] : null;

  static String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

  static String _tempo(double? qpm) => switch (qpm) {
    null => 'none',
    final t when t == t.roundToDouble() => '♩ = ${t.round()}',
    final t => '♩ = ${t.toStringAsFixed(1)}',
  };
}

/// What [ScoreSwap.carry] left out: past the new file's end.
typedef Lost = ({int regions, int anchors, int captions, int images});

/// A score engraved to stand in for the open one ([EditorController.prepareReplacement]):
/// nothing has changed yet.
@immutable
class ScoreReplacement {
  const ScoreReplacement({
    required this.name,
    required this.bytes,
    required this.score,
    required this.state,
    required this.differences,
    required this.replacing,
  });

  /// The new file's name and bytes, as a project keeps them.
  final String name;
  final Uint8List bytes;

  /// Engraved with the carried edits.
  final LoadedScore score;

  /// The project, carried over.
  final ProjectState state;

  /// What differs ([ScoreSwap.differences]); empty: nothing to warn about.
  final List<String> differences;

  /// The score it was made to replace: if another is open by then, it isn't used.
  final LoadedScore replacing;
}
