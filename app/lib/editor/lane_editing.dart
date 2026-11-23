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
  erase;

  /// The tool a drag uses with ⌥ held ([alt]): select draws, and draw and erase swap.
  LaneTool withAlt(bool alt) => !alt ? this : (this == draw ? erase : draw);
}

/// A region together with the lane it is in.
typedef RegionRef = ({String partId, Region region});

/// One lane of copied regions: the lane they came from, its [row] below the top lane copied,
/// and the regions with their bounds measured from the first one's start.
typedef CopiedLane = ({String partId, int row, List<Region> regions});

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
    _script = '';
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
    final shown = {for (final p in _editor.laneRows) p.id};
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
    final ids = [for (final p in _editor.laneRows) p.id];
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
    final ids = [for (final p in _editor.laneRows) p.id];
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

  void selectAll() => _selectLanes([for (final p in _editor.laneRows) p.id]);

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
  void _editSelected(Region? Function(Region r, RegionEdges edges) edit) => _editSelectedIn((_, r, edges) => edit(r, edges));

  /// [_editSelected], told each region's lane too.
  void _editSelectedIn(Region? Function(String partId, Region r, RegionEdges edges) edit) {
    final curation = _curation;
    final selected = _valid;
    if (curation == null || selected.isEmpty) return;
    final changed = <RegionRef, RegionEdges>{};
    final lanes = <String, List<Region>>{};
    for (final id in {for (final r in selected.keys) r.partId}) {
      final mine = {for (final MapEntry(key: r, value: edges) in selected.entries) if (r.partId == id) r.region: edges};
      final edited = [
        for (final MapEntry(key: r, value: edges) in mine.entries)
          if (edit(id, r, edges) case final e?) (e, edges),
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

  /// How many staves the instrument of [partId] is on: each a region can leave out.
  int staffCountOf(String partId) =>
      _editor._score?.metadata.parts.where((p) => p.id == partId).firstOrNull?.staffNumbers.length ?? 1;

  /// The most staves an instrument of the selected regions is on (1: none is on more).
  int get selectedStaffCount => _valid.keys.map((r) => staffCountOf(r.partId)).fold(1, math.max);

  /// For each staff from 1 to [selectedStaffCount]: whether the selected regions (of instruments
  /// on that many staves) show it, true all, false none, null some.
  List<bool?> get selectedStavesShown => [
        for (var n = 1; n <= selectedStaffCount; n++)
          {
            for (final r in _valid.keys)
              if (staffCountOf(r.partId) >= n) r.region.showsStaff(n),
          }.singleOrNull,
      ];

  /// Shows or leaves out staff [n] in the selected regions of instruments on that many staves,
  /// as one step; a region keeps at least one staff.
  void setStaffShown(int n, bool shown) => _editSelectedIn((id, r, _) {
        final count = staffCountOf(id);
        if (count < n) return r;
        final hidden = {...r.hiddenStaves};
        shown ? hidden.remove(n) : hidden.add(n);
        return hidden.length >= count ? r : r.withHiddenStaves(hidden);
      });

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

  // MARK: Copy and paste

  /// What Copy or Cut took, lane by lane; kept when another project opens. The app's own,
  /// not the system clipboard's (that holds images for Attach Image).
  List<CopiedLane> get copied => _copied;
  List<CopiedLane> _copied = const [];

  /// Whether Paste has regions to put in.
  bool get canPaste => _copied.isNotEmpty;

  /// Copy: the selected regions, whole (with their transitions) whatever edge is selected,
  /// and how far apart their lanes are.
  void copy() {
    final selected = _valid.keys;
    if (selected.isEmpty) return;
    final ids = [for (final p in _editor.laneRows) p.id];
    final start = selected.map((r) => r.region.start).reduce(math.min);
    final lanes = {for (final r in selected) r.partId}.toList()..sort((a, b) => ids.indexOf(a).compareTo(ids.indexOf(b)));
    final top = ids.indexOf(lanes.first);
    _copied = [
      for (final id in lanes)
        (
          partId: id,
          row: ids.indexOf(id) - top,
          regions: [
            for (final r in selected.where((r) => r.partId == id).map((r) => r.region).toList()..sort((a, b) => a.start.compareTo(b.start)))
              r.withBounds(r.start - start, r.end - start),
          ],
        ),
    ];
    _editor._changed();
  }

  /// Cut: Copy, then Delete.
  void cut() {
    copy();
    delete();
  }

  /// Paste: the copied regions from the beat nearest the playhead, merged with what the lanes
  /// hold, and selected. The top lane copied goes into the top lane selected, the rest as far
  /// below it as they were (any past the bottom lane are left out); with nothing selected,
  /// each into the lane it came from (from another score: from the top lane). Cut off at the
  /// end of the piece.
  void paste() {
    final curation = _curation, sync = _editor._sync;
    if (curation == null || sync == null || _copied.isEmpty) return;
    final ids = [for (final p in _editor.laneRows) p.id];
    final into = [for (final id in selectedPartIds) ids.indexOf(id)];
    final top = into.isNotEmpty ? into.reduce(math.min) : (_copied.any((l) => ids.contains(l.partId)) ? null : 0);
    final at = sync.nearestGrid(_editor.timeline.quarterAtSeconds(_editor.playback.time.value), SyncGrid.beat);
    final end = _editor.timeline.measureStarts.last;
    final placed = <RegionRef>[];
    for (final lane in _copied) {
      final id = top == null ? (ids.contains(lane.partId) ? lane.partId : null) : ids.elementAtOrNull(top + lane.row);
      if (id == null) continue;
      for (final r in lane.regions) {
        final to = math.min(at + r.end, end);
        if (to - (at + r.start) > 1e-9) placed.add((partId: id, region: r.withBounds(at + r.start, to)));
      }
    }
    if (placed.isEmpty) return;
    curation.setLanes({
      for (final id in {for (final p in placed) p.partId})
        id: [...curation.lane(id), for (final p in placed) if (p.partId == id) p.region],
    });
    reselect({for (final p in placed) p: RegionEdges.both});
  }

  /// A drag's live state of the lanes (between [EditorController.beginEdit] and
  /// [EditorController.endEdit], which merges what it leaves overlapping).
  void preview(Map<String, List<Region>> lanes) => _curation?.updateLanes(lanes);

  // MARK: Whole lanes

  /// Fills [partIds] (every lane when null) from where each part plays, cut back where the
  /// staves would run off the video's frame ([CuratedScene.curatedToFit]); a condensed pair's
  /// lane from where either player does.
  /// Nothing for a PDF's project unless [EditorController.autoCuratePdf].
  void autoCurate([Iterable<String>? partIds]) {
    if (!_editor.canAutoCurate) return;
    // A blank lane (a PDF score's) plays nothing: it stays as it is.
    final ids = [for (final id in partIds ?? [for (final p in _editor.laneRows) p.id]) if (!_editor.isBlankLane(id)) id];
    // A staff's lane (of an instrument split) is curated as its instrument is.
    final curated = _curated({for (final id in ids) _editor.instrumentOfLane(id)});
    if (curated == null) return;
    _curation?.setLanes({for (final id in ids) id: curated[_editor.instrumentOfLane(id)] ?? const []});
    _editor.clearSelection();
  }

  /// The bars each lane's instrument plays in (a condensed pair's lane: either player's), and
  /// the pairs condensed: what auto-curation fills the lanes from.
  ({Map<String, List<bool>> active, List<List<String>> pairs}) _activity(LoadedScore score) {
    final active = {...score.metadata.activeMeasures};
    final pairs = <List<String>>[];
    for (final g in _editor.condensable) {
      if (!_editor.condensed.contains(g.id)) continue;
      final [a, b] = [for (final id in g.partIds) active[id] ?? const <bool>[]];
      active[g.partIds.first] = [for (var m = 0; m < math.max(a.length, b.length); m++) a.elementAtOrNull(m) == true || b.elementAtOrNull(m) == true];
      pairs.add(g.partIds);
    }
    return (active: active, pairs: pairs);
  }

  /// What [autoCurate] fills [partIds] with (null without a score).
  Map<String, List<Region>>? _curated(Iterable<String> partIds) {
    final score = _editor._score, curation = _curation, scene = _editor._scene;
    if (score == null || curation == null) return null;
    final (:active, :pairs) = _activity(score);
    if (scene == null) return Curation.autoCuratedLanes(partIds, active, score.timeline.measureStarts);
    return scene.curatedToFit(curation, _editor._videoLayout,
        partIds: partIds, activeMeasures: active, salience: score.salience.condensed(pairs));
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

  // MARK: Script

  /// Whether the Instruments tab shows the script in the lanes' place.
  bool get scripting => _scripting;
  bool _scripting = false;
  set scripting(bool value) {
    if (value == _scripting) return;
    _scripting = value;
    _editor._changed();
  }

  /// The project's script ([LaneScript]) as it was left: saved with it, and no edit (what it
  /// did when it ran is).
  String get script => _script;
  String _script = '';
  set script(String value) {
    if (value == _script) return;
    _script = value;
    _editor.editRevision.value++;
  }

  /// What is wrong with [source] as a script, were it run now; nothing changes.
  List<LaneScriptProblem> checkScript(String source) =>
      _curation == null ? const [] : LaneScript.parse(source).check(_ScriptHost(_editor));

  /// Runs [source], every statement, as one Undo step: what the tools would do, done by
  /// writing. What is wrong with it is given back, and then nothing has changed; [changed]:
  /// whether anything did.
  ({List<LaneScriptProblem> problems, bool changed}) runScript(String source) {
    final script = LaneScript.parse(source), host = _ScriptHost(_editor);
    if (_curation == null) return (problems: const [], changed: false);
    final problems = script.check(host);
    return problems.isNotEmpty ? (problems: problems, changed: false) : _ran(script, host);
  }

  /// [runScript] for a script that may wait ([LaneScript.waits]: it hears the recording, as
  /// Align does): what it waits for is got first, with nothing changed and Align's progress
  /// showing ([SyncEditing.aligning]), and then it runs at once, one Undo step. Nothing where
  /// an Align is under way, or the project was changed for another meanwhile.
  Future<({List<LaneScriptProblem> problems, bool changed})> runScriptReady(String source) async {
    final script = LaneScript.parse(source), host = _ScriptHost(_editor);
    if (!script.waits) return runScript(source);
    const nothing = (problems: <LaneScriptProblem>[], changed: false);
    if (_curation == null) return nothing;
    final problems = script.check(host);
    if (problems.isNotEmpty) return (problems: problems, changed: false);
    final sync = _editor._sync, track = _editor.track;
    final got = await _editor.anchors._whileAligning((report) {
      host._report = report;
      return script.ready(host);
    });
    if (got == null || _editor._disposed || _curation == null || _editor._sync != sync || _editor.track != track) return nothing;
    return got.problems.isNotEmpty ? (problems: got.problems, changed: false) : _ran(script, host, ready: got.ready);
  }

  /// Runs [script], checked, as one Undo step ([only]: those of its lines).
  ({List<LaneScriptProblem> problems, bool changed}) _ran(LaneScript script, _ScriptHost host, {ScriptReady? ready, Set<int>? only}) {
    List<LaneScriptProblem> problems;
    final before = _editor._editState;
    _editor.beginEdit();
    try {
      problems = script.run(host, ready: ready, only: only);
      // What only running finds (lanes that can't be auto-curated): as it was, as Undo puts it.
      if (problems.isNotEmpty) _editor._restore(before);
    } finally {
      _editor.endEdit();
    }
    _editor.clearSelection();
    return (problems: problems, changed: _editor._editState != before);
  }

  // MARK: Macros

  /// [macro] as a script for now: with the lanes selected, the beat nearest the playhead, the
  /// bars from the first selected region's start to the last one's end, and the bars [asked]
  /// for; and what keeps a step from being written.
  ({String script, List<MacroProblem> problems, List<int> order}) _macroScript(LaneMacro macro, String? asked) {
    final regions = _valid.keys;
    return macro.script(MacroContext.of(
      _ScriptHost(_editor),
      selected: selectedPartIds,
      playhead: _editor._sync!.nearestGrid(_editor.timeline.quarterAtSeconds(_editor.playback.time.value), SyncGrid.beat),
      span: regions.isEmpty ? null : (regions.map((r) => r.region.start).reduce(math.min), regions.map((r) => r.region.end).reduce(math.max)),
      asked: asked,
    ));
  }

  /// What is wrong with [macro] were it run now, by step; nothing changes.
  List<MacroProblem> checkMacro(LaneMacro macro, {String? asked}) {
    if (_curation == null || _editor._sync == null) return const [];
    final (:script, :problems, :order) = _macroScript(macro, asked);
    return problems.isNotEmpty ? problems : LaneMacro.problemsOf(checkScript(script), order);
  }

  /// Runs [macro] as the script it is for now ([runScript]: one Undo step, or nothing at all),
  /// [asked] the bars it asks for. The lanes it was run on stay selected, for the next. (One
  /// with a step that waits is for [runMacroReady]: here that step fails, and nothing is done.)
  ({List<MacroProblem> problems, bool changed}) runMacro(LaneMacro macro, {String? asked}) {
    if (_curation == null || _editor._sync == null) return (problems: const [], changed: false);
    final lanes = selectedPartIds;
    final (:script, :problems, :order) = _macroScript(macro, asked);
    return problems.isNotEmpty ? (problems: problems, changed: false) : _macroRan(runScript(script), order, lanes);
  }

  /// [runMacro] for a macro that may wait (a step hears the recording), as its graph says
  /// ([LaneMacro.stages]): the steps that neither wait nor come after one that does are done
  /// at once, one Undo step, before this is waited for; what the others wait for is got
  /// meanwhile, with nothing changed and Align's progress showing ([SyncEditing.aligning]), and
  /// then they are done, a step of their own (as Align's anchors are). The whole of it is
  /// checked before anything is done; what only the hearing finds (a recording that can't be
  /// read, no score heard in it) leaves what was done at once done. Nothing more where an
  /// Align is under way, or the recording or the project is another by then.
  Future<({List<MacroProblem> problems, bool changed})> runMacroReady(LaneMacro macro, {String? asked}) async {
    const nothing = (problems: <MacroProblem>[], changed: false);
    if (_curation == null || _editor._sync == null) return nothing;
    final lanes = selectedPartIds;
    final (script: source, :problems, :order) = _macroScript(macro, asked);
    if (problems.isNotEmpty) return (problems: problems, changed: false);
    final script = LaneScript.parse(source), host = _ScriptHost(_editor);
    if (!script.waits) return _macroRan(runScript(source), order, lanes);
    final wrong = script.check(host);
    if (wrong.isNotEmpty) return (problems: LaneMacro.problemsOf(wrong, order), changed: false);
    // A line is its step's place in the order they are done in.
    final (:now, :later) = macro.stages;
    Set<int> lines(List<int> steps) => {for (final i in steps) order.indexOf(i) + 1};
    var changed = false;
    if (now.isNotEmpty) {
      final ran = _macroRan(_ran(script, host, only: lines(now)), order, lanes);
      if (ran.problems.isNotEmpty) return ran;
      changed = ran.changed;
    }
    final sync = _editor._sync, track = _editor.track;
    final got = await _editor.anchors._whileAligning((report) {
      host._report = report;
      return script.ready(host);
    });
    if (got == null || _editor._disposed || _curation == null || _editor._sync != sync || _editor.track != track) return (problems: const <MacroProblem>[], changed: changed);
    if (got.problems.isNotEmpty) return (problems: LaneMacro.problemsOf(got.problems, order), changed: changed);
    final ran = _macroRan(_ran(script, host, ready: got.ready, only: lines(later)), order, lanes);
    return (problems: ran.problems, changed: changed || ran.changed);
  }

  ({List<MacroProblem> problems, bool changed}) _macroRan(({List<LaneScriptProblem> problems, bool changed}) ran, List<int> order, Set<String> lanes) {
    if (ran.problems.isEmpty && lanes.isNotEmpty) _selectLanes([for (final row in _editor.laneRows) if (lanes.contains(row.id)) row.id]);
    return (problems: LaneMacro.problemsOf(ran.problems, order), changed: ran.changed);
  }

  /// The lanes as they are, as a script that makes them again ([LaneScript.write]).
  String get asScript => _curation == null ? '' : LaneScript.write(_ScriptHost(_editor));

  /// The lanes' names, top to bottom, each once: what a script calls them.
  List<String> get scriptNames => {for (final lane in _ScriptHost(_editor).lanes) lane.name}.toList();
}

/// The project a script runs over ([LaneScriptHost]): the lanes as the Instruments tab has
/// them, by the names it shows.
class _ScriptHost extends LaneScriptHost {
  _ScriptHost(this._editor);
  final EditorController _editor;

  @override
  List<ScriptLane> get lanes {
    final instruments = {for (final p in _editor.laneParts) p.id: p};
    return [
      for (final row in _editor.laneRows)
        if (_editor.instrumentOfLane(row.id) case final instrument)
          ScriptLane(
            id: row.id,
            name: _editor.laneName(instruments[instrument] ?? row),
            instrument: instrument,
            staff: Curation.staffOfLane(row.id)?.$2,
            staves: _editor.lanes.staffCountOf(instrument),
          ),
    ];
  }

  @override
  BeatGrid get beats => _editor.beats;
  @override
  Curation get curation => _editor._curation!;

  @override
  List<(String, double)> get marks {
    final score = _editor._score!, starts = score.timeline.measureStarts;
    return [
      for (final text in score.texts)
        if (text.kind == ScoreTextKind.rehearsal && text.measure >= 0 && text.measure < starts.length - 1) (score.currentText(text), starts[text.measure]),
    ];
  }

  @override
  bool autoCurate(List<String> ids) {
    if (!_editor.canAutoCurate) return false;
    _editor.lanes.autoCurate(ids);
    return true;
  }

  // Auto-Curate in its halves (`follow`, `fit`) and the second's steps (`thin`, `refill`, `remove lone`), from what
  // [LaneEditing.autoCurate] is made of.

  late final _activity = _editor.lanes._activity(_editor._score!);

  @override
  bool get curates => _editor.canAutoCurate;

  /// (A blank lane, a PDF score's, plays nothing; a staff's lane plays what its instrument does.)
  @override
  List<bool>? playing(String id) => _editor.isBlankLane(id) ? null : _activity.active[_editor.instrumentOfLane(id)] ?? const [];

  /// What this run's fitting has hidden, from a step to the next.
  final _cuts = FrameCuts();

  /// (An instrument is fitted as its lanes asked for have it, a staff's lane as its instrument, as Auto-Curate does.)
  @override
  Map<String, List<Region>> fit(List<String> ids, FitStep step, {int phrase = 4}) {
    final scene = _editor._scene, lanes = [for (final id in ids) if (!_editor.isBlankLane(id)) id];
    if (scene == null || lanes.isEmpty) return const {};
    final asked = <String, List<Region>>{};
    for (final id in lanes) {
      asked.update(_editor.instrumentOfLane(id), (regions) => curation.lane(id).fold(regions, Curation.painted), ifAbsent: () => curation.lane(id));
    }
    final changed = scene.fitStep(curation, _editor._videoLayout, step,
        lanes: asked, salience: _editor._score!.salience.condensed(_activity.pairs), cuts: _cuts, phrase: phrase);
    return {for (final id in lanes) id: changed[_editor.instrumentOfLane(id)] ?? const []};
  }

  // Align in its steps (`hear`, `match`, `snap anchors`), from what [SyncEditing.align] is made of.

  /// Told how far the hearing has got, while a script is made ready.
  void Function(double done)? _report;

  @override
  String? get unheard => _editor.track == null
      ? 'There is no recording.'
      : _editor.usesMidiTempo
          ? 'The anchors follow a MIDI file’s tempo.'
          : !_editor.hasNotes
              ? 'This score has no notes to hear.'
              : !_editor.editsSync
                  ? 'None of the recordings is the one synced.'
                  : null;

  @override
  bool get snaps => _editor.anchors.snapToOnsets;

  @override
  Future<Object?> hear() => _editor.anchors._hear(_report ?? (_) {});

  @override
  Future<List<SyncAnchor>> match(Object heard) => _editor.anchors._match(heard as ({Float32List notes, List<ScorePass> passes}));

  @override
  void setAnchors(List<SyncAnchor> anchors) => _editor.anchors.setAll(anchors);

  @override
  void snapAnchors(double within) => _editor.anchors.snapAll(within);

  @override
  void setSplit(String instrument, bool on) => _editor.setSplit(instrument, on: on);

  @override
  void moveLanes(List<String> ids, {String? before}) {
    final moving = {for (final id in ids) _editor.instrumentOfLane(id)};
    final others = [for (final p in _editor.laneParts) if (!moving.contains(p.id)) p.id];
    _editor.moveLanes(moving, before == null ? others.length : others.indexOf(_editor.instrumentOfLane(before)));
  }

  @override
  void restoreOrder() => _editor.restoreScoreOrder();
}
