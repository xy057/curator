import 'dart:math' as math;

import 'project_state.dart';

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
