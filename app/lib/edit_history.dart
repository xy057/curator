import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:score_engine/score_engine.dart';

import 'image_patch.dart';
import 'project_state.dart';

/// Everything Undo steps through, at one moment: the edits a project saves (not the view).
@immutable
class EditState {
  const EditState({
    required this.lanes,
    required this.transition,
    required this.anchors,
    required this.leadIn,
    this.midi,
    required this.partNames,
    required this.textEdits,
    required this.condensed,
    required this.pairs,
    required this.partOrder,
    this.patches = const [],
    this.captions = const [],
    this.captionFont,
    this.fonts = ScoreFonts.standard,
    this.engraving = const EngravingOptions(),
  });

  final Map<String, List<Region>> lanes;
  final double transition;
  final List<SyncAnchor> anchors;
  final double leadIn;

  /// The MIDI tempo map the sync follows instead of [anchors] (kept for when it goes).
  final MidiTempoMap? midi;
  final Map<String, PartName> partNames;
  final Map<String, String> textEdits;
  final Set<String> condensed;
  final List<PlayerPair> pairs;
  final List<String> partOrder;
  final List<ImagePatch> patches;
  final List<Caption> captions;

  /// The project's caption font; null: the app's.
  final String? captionFont;
  final ScoreFonts fonts;

  /// The project's own engraving options, over the app's.
  final EngravingOptions engraving;

  @override
  bool operator ==(Object other) =>
      other is EditState &&
      transition == other.transition &&
      leadIn == other.leadIn &&
      midi == other.midi &&
      Curation.sameLanes(lanes, other.lanes) &&
      listEquals(anchors, other.anchors) &&
      mapEquals(partNames, other.partNames) &&
      mapEquals(textEdits, other.textEdits) &&
      setEquals(condensed, other.condensed) &&
      listEquals(pairs, other.pairs) &&
      listEquals(partOrder, other.partOrder) &&
      listEquals(patches, other.patches) &&
      listEquals(captions, other.captions) &&
      captionFont == other.captionFont &&
      fonts == other.fonts &&
      engraving == other.engraving;

  /// This state with [patches] instead of its own.
  EditState withPatches(List<ImagePatch> patches) => EditState(
        lanes: lanes,
        transition: transition,
        anchors: anchors,
        leadIn: leadIn,
        midi: midi,
        partNames: partNames,
        textEdits: textEdits,
        condensed: condensed,
        pairs: pairs,
        partOrder: partOrder,
        patches: patches,
        captions: captions,
        captionFont: captionFont,
        fonts: fonts,
        engraving: engraving,
      );

  @override
  int get hashCode => Object.hash(transition, leadIn, lanes.length, anchors.length, partNames.length, textEdits.length);
}

/// Undo and Redo: the states the document was in before each edit, as many as [limit].
class EditHistory {
  final _undo = <EditState>[];
  final _redo = <EditState>[];

  /// How many steps Undo can go back; older ones are forgotten.
  int get limit => _limit;
  int _limit = 200;
  set limit(int value) {
    _limit = math.max(1, value);
    if (_undo.length > _limit) _undo.removeRange(0, _undo.length - _limit);
  }

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// An edit happened; [before] is the state it changed. Anything undone is gone for good.
  void record(EditState before) {
    _undo.add(before);
    if (_undo.length > _limit) _undo.removeAt(0);
    _redo.clear();
  }

  /// The state to go back to from [current], or null when there is none.
  EditState? undo(EditState current) {
    if (_undo.isEmpty) return null;
    _redo.add(current);
    return _undo.removeLast();
  }

  /// The state to go forward to from [current], or null when there is none.
  EditState? redo(EditState current) {
    if (_redo.isEmpty) return null;
    _undo.add(current);
    return _redo.removeLast();
  }

  /// Changes every state kept by [change] (from [current], the state now, which it leaves
  /// as it is); a step that then changes nothing is dropped.
  void rewrite(EditState current, EditState Function(EditState) change) {
    List<EditState> changed(List<EditState> steps) {
      final kept = <EditState>[];
      var next = current;
      for (final state in steps.reversed.map(change)) {
        if (state == next) continue;
        kept.add(state);
        next = state;
      }
      return kept.reversed.toList();
    }

    final undo = changed(_undo), redo = changed(_redo);
    _undo
      ..clear()
      ..addAll(undo);
    _redo
      ..clear()
      ..addAll(redo);
  }

  void clear() {
    _undo.clear();
    _redo.clear();
  }
}
