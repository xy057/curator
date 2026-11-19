part of '../editor_controller.dart';

/// What changes over the performance ([Automation], the project's: opening, Undo and closing
/// take it): the Video tab's lanes. One now, View: what a frame shows ([SceneView]: the score,
/// the player map, both side by side, or the map in a corner), which the preview, a video and a
/// web page follow. A lane is a [StepLane] of an [AutomationTarget]; another target adds a lane
/// here and in the tab.
class AutomationEditing {
  AutomationEditing._(this._editor);
  final EditorController _editor;

  /// The project's automation (none while nothing changes).
  Automation get automation => _editor._doc.automation ?? Automation.none;

  /// The View lane.
  StepLane<SceneView> get views => automation.steps(SceneViews.target);

  /// Makes [lane] the project's, in place of its target's: an edit (one Undo step, or part of
  /// a gesture's).
  void setSteps<T>(StepLane<T> lane) {
    final next = automation.withSteps(lane);
    if (next == automation) return;
    _editor._doc = _editor._doc.copyWith(automation: next.isEmpty ? null : next);
    _edited();
  }

  void _edited() {
    _editor._edited();
    _followTime();
  }

  // MARK: Selection

  /// The stretch selected in the View lane (an index into [views]'s); null: none.
  int? get selected => _selected;
  int? _selected;

  void select(int? index) {
    if (index == _selected) return;
    _editor.clearSelection();
    _selected = index;
    _editor._changed();
  }

  bool get hasSelection => _selected != null && _selected! < views.stretches.length;

  AutoStretch<SceneView>? get selectedStretch => hasSelection ? views.stretches[_selected!] : null;

  /// Removes the stretch selected: there the score shows again.
  void removeSelected() {
    if (!hasSelection) return;
    final i = _selected!;
    _selected = null;
    setSteps(views.without(i));
  }

  /// The stretch selected changed to [view] (keeping its stretch and fade), over what it then
  /// covers; still selected.
  void setSelectedView(SceneView view) => _reshapeSelected((s) => s.withValue(view));

  /// The stretch selected changes over [seconds] (0: a cut).
  void setSelectedFade(double seconds) => _reshapeSelected((s) => s.withFade(seconds.clamp(0.0, AutoStretch.maxFade).toDouble()));

  void _reshapeSelected(AutoStretch<SceneView> Function(AutoStretch<SceneView>) change) {
    final s = selectedStretch;
    if (s == null) return;
    final next = change(s), lane = views.reshaped(_selected!, next);
    _selected = lane.indexOf(next);
    setSteps(lane);
  }

  /// The view the Draw tool paints, and what the Video tab's picker shows with nothing selected.
  SceneView get drawing => _drawing;
  SceneView _drawing = SceneView.map;
  set drawing(SceneView view) {
    if (view == _drawing) return;
    _drawing = view;
    _editor._changed();
  }

  /// A stretch of [drawing] over score quarters [start]–[end], over what it covers; selected.
  void draw(double start, double end) {
    final s = AutoStretch(start, end, _drawing);
    final lane = views.painted(s);
    _selected = lane.indexOf(s);
    setSteps(lane);
  }

  /// A view over the beat the playhead is in, to where the next stretch starts (else a bar on):
  /// the View lane's Add.
  void addAtPlayhead() {
    final tl = _editor.timeline, seconds = _editor.playback.time.value;
    final q = tl.quarterAtSeconds(seconds).clamp(0.0, tl.measureStarts.last - 1e-6);
    final beat = beatInLanes(_editor, q, pass: tl.passAt(seconds));
    final next = views.stretches.where((s) => s.start > beat.start + 1e-6).firstOrNull?.start;
    final bar = tl.measureStarts.firstWhere((b) => b > beat.start + 1e-6, orElse: () => tl.measureStarts.last);
    draw(beat.start, math.min(next ?? double.infinity, math.max(bar, beat.end)));
  }

  /// ←/→ with a stretch selected: it moves a bar (a beat, [fine]) over what it then covers.
  /// Whether one was selected.
  bool nudgeSelected(int direction, {required bool fine}) {
    final s = selectedStretch;
    if (s == null) return false;
    final to = fine
        ? beatInLanes(_editor, direction > 0 ? s.start + 1e-6 : s.start - 1e-6, pass: 0)
        : null;
    final starts = _editor.timeline.measureStarts, total = starts.last;
    final target = to != null
        ? (direction > 0 ? to.end : to.start)
        : direction > 0
            ? starts.firstWhere((b) => b > s.start + 1e-6, orElse: () => total)
            : starts.lastWhere((b) => b < s.start - 1e-6, orElse: () => 0);
    final delta = (target - s.start).clamp(-s.start, total - s.end).toDouble();
    if (delta.abs() < 1e-9) return true;
    _reshapeSelected((s) => s.withBounds(s.start + delta, s.end + delta));
    return true;
  }

  /// [ / ] with a stretch selected: it starts (ends) at the playhead's beat, unless that would
  /// turn it inside out. Whether one was selected.
  bool trimSelected({required bool start}) {
    final s = selectedStretch;
    if (s == null) return false;
    final sync = _editor._sync;
    if (sync == null) return true;
    final at = sync.nearestGrid(_editor.timeline.quarterAtSeconds(_editor.playback.time.value), SyncGrid.beat);
    if (start ? at >= s.end - 1e-6 : at <= s.start + 1e-6) return true;
    _reshapeSelected((s) => start ? s.withBounds(at, s.end) : s.withBounds(s.start, at));
    return true;
  }

  // MARK: In time

  /// The View lane in the editor's performance: what the preview shows at each time.
  TimedSteps<SceneView> get viewsTimed => _viewsTimed.of(views, _editor.timeline);

  final _viewsTimed = TimedStepsCache<SceneView>();

  /// Whether the preview shows the score where it always is (in the whole frame, as engraved,
  /// nothing mid-change) on the toolbar's Score page ([EditorController.onScorePage]: not MIDI
  /// View, not Player Map, whatever plays there), so what is clicked on it is where it looks:
  /// images and spacers are put in and handled only then. Kept up as the playhead moves and the
  /// toolbar's switch is set.
  final scoreInPlace = ValueNotifier(true);

  /// Whether the preview shows the lane's views whatever the toolbar's switch is on: the lane
  /// has one and the music plays ([Playback.runs]). Stopped, MIDI View and Player Map show
  /// their own again.
  bool get playsViews => _editor.playback.runs && views.stretches.isNotEmpty;

  /// Whether the preview shows the score's notes in rows throughout: the toolbar is on MIDI
  /// View ([EditorController.showsMidiView]) and the lane hasn't the preview ([playsViews]).
  bool get rowsThroughout => _editor.showsMidiView && !playsViews;

  /// What the preview shows now: the View lane's views, or the rows throughout
  /// ([rowsThroughout]).
  StepMix<SceneView> get shown =>
      rowsThroughout ? (from: SceneView.midi, to: SceneView.midi, mix: 0.0) : viewsTimed.at(_editor.playback.time.value);

  void _followTime() {
    if (_editor._score == null || _editor._sync == null || _editor._disposed) return;
    final m = shown;
    final inPlace = _editor.onScorePage && m.from.kind.scoreWhole && (m.mix == 0 || m.to.kind.scoreWhole);
    if (inPlace == scoreInPlace.value) return;
    scoreInPlace.value = inPlace;
    // An image selected is let go of with its handles: Delete takes no image nobody sees selected.
    if (!inPlace) _editor.images._deselect();
    _editor._changed(); // (what the menus and a drop offer follows it)
  }

  void _clearSelection() => _selected = null;

  void _dispose() => scoreInPlace.dispose();
}
