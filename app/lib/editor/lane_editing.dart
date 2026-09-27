part of '../editor_controller.dart';

/// What a plain drag does in the instrument lanes.
enum LaneTool {
  /// Select, move and trim regions (⌥-drag still draws).
  select,

  /// Drag across lanes and bars to show those instruments there; a click shows one beat
  /// (one bar when zoomed out).
  draw,

  /// Drag across lanes and bars to hide those instruments there; a click hides one beat
  /// (one bar when zoomed out).
  erase,
}

/// A region together with the lane it is in.
typedef RegionRef = ({String partId, Region region});

/// [lanes] with the [moving] regions taken out and the [placed] ones put in: moving regions
/// within a lane, or from one lane to another. Overlaps are left for the caller to merge.
Map<String, List<Region>> relocateRegions(Map<String, List<Region>> lanes, Set<RegionRef> moving, Iterable<RegionRef> placed) => {
      for (final MapEntry(key: id, value: regions) in lanes.entries)
        id: [
          for (final r in regions)
            if (!moving.contains((partId: id, region: r))) r,
          for (final p in placed)
            if (p.partId == id) p.region,
        ],
    };

/// Editing in the Instruments tab: the tool, the selected regions, and the edits that act on
/// them or on whole lanes.
class LaneEditing {
  LaneEditing._(this._editor);
  final EditorController _editor;

  Curation? get _curation => _editor._curation;

  LaneTool get tool => _tool;
  LaneTool _tool = LaneTool.select;
  set tool(LaneTool value) {
    _tool = value;
    _editor._changed();
  }

  void _reset() => _selected = {};

  // MARK: Selection

  /// The selected regions. Batch edits act on all of them.
  Set<RegionRef> get selected => _valid;
  Set<RegionRef> _selected = {};

  /// The selection minus anything an edit has since removed or merged away.
  Set<RegionRef> get _valid {
    final curation = _curation;
    if (curation == null) return const {};
    return {for (final r in _selected) if (curation.lane(r.partId).contains(r.region)) r};
  }

  bool isSelected(String partId, Region region) => _selected.contains((partId: partId, region: region));

  /// Lanes with something selected.
  Set<String> get selectedPartIds => {for (final r in _valid) r.partId};

  /// Click: select just this region. ⇧ ([add]): add it. ⌘ ([toggle]): add or remove it.
  void select(String partId, Region region, {bool add = false, bool toggle = false}) {
    final ref = (partId: partId, region: region);
    if (toggle) {
      _selected = {..._valid};
      if (!_selected.remove(ref)) _selected.add(ref);
    } else {
      _selected = add ? {..._valid, ref} : {ref};
    }
    _editor._changed();
  }

  /// Replaces the selection with [regions] (plus [keep]).
  void selectMany(Iterable<RegionRef> regions, {Iterable<RegionRef> keep = const []}) {
    _selected = {...keep, ...regions};
    _editor._changed();
  }

  /// Every region in one lane (added to the selection with [add]).
  void selectLane(String partId, {bool add = false}) => selectMany(
        [for (final r in _curation?.lane(partId) ?? const <Region>[]) (partId: partId, region: r)],
        keep: add ? _valid : const [],
      );

  void selectAll() {
    final curation = _curation;
    if (curation == null) return;
    selectMany([
      for (final p in _editor.laneParts)
        for (final r in curation.lane(p.id)) (partId: p.id, region: r),
    ]);
  }

  /// After an edit merged or reshaped regions, selects whatever now covers [wanted].
  void reselect(Iterable<RegionRef> wanted) {
    final curation = _curation;
    if (curation == null) return;
    _selected = {
      for (final w in wanted)
        for (final r in curation.lane(w.partId))
          if (r.overlaps(w.region) && (w.region.length == 0 || math.min(r.end, w.region.end) > math.max(r.start, w.region.start)))
            (partId: w.partId, region: r),
    };
    _editor._changed();
  }

  // MARK: Editing the selection

  /// Replaces the selected regions with [edit] of each, as one undo step, and keeps the
  /// results selected.
  void _editSelected(Region? Function(Region r) edit) {
    final curation = _curation;
    final selected = _valid;
    if (curation == null || selected.isEmpty) return;
    final changed = <RegionRef>[];
    final lanes = <String, List<Region>>{};
    for (final id in {for (final r in selected) r.partId}) {
      final mine = {for (final r in selected) if (r.partId == id) r.region};
      final edited = [for (final r in mine) ?edit(r)];
      lanes[id] = [for (final r in curation.lane(id)) if (!mine.contains(r)) r, ...edited];
      changed.addAll([for (final r in edited) (partId: id, region: r)]);
    }
    curation.setLanes(lanes);
    reselect(changed);
  }

  /// ←/→: moves the selected regions to the next or previous barline (or beat), together.
  void nudge(int direction, {bool beat = false}) {
    final sync = _editor._sync;
    final selected = _valid;
    if (sync == null || selected.isEmpty) return;
    final grid = beat ? SyncGrid.beat : SyncGrid.bar;
    final first = selected.map((r) => r.region.start).reduce(math.min);
    final last = selected.map((r) => r.region.end).reduce(math.max);
    final total = _editor.timeline.measureStarts.last;
    var delta = (direction > 0 ? sync.nextGrid(first, grid) : sync.previousGrid(first, grid)) - first;
    delta = delta.clamp(-first, total - last).toDouble();
    if (delta.abs() < 1e-9) return;
    _editSelected((r) => Region(r.start + delta, r.end + delta));
  }

  /// ↑/↓: moves the selected regions to the lane above (-1) or below (+1), together. Does
  /// nothing when one of them is already in the top (bottom) lane.
  void moveToLane(int direction) {
    final curation = _curation;
    final selected = _valid;
    if (curation == null || selected.isEmpty) return;
    final ids = [for (final p in _editor.laneParts) p.id];
    final rows = [for (final r in selected) ids.indexOf(r.partId)];
    if (rows.reduce(math.min) + direction < 0 || rows.reduce(math.max) + direction >= ids.length) return;
    final placed = [for (final r in selected) (partId: ids[ids.indexOf(r.partId) + direction], region: r.region)];
    curation.setLanes(relocateRegions({for (final id in ids) id: curation.lane(id)}, selected, placed));
    reselect(placed);
  }

  /// [ / ]: the selected regions now start (or end) at the beat nearest the playhead.
  void trimToPlayhead({required bool start}) {
    final sync = _editor._sync;
    if (sync == null) return;
    final q = sync.nearestGrid(_editor.timeline.quarterAtSeconds(_editor.playback.time.value), SyncGrid.beat);
    _editSelected((r) {
      if (start ? q >= r.end : q <= r.start) return r; // would turn it inside out
      return start ? Region(q, r.end) : Region(r.start, q);
    });
  }

  /// Gives one region new bounds (the region dialog).
  void setRegion(RegionRef ref, Region region) {
    final curation = _curation;
    if (curation == null) return;
    curation.setLane(ref.partId, [for (final r in curation.lane(ref.partId)) if (r != ref.region) r, region]);
    reselect([(partId: ref.partId, region: region)]);
  }

  /// Delete: removes the selected regions.
  void delete() {
    _editSelected((_) => null);
    _selected = {};
    _editor._changed();
  }

  /// A drag's live state of the lanes (between [EditorController.beginEdit] and
  /// [EditorController.endEdit], which merges what it leaves overlapping).
  void preview(Map<String, List<Region>> lanes) => _curation?.updateLanes(lanes);

  // MARK: Whole lanes

  /// Fills [partIds] (every lane when null) from where each part plays; a condensed pair's
  /// lane from where either player does.
  void autoCurate([Iterable<String>? partIds]) {
    final score = _editor._score;
    if (score == null) return;
    final active = {...score.metadata.activeMeasures};
    for (final g in _editor.condensable) {
      if (!_editor.condensed.contains(g.id)) continue;
      final [a, b] = [for (final id in g.partIds) active[id] ?? const <bool>[]];
      active[g.partIds.first] = [for (var m = 0; m < math.max(a.length, b.length); m++) a.elementAtOrNull(m) == true || b.elementAtOrNull(m) == true];
    }
    _curation?.autoCurate(active, score.timeline.measureStarts, partIds: partIds ?? [for (final p in _editor.laneParts) p.id]);
    _editor.clearSelection();
  }

  /// Empties [partIds] (every lane when null).
  void clear([Iterable<String>? partIds]) {
    final curation = _curation;
    if (curation == null) return;
    curation.setLanes({for (final id in partIds ?? curation.partIds) id: const []});
    _editor.clearSelection();
  }

  /// Shows [partId] from the first bar to the last.
  void showThroughout(String partId) {
    _curation?.setLane(partId, [Region(0, _editor.timeline.measureStarts.last)]);
    _editor.clearSelection();
  }

  /// The lanes that lane-wide tools act on: those with a selection, or every lane.
  Iterable<String>? get _toolLanes => selectedPartIds.isEmpty ? null : selectedPartIds;

  /// Joins regions separated by rests of at most [bars] bars.
  void fillGaps(double bars) {
    final kept = _valid;
    _curation?.fillGaps(_editor.timeline.measureStarts, bars, partIds: _toolLanes);
    reselect(kept);
  }

  /// Removes regions shorter than [bars] bars.
  void removeShort(double bars) {
    final kept = _valid;
    _curation?.removeShort(_editor.timeline.measureStarts, bars, partIds: _toolLanes);
    reselect(kept);
  }

  void copyLane(String from, Iterable<String> to) {
    _curation?.copyLane(from, to);
    _editor.clearSelection();
  }
}
