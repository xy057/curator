import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'edit_dialogs.dart';
import 'editor_controller.dart';
import 'error_text.dart';
import 'lanes_common.dart';
import 'media_converter.dart';
import 'menu_kit.dart';
import 'ui_kit.dart';

/// Recordings: audio, or a video whose sound is taken out of it.
final audioTypes = XTypeGroup(label: 'Audio or video', extensions: MediaFormats.all.toList());

/// MIDI files, for their tempo map.
final midiTypes = XTypeGroup(label: 'MIDI', extensions: MediaFormats.midi.toList());

const _anchorLaneHeight = 30.0;
const _tempoLaneHeight = 58.0;
const _grab = 7.0;

/// Audio tab: the recording, the anchors that pin the score to it, and the resulting tempo.
///
/// Tap mode (T): Space starts playback, then each Space marks the bar (or beat) sounding
/// now. ⌥-click adds an anchor · double-click one to type its position, or where it jumps
/// to (a warp) · W makes the selected anchor a warp, or adds one at the playhead.
///
/// Selection: click an anchor · ⇧-click extends · ⌘-click toggles · drag across the anchor
/// lane (or ⇧-drag anywhere) box-selects · ⌘A selects all. The selection then moves together:
/// drag it (the grabbed anchor snaps to note onsets; ⌘ = free) · ←/→ nudge 10 ms (⇧ 1 ms) ·
/// ↑/↓ re-point every selected anchor a bar or beat · Delete removes them.
///
/// With a MIDI tempo map (dropped on the window, or the toolbar's MIDI button) the sync
/// follows the file instead: the anchors, the waveform and tapping give way to the tempo map,
/// drawn large, and edited there (see [_MidiTempoLane]).
class AudioLanes extends StatefulWidget {
  const AudioLanes({super.key, required this.controller});
  final EditorController controller;

  @override
  State<AudioLanes> createState() => _AudioLanesState();
}

class _AudioLanesState extends State<AudioLanes> {
  EditorController get c => widget.controller;
  SyncMap get sync => c.sync!;

  // Dragging a selection: anchors as they were when the drag began, and the one grabbed.
  List<SyncAnchor>? _dragFrom;
  int? _grabbed;
  bool _scrubbing = false;

  /// Box selection in progress (seconds); painted as a band across the lanes.
  final _marquee = ValueNotifier<(double, double)?>(null);
  Set<int> _marqueeKeep = const {};

  final _clicks = DoubleClicks();

  /// Where the pointer was (in seconds) when the current drag began: kept, as the view may
  /// scroll under the drag (it follows the playhead).
  double _downSeconds = 0;
  MouseCursor _cursor = SystemMouseCursors.basic;

  @override
  void dispose() {
    _marquee.dispose();
    super.dispose();
  }

  int? _anchorAt(double x) {
    final anchors = sync.anchors;
    int? best;
    for (var i = 0; i < anchors.length; i++) {
      final d = (c.viewport.x(anchors[i].seconds) - x).abs();
      if (d <= _grab && (best == null || d < (c.viewport.x(anchors[best].seconds) - x).abs())) best = i;
    }
    return best;
  }

  double _snapToOnset(double seconds) {
    final waveform = c.track?.waveform;
    if (waveform == null || isCommandPressed) return seconds;
    return waveform.nearestOnset(seconds, 12 / c.viewport.pxPerSec) ?? seconds;
  }

  void _onDown(PointerDownEvent e) {
    c.captions.select(null); // the Delete key goes to what was clicked here
    if (e.buttons != kPrimaryButton) return;
    final keys = HardwareKeyboard.instance;
    final x = e.localPosition.dx;
    final seconds = c.viewport.seconds(x);
    final hit = _anchorAt(x);
    final doubleClick = _clicks.press(e.timeStamp, e.localPosition);
    _downSeconds = seconds;

    if (hit != null) {
      if (isCommandPressed) {
        c.anchors.select(hit, toggle: true);
        return;
      }
      if (keys.isShiftPressed) {
        c.anchors.select(hit, extend: true);
        return;
      }
      if (doubleClick) {
        c.anchors.select(hit);
        _editPosition(hit);
        return;
      }
      // Grabbing an unselected anchor selects just it; grabbing a selected one drags them all.
      if (!c.anchors.selected.contains(hit)) c.anchors.select(hit);
      c.beginEdit();
      _dragFrom = sync.anchors;
      _grabbed = hit;
      setState(() => _cursor = SystemMouseCursors.grabbing);
    } else if (keys.isAltPressed) {
      final at = _snapToOnset(seconds);
      c.anchors.add(SyncAnchor(sync.nearestGrid(sync.quarterAtSeconds(at), c.anchors.grid), at));
    } else if (e.localPosition.dy < _anchorLaneHeight || keys.isShiftPressed || isCommandPressed) {
      // Box selection: drag across the anchor lane (or ⇧/⌘-drag anywhere); ⇧/⌘ adds to it.
      _marqueeKeep = keys.isShiftPressed || isCommandPressed ? {...c.anchors.selected} : const {};
      _marquee.value = (seconds, seconds);
      c.anchors.selectBetween(seconds, seconds, keep: _marqueeKeep);
    } else {
      c.anchors.select(null);
      _scrubbing = true;
      c.playback.scrub(seconds);
    }
  }

  void _onMove(PointerMoveEvent e) {
    final seconds = c.viewport.seconds(e.localPosition.dx);
    final from = _dragFrom, grabbed = _grabbed;
    if (from != null && grabbed != null) {
      final delta = _snapToOnset(seconds - (_downSeconds - from[grabbed].seconds)) - from[grabbed].seconds;
      c.anchors.drag(delta, from: from);
    } else if (_marquee.value != null) {
      _marquee.value = (_marquee.value!.$1, seconds);
      c.anchors.selectBetween(_marquee.value!.$1, seconds, keep: _marqueeKeep);
    } else if (_scrubbing) {
      c.playback.scrub(seconds);
    }
  }

  void _onUp(PointerEvent e) {
    if (_dragFrom != null) {
      c.endEdit();
      _dragFrom = null;
      _grabbed = null;
      setState(() => _cursor = SystemMouseCursors.basic);
    }
    _marquee.value = null;
    if (_scrubbing) c.playback.endScrub();
    _scrubbing = false;
  }

  void _onHover(PointerHoverEvent e) {
    final cursor = _anchorAt(e.localPosition.dx) != null
        ? SystemMouseCursors.grab
        : HardwareKeyboard.instance.isAltPressed
            ? SystemMouseCursors.precise
            : SystemMouseCursors.basic;
    if (cursor != _cursor) setState(() => _cursor = cursor);
  }

  Future<void> _editPosition(int index) => _editAnchor(context, c, index);

  @override
  Widget build(BuildContext context) => Select(
        listenable: c,
        select: () => (sync: c.sync, midi: c.midiTempo, track: c.track, loading: c.isLoadingAudio),
        builder: (context, _) => _lanes(context),
      );

  Widget _lanes(BuildContext context) {
    if (c.midiTempo case final midi?) return _MidiTempoLane(controller: c, name: midi.name);
    final track = c.track;
    final colors = context.colors;
    final repaint = Listenable.merge([c.viewport, sync, c, _marquee]);
    final lanes = MouseRegion(
      cursor: _cursor,
      onHover: _onHover,
      child: Listener(
        onPointerDown: _onDown,
        onPointerMove: _onMove,
        onPointerUp: _onUp,
        onPointerCancel: _onUp,
        // One playhead through the three lanes.
        child: WithPlayhead(controller: c, child: Column(children: [
          SizedBox(
            height: _anchorLaneHeight,
            child: CustomPaint(size: Size.infinite, painter: _AnchorPainter(c, colors, _marquee, repaint)),
          ),
          Expanded(
            child: Stack(fit: StackFit.expand, children: [
              CustomPaint(painter: _WaveformPainter(c, colors, _marquee, repaint)),
              if (track == null)
                Center(
                  child: Text(
                    c.isLoadingAudio
                        ? 'Reading the recording…'
                        : 'Drop a recording or a MIDI file',
                    style: TextStyle(color: colors.textMuted, fontSize: 12),
                  ),
                ),
            ]),
          ),
          SizedBox(
            height: _tempoLaneHeight,
            child: CustomPaint(size: Size.infinite, painter: _TempoPainter(c, colors, repaint)),
          ),
        ])),
      ),
    );

    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        width: kLaneHeaderWidth,
        child: Column(children: [
          const LaneLabel(height: _anchorLaneHeight, child: Text('Anchors')),
          Expanded(
            child: LaneLabel(
              height: double.infinity,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Recording'),
                  if (track != null)
                    Text(track.name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: colors.textMuted)),
                ],
              ),
            ),
          ),
          const LaneLabel(
            height: _tempoLaneHeight,
            child: Tip(message: 'Beats per minute', child: Text('Tempo')),
          ),
        ]),
      ),
      Expanded(child: lanes),
    ]);
  }
}

/// The MIDI tempo map in place of the anchors, the waveform and the tempo lane, edited as a
/// sequencer's tempo track is: drag a change (up and down its tempo, sideways its place,
/// snapped to beats; ⌘ = free, to a tenth of a beat a minute), or the step after it for its
/// tempo only; ⌥-click on the line adds a change at the nearest beat, ⌥-drag draws a step a
/// beat; Delete removes the selected change. A click elsewhere moves the playhead. Warps (W)
/// are lines across it; double-click one to change or remove it.
class _MidiTempoLane extends StatefulWidget {
  const _MidiTempoLane({required this.controller, required this.name});
  final EditorController controller;
  final String name;

  @override
  State<_MidiTempoLane> createState() => _MidiTempoLaneState();
}

class _MidiTempoLaneState extends State<_MidiTempoLane> {
  EditorController get c => widget.controller;

  /// The scale held while a gesture lasts, so the lane doesn't re-fit under the pointer.
  final _scale = ValueNotifier<_TempoScale?>(null);
  Size _size = Size.zero;
  MouseCursor _cursor = SystemMouseCursors.basic;
  bool _scrubbing = false;

  // Dragging change [_index] of [_from]: taken by its dot ([_byDot]), also sideways
  // ([_sideways], once past a few pixels).
  MidiTempoMap? _from;
  int _index = 0;
  bool _byDot = false, _sideways = false;
  Offset _down = Offset.zero;
  double _downBpm = 0;

  // Drawing over [_drawFrom]: the beats drawn (beats a minute by beat start), and the last point.
  // [_inserting]: ⌥ went down on the line, which put a change there; moving draws instead.
  MidiTempoMap? _drawFrom;
  bool _inserting = false;
  final _drawn = SplayTreeMap<double, double>();
  (double quarter, double bpm)? _last;

  /// The map the gesture under way last made: when the map is another (Undo meanwhile), the
  /// gesture is over.
  MidiTempoMap? _made;

  bool get _editing => _from != null || _drawFrom != null;

  /// Follows [map], made by the gesture under way.
  void _edit(MidiTempoMap map) {
    c.editMidiTempo(map);
    _made = c.midiTempo;
  }

  /// Ends the gesture under way (one Undo step).
  void _endEdit() {
    if (!_editing) return;
    c.endEdit();
    _from = _drawFrom = null;
    _scale.value = null;
  }

  @override
  void dispose() {
    // Gone mid-gesture (Undo back past the MIDI file): the gesture ends here, after this frame
    // (ending it tells the controller's listeners), not at the pointer's release, which still
    // comes to this state's handlers.
    if (_editing) {
      _from = _drawFrom = null;
      scheduleMicrotask(c.endEdit);
    }
    _scale.dispose();
    super.dispose();
  }

  _TempoScale get _currentScale => _scale.value ?? _TempoScale.fit(c, _size.width, large: true);

  /// The map followed, in the score: where the file's quarters fall in it, and its beats.
  MidiInScore get _placed => MidiInScore(c.midiTempo!, c.sync!);

  static double _bpmOf(double value) =>
      (isCommandPressed ? (value * 10).roundToDouble() / 10 : value.roundToDouble()).clamp(10.0, 600.0);

  double _x(MidiTempoMap midi, double quarter) => c.viewport.x(c.sync!.startSeconds + midi.secondsAt(quarter));

  /// The change under [p]: on its dot ([dot]), or on the step after it.
  ({int index, bool dot})? _hit(Offset p) {
    final midi = c.midiTempo, sync = c.sync;
    if (midi == null || sync == null) return null;
    final scale = _currentScale;
    ({int index, bool dot})? step;
    final end = _placed.end;
    for (final (i, t) in midi.tempos.indexed) {
      if (t.quarter >= end) break;
      final x = _x(midi, t.quarter), y = scale.y(t.quartersPerMinute / _placed.beatLength(t.quarter), _size);
      if ((p.dx - x).abs() <= _grab && (p.dy - y).abs() <= _grab + 2) return (index: i, dot: true);
      final next = i + 1 < midi.tempos.length ? math.min(midi.tempos[i + 1].quarter, end) : end;
      if (p.dx > x && p.dx < _x(midi, next) && (p.dy - y).abs() <= 5) step = (index: i, dot: false);
    }
    return step;
  }

  /// The warp (its place among the map's warps) whose line is under [p].
  int? _warpAt(Offset p) {
    for (final (i, seconds) in _placed.warpSeconds.indexed) {
      if ((c.viewport.x(seconds) - p.dx).abs() <= 4) return i;
    }
    return null;
  }

  final _clicks = DoubleClicks();

  void _onDown(PointerDownEvent e) {
    c.captions.select(null); // the Delete key goes to what was clicked here
    final midi = c.midiTempo;
    if (e.buttons != kPrimaryButton || midi == null) return;
    final doubleClick = _clicks.press(e.timeStamp, e.localPosition);
    final hit = _hit(e.localPosition);
    final warp = hit == null ? _warpAt(e.localPosition) : null;
    if (doubleClick && warp != null && !HardwareKeyboard.instance.isAltPressed) {
      // Where it jumps from and to; an empty jump removes it.
      _scrubbing = false;
      c.playback.endScrub();
      editMidiWarp(context, c, index: warp);
    } else if (HardwareKeyboard.instance.isAltPressed) {
      c.beginEdit();
      _scale.value = _currentScale;
      _drawFrom = _made = midi;
      _drawn.clear();
      _last = null;
      _down = e.localPosition;
      _inserting = hit != null;
      if (_inserting) {
        // On the line: a change at the beat nearest, keeping its tempo; drawing once it moves.
        var quarter = midi.quarterAt(c.viewport.seconds(e.localPosition.dx) - c.sync!.startSeconds);
        if (!isCommandPressed) quarter = _placed.snap(quarter);
        final inserted = quarter < _placed.end ? midi.inserted(quarter) : midi;
        _edit(inserted);
        final index = inserted.tempos.indexWhere((t) => t.quarter == quarter);
        c.anchors.selectTempo(index < 0 ? null : index);
      } else {
        c.anchors.selectTempo(null);
        _draw(e.localPosition);
      }
    } else if (hit != null) {
      c.anchors.selectTempo(hit.index);
      c.beginEdit();
      _scale.value = _currentScale;
      _from = _made = midi;
      _index = hit.index;
      _byDot = hit.dot;
      _sideways = false;
      _down = e.localPosition;
      final t = midi.tempos[hit.index];
      _downBpm = t.quartersPerMinute / _placed.beatLength(t.quarter);
    } else {
      c.anchors.selectTempo(null);
      _scrubbing = true;
      c.playback.scrub(c.viewport.seconds(e.localPosition.dx));
    }
  }

  void _onMove(PointerMoveEvent e) {
    final p = e.localPosition;
    if (_editing && c.midiTempo != _made) return _endEdit(); // undone meanwhile: what it began from is gone
    if (_drawFrom != null) {
      if (_inserting) {
        if ((p - _down).distance <= 4) return;
        _inserting = false;
        c.anchors.selectTempo(null);
        _draw(_down);
      }
      _draw(p);
    } else if (_from case final from?) {
      final scale = _scale.value!, t = from.tempos[_index];
      final bpm = _bpmOf(_downBpm + scale.bpm(p.dy, _size) - scale.bpm(_down.dy, _size));
      var quarter = t.quarter;
      _sideways = _sideways || (_byDot && _index > 0 && (p.dx - _down.dx).abs() > 4);
      if (_sideways) {
        // Where the change is taken, as a quarter at the tempo before it (which holds up to it).
        final previous = from.tempos[_index - 1];
        final seconds = from.secondsAt(t.quarter) + c.viewport.seconds(p.dx) - c.viewport.seconds(_down.dx);
        quarter = previous.quarter + (seconds - from.secondsAt(previous.quarter)) * previous.quartersPerMinute / 60;
        if (!isCommandPressed) quarter = _placed.snap(quarter);
      }
      _edit(from.moved(_index, quarter: quarter, quartersPerMinute: bpm * _placed.beatLength(quarter)));
    } else if (_scrubbing) {
      c.playback.scrub(c.viewport.seconds(p.dx));
    }
  }

  /// Draws a step at every beat the pointer passed since the last point, the tempo going
  /// evenly from the last point's to this one's. The pointer is read on the map as the drawing
  /// began ([_drawFrom]): on the one drawn, each step would move the beats under it.
  void _draw(Offset p) {
    final sync = c.sync!, from = _drawFrom!, end = _placed.end;
    final quarter = from.quarterAt(c.viewport.seconds(p.dx) - sync.startSeconds).clamp(0.0, end - 1e-6);
    final bpm = _bpmOf(_scale.value!.bpm(p.dy, _size));
    final last = _last ?? (quarter, bpm);
    _last = (quarter, bpm);
    final lo = math.min(last.$1, quarter), hi = math.max(last.$1, quarter);
    for (var b = _placed.beatAround(lo).start;;) {
      final f = hi > lo ? ((b.clamp(lo, hi) - last.$1) / (quarter - last.$1)).clamp(0.0, 1.0) : 1.0;
      _drawn[b] = _bpmOf(last.$2 + (bpm - last.$2) * f);
      final next = _placed.beatAround(b + 1e-7).end;
      if (next <= b + 1e-9 || next > hi) break;
      b = next;
    }
    final until = _placed.beatAround(_drawn.lastKey()! + 1e-7).end;
    _edit(from.drawn([
      for (final MapEntry(key: q, value: bpm) in _drawn.entries) (quarter: q, quartersPerMinute: bpm * _placed.beatLength(q)),
    ], until: until > _drawn.lastKey()! ? until : end));
  }

  void _onUp(PointerEvent e) {
    _endEdit();
    if (_scrubbing) c.playback.endScrub();
    _scrubbing = false;
  }

  void _onHover(PointerHoverEvent e) {
    final hit = HardwareKeyboard.instance.isAltPressed ? null : _hit(e.localPosition);
    final cursor = HardwareKeyboard.instance.isAltPressed
        ? SystemMouseCursors.precise
        : hit == null
            ? (_warpAt(e.localPosition) != null ? SystemMouseCursors.click : SystemMouseCursors.basic)
            : hit.dot && hit.index > 0
                ? SystemMouseCursors.move
                : SystemMouseCursors.resizeUpDown;
    if (cursor != _cursor) setState(() => _cursor = cursor);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final repaint = Listenable.merge([c.viewport, c.sync, c, _scale]);
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        width: kLaneHeaderWidth,
        child: LaneLabel(
          height: double.infinity,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Tip(message: 'Beats per minute\n${shortcut('⌥ add, draw · ⌘ no snap')}', child: const Text('MIDI tempo')),
              Text(widget.name, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: colors.textMuted)),
              if (c.track case final track?)
                Text('♪ ${track.name}', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: colors.textMuted)),
            ],
          ),
        ),
      ),
      Expanded(
        child: LayoutBuilder(builder: (context, constraints) {
          _size = constraints.biggest;
          return MouseRegion(
            cursor: _cursor,
            onHover: _onHover,
            child: Listener(
              onPointerDown: _onDown,
              onPointerMove: _onMove,
              onPointerUp: _onUp,
              onPointerCancel: _onUp,
              child: WithPlayhead(
                controller: c,
                child: CustomPaint(size: Size.infinite, painter: _TempoPainter(c, colors, repaint, large: true, scale: _scale)),
              ),
            ),
          );
        }),
      ),
    ]);
  }
}

/// Opens anchor [index]'s position and jump to edit ([warp]: starting with the jump).
Future<void> _editAnchor(BuildContext context, EditorController c, int index, {bool warp = false}) async {
  final sync = c.sync!;
  final a = sync.anchors[index];
  final set = await showAnchorDialog(context, beats: sync.beats, quarter: a.quarter, jumpTo: a.jumpTo, warp: warp);
  if (set == null || !context.mounted || index >= sync.anchors.length) return;
  if (!c.anchors.setAnchor(index, set.quarter, jumpTo: set.jumpTo)) {
    _refused(context, set.jumpTo == a.jumpTo ? 'Choose a position between the neighboring anchors.' : null);
  }
}

void _refused(BuildContext context, String? why) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(why ?? 'This jump would put anchors out of order or past the end of the score.')));

/// Warp (W): makes the selected anchor jump (back for a repeat, on to a coda), or adds a
/// warp at the playhead, on the bar (or beat) sounding there.
Future<void> editWarp(BuildContext context, EditorController c) async {
  final sync = c.sync;
  if (sync == null) return;
  if (c.usesMidiTempo) return editMidiWarp(context, c);
  final selected = c.anchors.selected.where((i) => i < sync.anchors.length);
  if (selected.length == 1) return _editAnchor(context, c, selected.single, warp: true);

  var t = c.playback.time.value;
  final onset = c.anchors.snapToOnsets ? c.track?.waveform.nearestOnset(t, 0.08) : null;
  if (onset != null) t = onset;
  final quarter = sync.nearestGrid(sync.quarterAtSeconds(t), c.anchors.grid);
  final set = await showAnchorDialog(context, beats: sync.beats, quarter: quarter, warp: true);
  if (set == null || !context.mounted) return;
  if (!c.anchors.addWarp(t, set.quarter, set.jumpTo)) _refused(context, null);
}

/// A MIDI tempo map's warp [index] to edit (an empty jump removes it), or with none, one to
/// add at the playhead, on the bar (or beat) sounding there. The file plays on through a warp:
/// moving where it arrives moves the moment the file jumps; the warps after it keep theirs.
/// Warps that don't fit the score (a damaged project's: not shown, not followed) go with it.
Future<void> editMidiWarp(BuildContext context, EditorController c, {int? index}) async {
  final sync = c.sync!, midi = c.midiTempo!;
  // The warps followed: the lines drawn, [index] one of them.
  final arrivals = midi.arrivals(sync.totalQuarters);
  final followed = midi.warps.take(arrivals.length).toList();
  final MidiWarp? warp = index != null && index < arrivals.length ? followed[index] : null;
  final double at, arrival;
  if (warp != null) {
    at = warp.at;
    arrival = arrivals[index!];
  } else {
    final t = c.playback.time.value, q = sync.quarterAtSeconds(t);
    arrival = sync.nearestGrid(q, c.anchors.grid);
    at = midi.quarterAt(t - sync.startSeconds) + arrival - q;
  }
  final set = await showAnchorDialog(context, beats: sync.beats, quarter: arrival, jumpTo: warp?.jumpTo, warp: true);
  if (set == null || !context.mounted || c.midiTempo != midi) return;
  final others = [...followed]..remove(warp);
  final moved = at + set.quarter - arrival;
  if (set.jumpTo case final jumpTo?) {
    if (others.any((w) => (w.at - moved).abs() < 1e-6) || !c.setMidiWarps([...others, (at: moved, jumpTo: jumpTo)])) {
      _refused(context, null);
    }
  } else if (warp != null) {
    c.setMidiWarps(others);
  }
}

/// Audio tab tools (right of the tab switch). Every control explains itself on hover.
class AudioToolbar extends StatelessWidget {
  const AudioToolbar({super.key, required this.controller});
  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final sync = c.sync!;
    return ListenableBuilder(
      listenable: Listenable.merge([sync, c]),
      builder: (context, _) => Row(children: [
        ToolbarButton(
          icon: c.track == null ? AppIcon.addAudio.of(context) : AppIcon.replaceAudio.of(context),
          tooltip: c.track == null
              ? 'Add Recording… (or drop one here)'
              : 'Replace recording…\n${c.track!.name}',
          onPressed: c.isLoadingAudio ? null : () => pickAudio(context, c),
        ),
        ToolbarButton(
          icon: AppIcon.tempoMap.of(context),
          tooltip: c.midiTempo == null ? 'Add MIDI Tempo Map… (or drop one here)' : 'Stop following ${c.midiTempo!.name}',
          selected: c.usesMidiTempo,
          onPressed: () => c.usesMidiTempo ? c.useMidiTempo(null) : pickMidi(context, c),
        ),
        if (!c.usesMidiTempo) _TapButton(controller: c),
        ToolbarButton(
          icon: AppIcon.warp.of(context),
          tooltip: c.anchors.selected.length == 1 && !c.usesMidiTempo
              ? 'Warp (W)\nMake this anchor jump to another bar'
              : 'Warp (W)\nJump to another bar here',
          onPressed: () => editWarp(context, c),
        ),
        if (c.midiTempo case final midi?)
          ToolbarButton(
            icon: AppIcon.repeat.of(context),
            tooltip: 'Warps from score',
            onPressed: c.scoreWarps.isEmpty || listEquals(midi.warps, c.scoreWarps) ? null : c.useScoreWarps,
          ),
        if (!c.usesMidiTempo) ...[
          const ToolbarDivider(),
          Tip(
            message: 'Step for taps, ${shortcut('Option-click', 'Alt+click')}, and ↑/↓',
            child: ToolGroup(children: [
              for (final (grid, label) in const [(SyncGrid.bar, 'Bar'), (SyncGrid.beat, 'Beat')])
                _TextToggle(label: label, selected: c.anchors.grid == grid, onPressed: () => c.anchors.grid = grid),
            ]),
          ),
          const SizedBox(width: 2),
          ToolbarButton(
            icon: AppIcon.snap.of(context),
            tooltip: c.anchors.snapToOnsets
                ? 'Snap to notes (on)'
                : 'Snap to notes (off)',
            selected: c.anchors.snapToOnsets,
            onPressed: () => c.anchors.snapToOnsets = !c.anchors.snapToOnsets,
          ),
        ],
        const ToolbarDivider(),
        _SpeedMenu(controller: c),
        const SizedBox(width: 8),
        _StartField(controller: c),
        const Spacer(),
        FadeSlideSwitcher(
          alignment: Alignment.centerRight,
          child: c.anchors.selected.length < 2
              ? const SizedBox.shrink()
              : Padding(
                  key: const ValueKey('selection'),
                  padding: const EdgeInsets.only(right: 4),
                  child: Tip(
                    message: '↑/↓ re-point · ←/→ nudge · ${shortcut('⌫', 'Delete')} remove',
                    child: InputChip(
                      visualDensity: VisualDensity.compact,
                      label: Text('${c.anchors.selected.length} anchors', style: const TextStyle(fontSize: 12)),
                      onDeleted: () => c.anchors.select(null),
                      deleteButtonTooltipMessage: 'Deselect (Esc)',
                    ),
                  ),
                ),
        ),
        if (!c.usesMidiTempo)
          ToolbarButton(
            icon: AppIcon.clearAnchors.of(context),
            tooltip: 'Remove all anchors',
            onPressed: sync.anchors.isEmpty ? null : c.anchors.clear,
          ),
      ]),
    );
  }
}

/// Playback speed: "100% ▾", a menu as the video ratio and the transition are.
class _SpeedMenu extends StatelessWidget {
  const _SpeedMenu({required this.controller});
  final EditorController controller;

  static String _label(double speed) => '${(speed * 100).round()}%';

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final speed = controller.playback.speed;
    return OverlaySemantics(
      child: AppPopupMenuButton<double>(
        tooltip: 'Playback speed',
        position: PopupMenuPosition.under,
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.only(left: 6, right: 2),
          shape: RoundedRectangleBorder(borderRadius: AppStyle.of(context).radius(8)),
        ),
        onSelected: (s) => controller.playback.speed = s,
        itemBuilder: (context) => [
          for (final s in const [0.5, 0.75, 1.0]) checkedMenuItem(context, value: s, checked: s == speed, child: Text(_label(s))),
        ],
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(AppIcon.speed.of(context), size: 16, color: colors.textMuted),
          const SizedBox(width: 5),
          Text(_label(speed),
              style: TextStyle(fontSize: 12.5, color: colors.text, fontFeatures: const [FontFeature.tabularFigures()])),
          Icon(AppIcon.dropDown.of(context), size: 18, color: colors.textMuted),
        ]),
      ),
    );
  }
}

/// Tap mode (T): a record-like toggle that breathes while armed.
class _TapButton extends StatelessWidget {
  const _TapButton({required this.controller});
  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final colors = context.colors;
    return Tip(
      message: c.anchors.tapArmed
          ? 'Space marks · T or Esc stops'
          : 'Tap anchors (T)',
      child: AnimatedContainer(
        duration: stateDuration(motion(context, 200)),
        curve: Curves.easeOut,
        height: 32,
        padding: EdgeInsets.symmetric(horizontal: c.anchors.tapArmed ? 8 : 0),
        decoration: BoxDecoration(
          color: c.anchors.tapArmed ? colors.recordingWash : Colors.transparent,
          borderRadius: AppStyle.of(context).radius(8),
        ),
        child: InkWell(
          borderRadius: AppStyle.of(context).radius(8),
          onTap: () => c.anchors.tapArmed = !c.anchors.tapArmed,
          child: SizedBox(
            height: 32,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (c.anchors.tapArmed) ...[
                PulsingDot(color: colors.recording, size: 9),
                const SizedBox(width: 4),
                Text('Space', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: colors.recording)),
              ] else
                SizedBox.square(dimension: 32, child: Icon(AppIcon.tap.of(context), size: 18, color: colors.text)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A short text choice inside a [ToolGroup].
class _TextToggle extends StatelessWidget {
  const _TextToggle({required this.label, required this.selected, required this.onPressed});
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // On: the same neutral fill as a selected toolbar button, the text not tinted.
    final style = AppStyle.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final on = CarbonColors.maybeOf(context)?.backgroundSelected ??
        (dark ? Colors.white : Colors.black).withValues(alpha: dark ? 0.1 : 0.05);
    final radius = style.radius(5);
    return InkWell(
      borderRadius: radius,
      onTap: onPressed,
      child: AnimatedContainer(
        duration: stateDuration(motion(context, 150)),
        height: style.control,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: selected ? on : Colors.transparent, borderRadius: radius),
        child: Text(label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              color: selected ? colors.text : colors.textMuted,
            )),
      ),
    );
  }
}

Future<void> pickAudio(BuildContext context, EditorController c) async {
  final file = await openFile(acceptedTypeGroups: [audioTypes]);
  if (file == null) return;
  try {
    await c.loadAudio(file.path);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Couldn’t load the recording. ${describeError(e)}')));
    }
  }
}

Future<void> pickMidi(BuildContext context, EditorController c) async {
  final file = await openFile(acceptedTypeGroups: [midiTypes]);
  if (file == null) return;
  try {
    final taken = await c.loadMidiTempo(file.path);
    if (context.mounted) showMidiWarpsTaken(context, c, taken);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Couldn’t use the MIDI file. ${describeError(e)}')));
    }
  }
}

/// Says where the MIDI tempo map just read took its warps from ([EditorController.loadMidiTempo]),
/// when it took any, with Remove (one Undo step) for a file that plays straight through.
void showMidiWarpsTaken(BuildContext context, EditorController c, MidiWarpsTaken? taken) {
  if (taken == null) return;
  final map = c.midiTempo;
  final warps = taken.count == 1 ? '1 warp' : '${taken.count} warps';
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(switch (taken.from) {
      MidiWarpsFrom.file => 'Kept $warps from ${taken.file}',
      MidiWarpsFrom.anchors => 'Kept $warps from the anchors',
      MidiWarpsFrom.score => '$warps from the score’s repeats',
    }),
    action: SnackBarAction(
      label: 'Remove',
      onPressed: () {
        if (c.midiTempo == map) c.setMidiWarps(const []);
      },
    ),
  ));
}

/// "Starts at": where bar 1 sounds in the recording (the blank time before the music).
class _StartField extends StatefulWidget {
  const _StartField({required this.controller});
  final EditorController controller;

  @override
  State<_StartField> createState() => _StartFieldState();
}

class _StartFieldState extends State<_StartField> {
  final _text = TextEditingController();
  final _focus = FocusNode();

  /// What had the keyboard before the field took it (by a click, Tab or otherwise), given back on Enter.
  FocusNode? _before;

  void _track() {
    final now = FocusManager.instance.primaryFocus;
    if (now != _focus) _before = now;
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_show);
    _focus.addListener(_focusChanged);
    FocusManager.instance.addListener(_track);
    _track();
    _show();
  }

  @override
  void didUpdateWidget(_StartField old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_show);
      widget.controller.addListener(_show);
      _show();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_show);
    FocusManager.instance.removeListener(_track);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Leaving the field (a click elsewhere, Tab) sets what was typed, as Enter does.
  void _focusChanged() {
    if (!_focus.hasFocus) _apply();
    _show();
  }

  void _apply() {
    final seconds = double.tryParse(_text.text), sync = widget.controller.sync;
    if (seconds != null && sync != null && _text.text != sync.startSeconds.toStringAsFixed(2)) {
      widget.controller.anchors.setStart(seconds);
    }
  }

  /// Shows the start as it is now, unless it is being typed.
  void _show() {
    final sync = widget.controller.sync;
    if (sync == null || _focus.hasFocus) return;
    final text = sync.startSeconds.toStringAsFixed(2);
    if (_text.text != text) _text.text = text;
  }

  /// Gives the keyboard back to what had it (the window, under its shortcuts); a bare unfocus
  /// would leave it on the route's scope, above them, and Space, T, ⌘Z… would stop working.
  void _leave() {
    final before = _before;
    if (before != null && before.context != null && before.canRequestFocus) {
      before.requestFocus();
    } else {
      _focus.unfocus();
    }
  }

  /// Escape: leaves the field as it was, keeping nothing typed (as the time readout does).
  void _cancel() {
    final sync = widget.controller.sync;
    if (sync != null) _text.text = sync.startSeconds.toStringAsFixed(2);
    _leave();
  }

  @override
  Widget build(BuildContext context) {
    return Tip(
      message: 'Silence before bar 1 (s)',
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(AppIcon.leadIn.of(context), size: 17, color: context.colors.textMuted),
        const SizedBox(width: 4),
        // Shaped as the time readout's field.
        SizedBox(
          width: 64,
          height: 26,
          child: CallbackShortcuts(
            bindings: {const SingleActivator(LogicalKeyboardKey.escape): _cancel},
            child: TextField(
              controller: _text,
              focusNode: _focus,
              style: TextStyle(fontSize: 12.5, color: context.colors.text, fontFeatures: const [FontFeature.tabularFigures()]),
              textAlign: TextAlign.right,
              decoration: InputDecoration(
                isDense: true,
                suffixText: 's',
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                enabledBorder: OutlineInputBorder(
                  borderRadius: AppStyle.of(context).radius(6),
                  borderSide: BorderSide(color: context.colors.line),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: AppStyle.of(context).radius(6),
                  borderSide: BorderSide(color: context.colors.accent),
                ),
              ),
              onSubmitted: (_) {
                _apply();
                _leave();
              },
            ),
          ),
        ),
      ]),
    );
  }
}

// MARK: - Painting

/// The box-selection band, drawn behind the anchors.
void _paintMarquee(Canvas canvas, Size size, EditorController c, AppColors colors, (double, double)? marquee) {
  if (marquee == null) return;
  final x0 = c.viewport.x(marquee.$1), x1 = c.viewport.x(marquee.$2);
  final rect = Rect.fromLTRB(math.min(x0, x1), 0, math.max(x0, x1), size.height);
  // As the Instruments tab draws its box.
  canvas.drawRect(rect, Paint()..color = colors.accentStrong.withValues(alpha: 0.08));
  canvas.drawRect(
    rect,
    Paint()
      ..style = PaintingStyle.stroke
      ..color = colors.accentStrong.withValues(alpha: 0.6),
  );
}

class _AnchorPainter extends CustomPainter {
  _AnchorPainter(this.c, this.colors, this.marquee, Listenable repaint) : super(repaint: repaint);
  final EditorController c;
  final AppColors colors;
  final ValueListenable<(double, double)?> marquee;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, Paint()..color = c.anchors.tapArmed ? colors.recordingWash : colors.accentWash);
    canvas.drawLine(Offset(0, size.height - 0.5), Offset(size.width, size.height - 0.5), Paint()..color = colors.line);
    _paintMarquee(canvas, size, c, colors, marquee.value);
    final sync = c.sync!;
    final v = c.viewport;
    var lastLabelEnd = double.negativeInfinity;
    for (final (i, a) in sync.anchors.indexed) {
      final x = v.x(a.seconds);
      if (x < -20 || x > size.width + 20) continue;
      // The colour says whether it is selected; a warp says so by its ring and label.
      final selected = c.anchors.selected.contains(i);
      final color = selected ? colors.accentStrong : colors.accent;
      final y = size.height / 2 + 4;
      final diamond = Path()
        ..moveTo(x, y - 6)
        ..lineTo(x + 5, y)
        ..lineTo(x, y + 6)
        ..lineTo(x - 5, y)
        ..close();
      canvas.drawPath(diamond, Paint()..color = color);
      if (a.isWarp) {
        // A warp: ringed, and labelled with where it jumps to.
        final ring = Path()
          ..moveTo(x, y - 8)
          ..lineTo(x + 7, y)
          ..lineTo(x, y + 8)
          ..lineTo(x - 7, y)
          ..close();
        canvas.drawPath(
            ring,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.2
              ..color = color);
      }
      final label = a.isWarp
          ? '${sync.beats.format(a.quarter, compact: true)}→${sync.beats.format(a.jumpTo!, compact: true)}'
          : sync.beats.format(a.quarter, compact: true);
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            fontSize: 10.5,
            color: selected ? colors.accentStrong : a.isWarp ? colors.text : colors.textMuted,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      if (selected || x - tp.width / 2 > lastLabelEnd + 3) {
        tp.paint(canvas, Offset(x - tp.width / 2, 1));
        lastLabelEnd = x + tp.width / 2;
      }
      tp.dispose();
    }
  }

  @override
  bool shouldRepaint(_AnchorPainter old) => true;
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter(this.c, this.colors, this.marquee, Listenable repaint) : super(repaint: repaint);
  final EditorController c;
  final AppColors colors;
  final ValueListenable<(double, double)?> marquee;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.surface);
    final v = c.viewport;
    final sync = c.sync!;

    // Blank time before bar 1.
    final startX = v.x(sync.startSeconds);
    if (startX > 0) {
      canvas.drawRect(Rect.fromLTRB(0, 0, math.min(startX, size.width), size.height), Paint()..color = colors.grid.withValues(alpha: 0.6));
    }
    paintBarGrid(canvas, size, c, colors);

    final track = c.track;
    if (track != null) {
      final waveform = track.waveform;
      final mid = size.height / 2;
      final paint = Paint()
        ..color = colors.waveform
        ..strokeWidth = 1;
      final path = Path();
      for (var x = 0.0; x < size.width; x += 1) {
        final t0 = v.seconds(x), t1 = v.seconds(x + 1);
        if (t1 < 0 || t0 > track.length) continue;
        final h = math.max(0.5, math.sqrt(waveform.peak(math.max(0, t0), t1)) * (mid - 4));
        path
          ..moveTo(x + 0.5, mid - h)
          ..lineTo(x + 0.5, mid + h);
      }
      canvas.drawPath(path, paint..style = PaintingStyle.stroke);

      // Note onsets: small ticks, the targets taps and drags snap to.
      final onset = Paint()..color = colors.onset;
      final left = v.seconds(0), right = v.seconds(size.width);
      if ((right - left) < 120) {
        for (final o in waveform.onsets) {
          if (o < left || o > right) continue;
          final x = v.x(o);
          canvas.drawLine(Offset(x, 0), Offset(x, 5), onset);
        }
      }
    }

    // Anchors across the recording.
    for (final (i, a) in sync.anchors.indexed) {
      final x = v.x(a.seconds);
      if (x < 0 || x > size.width) continue;
      final width = a.isWarp ? 2.0 : 1.0; // a warp: where the score jumps
      canvas.drawRect(
        Rect.fromLTWH(x - width / 2, 0, width, size.height),
        Paint()
          ..color = c.anchors.selected.contains(i) ? colors.accentStrong : colors.accent.withValues(alpha: 0.7),
      );
    }
    _paintMarquee(canvas, size, c, colors, marquee.value);
  }

  @override
  bool shouldRepaint(_WaveformPainter old) => true;
}

/// The tempo lane's steps: start and end (seconds), beats a minute, and whether extrapolated
/// (before the first anchor or after the last), one per segment between anchors.
List<(double, double, double, bool)> _tempoSteps(EditorController c, double width) {
  final sync = c.sync!;
  final v = c.viewport;
  final anchors = sync.anchors;
  final steps = <(double, double, double, bool)>[];
  final end = math.max(c.playback.duration, v.seconds(width));
  // Quarter notes a minute → the meter's beats a minute, at the beat where [seconds] falls.
  double bpm(double quartersPerMinute, double seconds) {
    final q = sync.quarterAtSeconds(seconds).clamp(0.0, sync.totalQuarters);
    final beat = sync.beats.beatAt(q.toDouble());
    final length = beat.end - beat.start;
    return length > 1e-9 ? quartersPerMinute / length : quartersPerMinute;
  }

  void add(double s0, double s1, double quartersPerMinute, bool extrapolated) =>
      steps.add((s0, s1, bpm(quartersPerMinute, math.max(s0, 0)), extrapolated));
  if (anchors.length < 2) {
    final start = anchors.isEmpty ? sync.startSeconds : anchors.first.seconds;
    add(start, end, sync.defaultTempo, true);
  } else {
    add(v.seconds(0), anchors.first.seconds, sync.segmentTempo(0), true);
    for (var i = 0; i + 1 < anchors.length; i++) {
      add(anchors[i].seconds, anchors[i + 1].seconds, sync.segmentTempo(i), false);
    }
    add(anchors.last.seconds, end, sync.segmentTempo(anchors.length - 2), true);
  }
  return steps;
}

/// The tempo lane's height: beats a minute from [lo] (at the bottom margin) to [hi] (at the top).
@immutable
class _TempoScale {
  const _TempoScale(this.lo, this.hi, {required this.large});

  /// Fits the steps in view, at least 20 beats a minute apart.
  factory _TempoScale.fit(EditorController c, double width, {required bool large}) {
    final bpms = [for (final s in _tempoSteps(c, width)) s.$3];
    var lo = bpms.reduce(math.min), hi = bpms.reduce(math.max);
    if (hi - lo < 20) {
      final m = (hi + lo) / 2;
      lo = m - 10;
      hi = m + 10;
    }
    return _TempoScale(lo, hi, large: large);
  }

  final double lo, hi;
  final bool large;

  double get _margin => large ? 24.0 : 8.0;
  double get _top => large ? 30.0 : 14.0;

  double y(double bpm, Size size) => size.height - _margin - (bpm - lo) / (hi - lo) * (size.height - _margin - _top);
  double bpm(double y, Size size) => lo + (size.height - _margin - y) / (size.height - _margin - _top) * (hi - lo);
}

/// The tempo track: one step per segment between anchors (dashed where it is extrapolated), in
/// beats a minute as the time signature counts them (6/8: dotted crotchets).
///
/// [large]: a MIDI tempo map, filling the lanes: over the bars, each change marked with a dot
/// (larger when selected), on [scale] while it is held.
class _TempoPainter extends CustomPainter {
  _TempoPainter(this.c, this.colors, Listenable repaint, {this.large = false, this.scale})
      : super(repaint: repaint);
  final EditorController c;
  final AppColors colors;
  final bool large;
  final ValueListenable<_TempoScale?>? scale;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final sync = c.sync!;
    final v = c.viewport;
    if (large) {
      canvas.drawRect(Offset.zero & size, Paint()..color = colors.surface);
      final startX = v.x(sync.startSeconds);
      if (startX > 0) {
        canvas.drawRect(Rect.fromLTRB(0, 0, math.min(startX, size.width), size.height), Paint()..color = colors.grid.withValues(alpha: 0.6));
      }
      paintBarGrid(canvas, size, c, colors);
    } else {
      canvas.drawRect(Offset.zero & size, Paint()..color = colors.accentWash);
      canvas.drawLine(const Offset(0, 0.5), Offset(size.width, 0.5), Paint()..color = colors.line);
    }

    final segments = _tempoSteps(c, size.width);
    final fit = scale?.value ?? _TempoScale.fit(c, size.width, large: large);
    double y(double bpm) => fit.y(bpm, size);

    final line = Paint()
      ..color = colors.accentStrong
      ..strokeWidth = large ? 2 : 1.5;
    final faint = Paint()
      ..color = colors.accent.withValues(alpha: 0.5)
      ..strokeWidth = 1.2;
    Offset? previous;
    for (final (s0, s1, bpm, extrapolated) in segments) {
      final x0 = v.x(s0), x1 = v.x(s1);
      if (x1 < 0 || x0 > size.width) {
        previous = Offset(x1, y(bpm));
        continue;
      }
      final yy = y(bpm);
      if (previous != null && !extrapolated) canvas.drawLine(previous, Offset(x0, yy), faint);
      if (extrapolated) {
        for (var x = x0; x < x1; x += 8) {
          canvas.drawLine(Offset(x, yy), Offset(math.min(x + 4, x1), yy), faint);
        }
      } else {
        canvas.drawLine(Offset(x0, yy), Offset(x1, yy), line);
      }
      if (x1 - x0 > 34) {
        final tp = TextPainter(
          text: TextSpan(
            text: '${bpm.round()}',
            style: TextStyle(fontSize: large ? 11.5 : 10, color: extrapolated ? colors.textMuted : colors.text),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp
          ..paint(canvas, Offset(math.max(x0, 0) + 4, yy - tp.height - 1))
          ..dispose();
      }
      previous = Offset(x1, yy);
    }
    if (c.midiTempo case final midi? when large) _paintMidi(canvas, size, midi, y);
  }

  /// A MIDI tempo map's warps (a line, labelled where it jumps from and to) and its changes (a
  /// dot each, larger when selected).
  void _paintMidi(Canvas canvas, Size size, MidiTempoMap midi, double Function(double bpm) y) {
    final sync = c.sync!, v = c.viewport;
    var lastLabelEnd = double.negativeInfinity;
    for (final a in sync.anchors) {
      final x = v.x(a.seconds);
      if (!a.isWarp || x < -40 || x > size.width + 40) continue;
      canvas.drawRect(Rect.fromLTWH(x - 1, 0, 2, size.height), Paint()..color = colors.accent.withValues(alpha: 0.7));
      final tp = TextPainter(
        text: TextSpan(
          text: '${sync.beats.format(a.quarter, compact: true)}→${sync.beats.format(a.jumpTo!, compact: true)}',
          style: TextStyle(fontSize: 10.5, color: colors.text),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      if (x + 4 > lastLabelEnd + 3) {
        tp.paint(canvas, Offset(x + 4, 3));
        lastLabelEnd = x + 4 + tp.width;
      }
      tp.dispose();
    }
    final end = sync.anchors.last.seconds, placed = MidiInScore(midi, sync);
    for (final (i, t) in midi.tempos.indexed) {
      final seconds = sync.startSeconds + midi.secondsAt(t.quarter);
      if (seconds >= end) break;
      final x = v.x(seconds);
      if (x < -6 || x > size.width + 6) continue;
      final at = Offset(x, y(t.quartersPerMinute / placed.beatLength(t.quarter)));
      final selected = c.anchors.selectedTempo == i;
      if (selected) canvas.drawCircle(at, 6, Paint()..color = colors.surface);
      canvas.drawCircle(at, selected ? 4.5 : 3, Paint()..color = colors.accentStrong);
    }
  }

  @override
  bool shouldRepaint(_TempoPainter old) => true;
}
