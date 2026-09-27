import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:score_engine/score_engine.dart';

import 'project_state.dart';

/// Everything Undo steps through, at one moment: the edits a project saves (not the view).
@immutable
class EditState {
  const EditState({
    required this.lanes,
    required this.transition,
    required this.anchors,
    required this.leadIn,
    required this.partNames,
    required this.textEdits,
    required this.condensed,
    required this.pairs,
  });

  final Map<String, List<Region>> lanes;
  final double transition;
  final List<SyncAnchor> anchors;
  final double leadIn;
  final Map<String, PartName> partNames;
  final Map<String, String> textEdits;
  final Set<String> condensed;
  final List<PlayerPair> pairs;

  @override
  bool operator ==(Object other) =>
      other is EditState &&
      transition == other.transition &&
      leadIn == other.leadIn &&
      Curation.sameLanes(lanes, other.lanes) &&
      listEquals(anchors, other.anchors) &&
      mapEquals(partNames, other.partNames) &&
      mapEquals(textEdits, other.textEdits) &&
      setEquals(condensed, other.condensed) &&
      listEquals(pairs, other.pairs);

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

  void clear() {
    _undo.clear();
    _redo.clear();
  }
}
