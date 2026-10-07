import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'editor_controller.dart';
import 'edit_dialogs.dart';
import 'error_text.dart';
import 'lanes_common.dart';
import 'media_converter.dart';
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
/// drawn large. Clicking it moves the playhead.
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

  Duration _lastDown = Duration.zero;
  Offset _lastDownAt = Offset.zero;
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
    final doubleClick = e.timeStamp - _lastDown < const Duration(milliseconds: 350) &&
        (e.localPosition - _lastDownAt).distance < 6;
    _lastDown = e.timeStamp;
    _lastDownAt = e.localPosition;

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
      final delta = _snapToOnset(seconds - (_lastDownSeconds - from[grabbed].seconds)) - from[grabbed].seconds;
      c.anchors.drag(delta, from: from);
    } else if (_marquee.value != null) {
      _marquee.value = (_marquee.value!.$1, seconds);
      c.anchors.selectBetween(_marquee.value!.$1, seconds, keep: _marqueeKeep);
    } else if (_scrubbing) {
      c.playback.scrub(seconds);
    }
  }

  /// Where the pointer was (in seconds) when the current drag began.
  double get _lastDownSeconds => c.viewport.seconds(_lastDownAt.dx);

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

  /// The MIDI tempo map in place of the anchors, the waveform and the tempo lane.
  Widget _midiLanes(BuildContext context, MidiTempoMap midi) {
    final colors = context.colors;
    final repaint = Listenable.merge([c.viewport, sync, c]);
    void seek(PointerEvent e) => c.playback.scrub(c.viewport.seconds(e.localPosition.dx));
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        width: kLaneHeaderWidth,
        child: LaneLabel(
          height: double.infinity,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Tip(message: 'Beats per minute', child: Text('MIDI tempo')),
              Text(midi.name, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: colors.textMuted)),
              if (c.track case final track?)
                Text('♪ ${track.name}', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: colors.textMuted)),
            ],
          ),
        ),
      ),
      Expanded(
        child: Listener(
          onPointerDown: (e) => e.buttons == kPrimaryButton ? seek(e) : null,
          onPointerMove: (e) => e.buttons == kPrimaryButton ? seek(e) : null,
          onPointerUp: (_) => c.playback.endScrub(),
          onPointerCancel: (_) => c.playback.endScrub(),
          child: WithPlayhead(
            controller: c,
            child: CustomPaint(size: Size.infinite, painter: _TempoPainter(c, colors, repaint, large: true)),
          ),
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) => Select(
        listenable: c,
        select: () => (sync: c.sync, midi: c.midiTempo, track: c.track, loading: c.isLoadingAudio),
        builder: (context, _) => _lanes(context),
      );

  Widget _lanes(BuildContext context) {
    if (c.midiTempo case final midi?) return _midiLanes(context, midi);
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
                        : 'Load a recording (or drop it here) to see its waveform. You can also tap along without one, '
                            'or drop a MIDI file to follow its tempo map.',
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

/// Opens anchor [index]'s position and jump to edit ([warp]: starting with the jump).
Future<void> _editAnchor(BuildContext context, EditorController c, int index, {bool warp = false}) async {
  final sync = c.sync!;
  final a = sync.anchors[index];
  final set = await showAnchorDialog(context, beats: sync.beats, quarter: a.quarter, jumpTo: a.jumpTo, warp: warp);
  if (set == null || !context.mounted || index >= sync.anchors.length) return;
  if (!c.anchors.setAnchor(index, set.quarter, jumpTo: set.jumpTo)) {
    _refused(context, set.jumpTo == a.jumpTo ? '${sync.beats.format(set.quarter)} would cross a neighbouring anchor.' : null);
  }
}

void _refused(BuildContext context, String? why) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(why ?? 'That would put anchors out of order, or the ones after the jump past the end of the score.')));

/// Warp (W): makes the selected anchor jump (back for a repeat, on to a coda), or adds a
/// warp at the playhead, on the bar (or beat) sounding there.
Future<void> editWarp(BuildContext context, EditorController c) async {
  final sync = c.sync;
  if (sync == null || c.usesMidiTempo) return;
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
          icon: c.track == null ? Icons.audio_file_outlined : Icons.change_circle_outlined,
          tooltip: c.track == null
              ? 'Load recording… (or drop it here)'
              : 'Replace recording…\n${c.track!.name}',
          onPressed: c.isLoadingAudio ? null : () => pickAudio(context, c),
        ),
        ToolbarButton(
          icon: Icons.piano_outlined,
          tooltip: c.midiTempo == null ? 'Tempo from MIDI… (or drop it here)' : 'Stop following ${c.midiTempo!.name}',
          selected: c.usesMidiTempo,
          onPressed: () => c.usesMidiTempo ? c.useMidiTempo(null) : pickMidi(context, c),
        ),
        if (!c.usesMidiTempo) ...[
          _TapButton(controller: c),
          ToolbarButton(
            icon: Icons.u_turn_left_rounded,
            tooltip: c.anchors.selected.length == 1
                ? 'Warp (W)\nMake this anchor jump to another bar'
                : 'Warp (W)\nJump to another bar here',
            onPressed: () => editWarp(context, c),
          ),
          const ToolbarDivider(),
          Tip(
            message: 'Step for taps, ${shortcut('⌥-click')} and ↑/↓',
            child: ToolGroup(children: [
              for (final (grid, label) in const [(SyncGrid.bar, 'Bar'), (SyncGrid.beat, 'Beat')])
                _TextToggle(label: label, selected: c.anchors.grid == grid, onPressed: () => c.anchors.grid = grid),
            ]),
          ),
          const SizedBox(width: 2),
          ToolbarButton(
            icon: Icons.align_horizontal_center_rounded,
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
            icon: Icons.clear_all_rounded,
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
      child: PopupMenuButton<double>(
        tooltip: 'Playback speed',
        position: PopupMenuPosition.under,
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.only(left: 6, right: 2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onSelected: (s) => controller.playback.speed = s,
        itemBuilder: (context) => [
          for (final s in const [0.5, 0.75, 1.0]) CheckedPopupMenuItem(value: s, checked: s == speed, child: Text(_label(s))),
        ],
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.speed_rounded, size: 16, color: colors.textMuted),
          const SizedBox(width: 5),
          Text(_label(speed),
              style: TextStyle(fontSize: 12.5, color: colors.text, fontFeatures: const [FontFeature.tabularFigures()])),
          Icon(Icons.arrow_drop_down_rounded, size: 18, color: colors.textMuted),
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
        duration: stateDuration(const Duration(milliseconds: 200)),
        curve: Curves.easeOut,
        height: 32,
        padding: EdgeInsets.symmetric(horizontal: c.anchors.tapArmed ? 8 : 0),
        decoration: BoxDecoration(
          color: c.anchors.tapArmed ? colors.recordingWash : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => c.anchors.tapArmed = !c.anchors.tapArmed,
          child: SizedBox(
            height: 32,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (c.anchors.tapArmed) ...[
                PulsingDot(color: colors.recording, size: 9),
                const SizedBox(width: 4),
                Text('Space', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: colors.recording)),
              ] else
                SizedBox.square(dimension: 32, child: Icon(Icons.touch_app_outlined, size: 18, color: colors.text)),
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
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onPressed,
      child: AnimatedContainer(
        duration: stateDuration(const Duration(milliseconds: 150)),
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: selected ? colors.accentSoft : Colors.transparent, borderRadius: BorderRadius.circular(8)),
        child: Text(label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              color: selected ? colors.accentStrong : colors.textMuted,
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load the recording: ${describeError(e)}')));
    }
  }
}

Future<void> pickMidi(BuildContext context, EditorController c) async {
  final file = await openFile(acceptedTypeGroups: [midiTypes]);
  if (file == null) return;
  try {
    await c.loadMidiTempo(file.path);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not use the MIDI file: ${describeError(e)}')));
    }
  }
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
        Icon(Icons.start_rounded, size: 17, color: context.colors.textMuted),
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
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(color: context.colors.line),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
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

/// The tempo track: one step per segment between anchors (dashed where it is extrapolated), in
/// beats a minute as the time signature counts them (6/8: dotted crotchets).
///
/// [large]: a MIDI tempo map, filling the lanes: over the bars, each change marked with a dot.
class _TempoPainter extends CustomPainter {
  _TempoPainter(this.c, this.colors, Listenable repaint, {this.large = false}) : super(repaint: repaint);
  final EditorController c;
  final AppColors colors;
  final bool large;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final sync = c.sync!;
    final v = c.viewport;
    final anchors = sync.anchors;
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

    final segments = <(double, double, double, bool)>[]; // start s, end s, beats a minute, extrapolated
    final end = math.max(c.playback.duration, v.seconds(size.width));
    // Quarter notes a minute → the meter's beats a minute, at the beat where [seconds] falls.
    double bpm(double quartersPerMinute, double seconds) {
      final q = sync.quarterAtSeconds(seconds).clamp(0.0, sync.totalQuarters);
      final beat = sync.beats.beatAt(q.toDouble());
      final length = beat.end - beat.start;
      return length > 1e-9 ? quartersPerMinute / length : quartersPerMinute;
    }

    void add(double s0, double s1, double quartersPerMinute, bool extrapolated) =>
        segments.add((s0, s1, bpm(quartersPerMinute, math.max(s0, 0)), extrapolated));
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
    final bpms = [for (final s in segments) s.$3];
    var lo = bpms.reduce(math.min), hi = bpms.reduce(math.max);
    if (hi - lo < 20) {
      final m = (hi + lo) / 2;
      lo = m - 10;
      hi = m + 10;
    }
    final margin = large ? 24.0 : 8.0, top = large ? 30.0 : 14.0;
    double y(double bpm) => size.height - margin - (bpm - lo) / (hi - lo) * (size.height - margin - top);

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
      if (large && !extrapolated && x0 >= -4) canvas.drawCircle(Offset(x0, yy), 3, Paint()..color = colors.accentStrong);
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
  }

  @override
  bool shouldRepaint(_TempoPainter old) => true;
}
