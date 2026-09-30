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

/// Which edges of a selected region are selected: [both] when the region itself is (clicked
/// in its middle), or the one clicked on. Its transition there is what the toolbar sets.
enum RegionEdges {
  start,
  end,
  both;

  bool get hasStart => this != end;
  bool get hasEnd => this != start;

  /// Whether every edge of [other] is one of these.
  bool covers(RegionEdges other) => this == both || this == other;

  /// These edges and [other]'s.
  RegionEdges operator |(RegionEdges other) => this == other ? this : both;

  /// These edges without [other]'s; null when none is left.
  RegionEdges? without(RegionEdges other) => other.covers(this) ? null : (other == start ? end : start);
}

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

  void _reset() {
    _clear();
    _laneAnchor = null;
  }

  /// Nothing selected: no regions, no lanes.
  void _clear() {
    _selected = {};
    _lanes = {};
  }

  // MARK: Selection

  /// The selected regions, whole or by an edge. Batch edits act on all of them; those at an
  /// edge ([setTransition], trimming) on the edges selected.
  Set<RegionRef> get selected => _valid.keys.toSet();

  /// Every selected region with its selected edges.
  Map<RegionRef, RegionEdges> get selection => _valid;
  Map<RegionRef, RegionEdges> _selected = {};

  /// The selection minus anything an edit has since removed or merged away.
  Map<RegionRef, RegionEdges> get _valid {
    final curation = _curation;
    if (curation == null) return const {};
    return {
      for (final MapEntry(key: r, value: edges) in _selected.entries)
        if (curation.lane(r.partId).contains(r.region)) r: edges,
    };
  }

  /// Whether [region] is selected: at all, or at every edge of [edges].
  bool isSelected(String partId, Region region, [RegionEdges? edges]) {
    final own = _selected[(partId: partId, region: region)];
    return own != null && (edges == null || own.covers(edges));
  }

  /// Lanes selected by their names, empty ones too (their regions are selected with them).
  Set<String> _lanes = {};

  /// Lanes with something selected, or selected by their names.
  Set<String> get selectedPartIds {
    final shown = {for (final p in _editor.laneParts) p.id};
    return {for (final id in _lanes) if (shown.contains(id)) id, for (final r in _valid.keys) r.partId};
  }

  /// Click: select just this region, or just one of its [edges]. ⇧ ([add]): add it. ⌘
  /// ([toggle]): add or remove it.
  void select(String partId, Region region, {bool add = false, bool toggle = false, RegionEdges edges = RegionEdges.both}) {
    final ref = (partId: partId, region: region);
    if (!add && !toggle) _lanes = {};
    final own = _valid[ref];
    if (toggle && own != null && own.covers(edges)) {
      _selected = {..._valid}..remove(ref);
      if (own.without(edges) case final left?) _selected[ref] = left;
    } else if (add || toggle) {
      _selected = {..._valid, ref: own == null ? edges : own | edges};
    } else {
      _selected = {ref: edges};
    }
    _editor._changed();
  }

  /// Replaces the selection with the whole of [regions] (plus [keep]); lanes selected by
  /// their names stay only with [keepLanes].
  void selectMany(Iterable<RegionRef> regions, {Map<RegionRef, RegionEdges> keep = const {}, bool keepLanes = false}) {
    _selected = {...keep, for (final r in regions) r: RegionEdges.both};
    if (!keepLanes) _lanes = {};
    _editor._changed();
  }

  /// Replaces the selection with [selection]: regions with the edges selected (a drag's
  /// regions, as they go).
  void selectEdges(Map<RegionRef, RegionEdges> selection) {
    _selected = {...selection};
    _lanes = {};
    _editor._changed();
  }

  /// The lane last selected by its name: where a range of lanes ([selectLaneRange]) starts.
  String? _laneAnchor;

  /// Every region in one lane (added to the selection with [add]).
  void selectLane(String partId, {bool add = false}) {
    _laneAnchor = partId;
    _selectLanes([partId], add: add);
  }

  /// Selects [partIds] by their names, and every region in them.
  void _selectLanes(Iterable<String> partIds, {bool add = false}) {
    final curation = _curation;
    if (curation == null) return;
    final lanes = add ? {..._lanes, ...partIds} : {...partIds};
    selectMany([
      for (final id in partIds)
        for (final r in curation.lane(id)) (partId: id, region: r),
    ], keep: add ? _valid : const {});
    _lanes = lanes;
  }

  /// ⌘-click on a lane's name: every region in the lanes from the one last selected by its
  /// name to [partId], top to bottom, and nothing else.
  void selectLaneRange(String partId) {
    final curation = _curation;
    final ids = [for (final p in _editor.laneParts) p.id];
    final to = ids.indexOf(partId);
    if (curation == null || to < 0) return;
    final from = ids.indexOf(_laneAnchor ?? partId);
    final (a, b) = from < 0 ? (to, to) : (math.min(from, to), math.max(from, to));
    _laneAnchor ??= partId;
    _selectLanes(ids.sublist(a, b + 1));
  }

  /// ↑/↓: the selection moves to the lane above (-1) or below (+1), Oboe 1 to Oboe 2: the
  /// lanes with something selected, together, become those next to them (whole lanes). Stops
  /// at the top (bottom) lane. With nothing selected, ↓ selects the top lane and ↑ the bottom.
  void selectNextLane(int direction) {
    final ids = [for (final p in _editor.laneParts) p.id];
    if (ids.isEmpty) return;
    final rows = [for (final id in selectedPartIds) ids.indexOf(id)]..sort();
    if (rows.isEmpty) {
      selectLane(direction > 0 ? ids.first : ids.last);
      return;
    }
    if (rows.first + direction < 0 || rows.last + direction >= ids.length) return;
    final anchor = ids.indexOf(_laneAnchor ?? '');
    _laneAnchor = anchor < 0 ? null : ids[(anchor + direction).clamp(0, ids.length - 1)];
    _selectLanes([for (final i in rows) ids[i + direction]]);
  }

  void selectAll() => _selectLanes([for (final p in _editor.laneParts) p.id]);

  /// After an edit merged or reshaped regions, selects whatever now covers [wanted], at the
  /// same edges (those of every region merged into it).
  void reselect(Map<RegionRef, RegionEdges> wanted) {
    final curation = _curation;
    if (curation == null) return;
    final selected = <RegionRef, RegionEdges>{};
    for (final MapEntry(key: w, value: edges) in wanted.entries) {
      for (final r in curation.lane(w.partId)) {
        if (r.overlaps(w.region) && (w.region.length == 0 || math.min(r.end, w.region.end) > math.max(r.start, w.region.start))) {
          final ref = (partId: w.partId, region: r);
          selected[ref] = selected[ref] == null ? edges : selected[ref]! | edges;
        }
      }
    }
    _selected = selected;
    _editor._changed();
  }

  // MARK: Editing the selection

  /// Replaces the selected regions with [edit] of each (given its selected edges), as one
  /// undo step, and keeps the results selected at the same edges.
  void _editSelected(Region? Function(Region r, RegionEdges edges) edit) {
    final curation = _curation;
    final selected = _valid;
    if (curation == null || selected.isEmpty) return;
    final changed = <RegionRef, RegionEdges>{};
    final lanes = <String, List<Region>>{};
    for (final id in {for (final r in selected.keys) r.partId}) {
      final mine = {for (final MapEntry(key: r, value: edges) in selected.entries) if (r.partId == id) r.region: edges};
      final edited = [
        for (final MapEntry(key: r, value: edges) in mine.entries)
          if (edit(r, edges) case final e?) (e, edges),
      ];
      lanes[id] = [for (final r in curation.lane(id)) if (!mine.containsKey(r)) r, for (final (e, _) in edited) e];
      for (final (e, edges) in edited) {
        changed[(partId: id, region: e)] = edges;
      }
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
    final first = selected.keys.map((r) => r.region.start).reduce(math.min);
    final last = selected.keys.map((r) => r.region.end).reduce(math.max);
    final total = _editor.timeline.measureStarts.last;
    var delta = (direction > 0 ? sync.nextGrid(first, grid) : sync.previousGrid(first, grid)) - first;
    delta = delta.clamp(-first, total - last).toDouble();
    if (delta.abs() < 1e-9) return;
    _editSelected((r, _) => r.withBounds(r.start + delta, r.end + delta));
  }

  /// [ / ]: the selected regions now start (or end) at the beat nearest the playhead; those
  /// selected by the other edge only stay as they are.
  void trimToPlayhead({required bool start}) {
    final sync = _editor._sync;
    if (sync == null) return;
    final q = sync.nearestGrid(_editor.timeline.quarterAtSeconds(_editor.playback.time.value), SyncGrid.beat);
    _editSelected((r, edges) {
      if (!(start ? edges.hasStart : edges.hasEnd)) return r;
      if (start ? q >= r.end : q <= r.start) return r; // would turn it inside out
      return start ? r.withBounds(q, r.end) : r.withBounds(r.start, q);
    });
  }

  /// The transitions the selected edges have (null: the project's); one when they all agree.
  Set<double?> get selectedTransitions => {
        for (final MapEntry(key: r, value: edges) in _valid.entries) ...[
          if (edges.hasStart) r.region.transitionIn,
          if (edges.hasEnd) r.region.transitionOut,
        ],
      };

  /// Gives every selected edge (both of a whole region) its own transition (null: the
  /// project's), as one step.
  void setTransition(double? seconds) =>
      _editSelected((r, edges) => r.withTransition(seconds, atStart: edges.hasStart, atEnd: edges.hasEnd));

  /// Gives one region new bounds and properties (the region dialog).
  void setRegion(RegionRef ref, Region region) {
    final curation = _curation;
    if (curation == null) return;
    curation.setLane(ref.partId, [for (final r in curation.lane(ref.partId)) if (r != ref.region) r, region]);
    reselect({(partId: ref.partId, region: region): RegionEdges.both});
  }

  /// Delete: removes the selected regions.
  void delete() {
    _editSelected((_, _) => null);
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
