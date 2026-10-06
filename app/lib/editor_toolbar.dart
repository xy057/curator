import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'assets_dialog.dart';
import 'edit_dialogs.dart';
import 'editor_controller.dart';
import 'project_document.dart';
import 'ui_kit.dart';
import 'video_export.dart';

/// The one bar above the score: playback on the left, the score's own controls on the right.
/// The document's name is in the window's title bar; files are in the File menu.
class EditorToolbar extends StatelessWidget {
  const EditorToolbar({
    super.key,
    required this.controller,
    required this.document,
    required this.onEditTexts,
    required this.onExportVideo,
    required this.videoFrame,
    required this.onVideoFrame,
    required this.videoRatio,
    required this.onVideoRatio,
    required this.onClose,
    this.readout,
  });
  final EditorController controller;
  final ProjectDocument document;
  final VoidCallback onEditTexts;
  final VoidCallback onExportVideo;

  /// Whether the score shows the video's frame rather than filling the window.
  final bool videoFrame;
  final ValueChanged<bool> onVideoFrame;

  /// The video's ratio, which the frame shows and the video is exported at.
  final VideoRatio videoRatio;
  final ValueChanged<VideoRatio> onVideoRatio;
  final VoidCallback onClose;

  /// The time readout, which ⌘G opens to type where to go.
  final GlobalKey<TimeReadoutState>? readout;

  static const height = 46.0;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final colors = context.colors;
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: colors.surface, border: Border(bottom: BorderSide(color: colors.line))),
      child: Row(children: [
        ToolbarButton(
          icon: Icons.home_outlined,
          tooltip: 'Close project (${shortcut('⌘W')})',
          onPressed: onClose,
        ),
        const ToolbarDivider(),
        ToolbarButton(
          icon: Icons.skip_previous_rounded,
          tooltip: 'To start (Home)',
          onPressed: () => c.playback.seek(0),
        ),
        const SizedBox(width: 2),
        _PlayButton(controller: c),
        const SizedBox(width: 12),
        TimeReadout(key: readout, controller: c),
        const Spacer(),
        _SavingIndicator(document: document),
        ToolbarButton(
          icon: Icons.undo_rounded,
          tooltip: 'Undo (${shortcut('⌘Z')})',
          onPressed: c.canUndo ? c.undo : null,
        ),
        ToolbarButton(
          icon: Icons.redo_rounded,
          tooltip: 'Redo (${shortcut('⇧⌘Z', 'Ctrl+Y')})',
          onPressed: c.canRedo ? c.redo : null,
        ),
        const ToolbarDivider(),
        ToolbarButton(
          icon: Icons.edit_note_rounded,
          tooltip: 'Score texts…',
          onPressed: c.isReengraving ? null : onEditTexts,
        ),
        if (c.images.enabled)
          ToolbarButton(
            icon: Icons.photo_library_outlined,
            tooltip: 'Manage assets…',
            onPressed: () => showAssetsDialog(context, c),
          ),
        ToolbarButton(
          icon: Icons.movie_outlined,
          tooltip: 'Export video… (${shortcut('⌘E')})',
          onPressed: c.isReengraving ? null : onExportVideo,
        ),
        ToolbarButton(
          icon: Icons.crop_16_9_rounded,
          tooltip: videoFrame ? 'Fill the window' : "Show the video's frame",
          selected: videoFrame,
          onPressed: () => onVideoFrame(!videoFrame),
        ),
        RatioMenu(ratio: videoRatio, onSelected: onVideoRatio),
        const ToolbarDivider(),
        Tip(
          message: 'Score size',
          child: Icon(Icons.format_size_rounded, size: 16, color: colors.textMuted),
        ),
        SizedBox(
          width: 132,
          // At the top of the window the value shows below the thumb, not above it.
          child: OverlaySemantics(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(valueIndicatorShape: const BelowValueIndicatorShape()),
              child: Slider(
                value: c.staffSpace,
                min: EditorController.minStaffSpace,
                max: EditorController.maxStaffSpace,
                divisions: 14,
                label: c.staffSpace.toStringAsFixed(1),
                onChanged: (v) => c.setStaffSpace(v, dragging: true),
                onChangeEnd: c.setStaffSpace,
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// The video's ratio: "16:9 ▾", a preset or Custom… (any ratio, typed).
class RatioMenu extends StatelessWidget {
  const RatioMenu({super.key, required this.ratio, required this.onSelected});
  final VideoRatio ratio;
  final ValueChanged<VideoRatio> onSelected;

  /// Custom…'s value in the menu (a menu's null means it was dismissed).
  static const _custom = VideoRatio(0, 1);

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final custom = !VideoRatio.presets.contains(ratio);
    return OverlaySemantics(
      child: PopupMenuButton<VideoRatio>(
        tooltip: 'Video ratio',
        position: PopupMenuPosition.under,
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.only(left: 8, right: 2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onSelected: (r) async {
          if (r != _custom) return onSelected(r);
          final typed = await showVideoRatioDialog(context, ratio);
          if (typed != null) onSelected(typed);
        },
        itemBuilder: (context) => [
          for (final r in VideoRatio.presets)
            CheckedPopupMenuItem(value: r, checked: r == ratio, child: Text(r.label)),
          const PopupMenuDivider(),
          CheckedPopupMenuItem(
              value: _custom, checked: custom, child: Text(custom ? 'Custom (${ratio.label})…' : 'Custom…')),
        ],
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(ratio.label,
              style: TextStyle(
                  fontSize: 12.5, color: colors.text, fontFeatures: const [FontFeature.tabularFigures()])),
          Icon(Icons.arrow_drop_down_rounded, size: 18, color: colors.textMuted),
        ]),
      ),
    );
  }
}

/// Play / pause: the icon morphs between the two.
class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.controller});
  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final playing = controller.playback.isPlaying;
    return Tip(
      message: playing ? 'Pause (Space)' : 'Play (Space)',
      child: Material(
        color: colors.accent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: controller.playback.togglePlay,
          child: SizedBox.square(
            dimension: 32,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 160),
              transitionBuilder: (child, animation) => ScaleTransition(
                scale: Tween(begin: 0.6, end: 1.0).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutBack)),
                child: FadeTransition(opacity: animation, child: child),
              ),
              child: Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                key: ValueKey(playing),
                size: 20,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "1:10.0 / 1:31.4" and the bar.beat sounding now. A click on either (or ⌘G: [edit]) types
/// where to go instead: a bar or a time ([Playback.goTo]).
class TimeReadout extends StatefulWidget {
  const TimeReadout({super.key, required this.controller});
  final EditorController controller;

  @override
  State<TimeReadout> createState() => TimeReadoutState();
}

class TimeReadoutState extends State<TimeReadout> {
  final _field = TextEditingController();
  final _focus = FocusNode();
  bool _editing = false;
  bool _wrong = false;

  /// What had the keyboard before the field: it gets it back, so the window's shortcuts
  /// (Space, ⌘G…) work again.
  FocusNode? _before;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _close();
    });
  }

  @override
  void dispose() {
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  static String _clock(double seconds) {
    final s = seconds.clamp(0, 359999);
    final tenths = ((s * 10).floor() % 10);
    return '${s ~/ 60}:${(s.floor() % 60).toString().padLeft(2, '0')}.$tenths';
  }

  /// The beat sounding now, counted the way the time signature beats (6/8: two dotted crotchets).
  String _position(double time) {
    final c = widget.controller;
    if (c.score == null) return '1.1';
    final q = c.timeline.quarterAtSeconds(time).clamp(0.0, c.timeline.measureStarts.last);
    return c.beats.format(c.beats.beatAt(q.toDouble()).start);
  }

  /// Opens the field, holding the bar.beat sounding now (or the [time]), all selected.
  void edit({bool time = false}) {
    if (widget.controller.score == null) return;
    final now = widget.controller.playback.time.value;
    if (!_editing) _before = FocusManager.instance.primaryFocus;
    _field.text = time ? _clock(now) : _position(now);
    _field.selection = TextSelection(baseOffset: 0, extentOffset: _field.text.length);
    setState(() {
      _editing = true;
      _wrong = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  void _submit() {
    if (!widget.controller.playback.goTo(_field.text)) {
      setState(() => _wrong = true);
      _focus.requestFocus();
      return;
    }
    _leave();
  }

  void _leave() {
    final before = _before;
    if (before != null && before.context != null && before.canRequestFocus) {
      before.requestFocus();
    } else {
      _focus.unfocus();
    }
  }

  void _close() {
    _before = null;
    if (_editing && mounted) setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final mono = TextStyle(fontFeatures: const [FontFeature.tabularFigures()], fontSize: 13, color: colors.text);
    if (_editing) return _input(colors, mono);
    final playback = widget.controller.playback;
    return ValueListenableBuilder<double>(
      valueListenable: playback.time,
      builder: (context, time, _) => Row(mainAxisSize: MainAxisSize.min, children: [
        _Clickable(
          tip: 'Go to time (${shortcut('⌘G')})',
          onTap: () => edit(time: true),
          child: Text.rich(TextSpan(children: [
            TextSpan(text: _clock(time), style: mono.copyWith(fontWeight: FontWeight.w500)),
            TextSpan(text: '  /  ${_clock(playback.duration)}', style: mono.copyWith(color: colors.textMuted)),
          ])),
        ),
        const SizedBox(width: 10),
        _Clickable(
          tip: 'Go to bar (${shortcut('⌘G')})',
          onTap: edit,
          child: Container(
            height: 24,
            constraints: const BoxConstraints(minWidth: 52),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            alignment: Alignment.center,
            decoration: BoxDecoration(color: colors.accentWash, borderRadius: BorderRadius.circular(6), border: Border.all(color: colors.line)),
            child: Text(_position(time), style: mono.copyWith(fontSize: 12, fontWeight: FontWeight.w500, color: colors.text)),
          ),
        ),
      ]),
    );
  }

  Widget _input(AppColors colors, TextStyle mono) {
    OutlineInputBorder border(Color color) =>
        OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: color));
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _leave},
      child: SizedBox(
        width: 160,
        height: 26,
        child: TextField(
          controller: _field,
          focusNode: _focus,
          style: mono.copyWith(fontSize: 12.5, fontWeight: FontWeight.w500),
          onChanged: (_) {
            if (_wrong) setState(() => _wrong = false);
          },
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Bar or m:ss',
            hintStyle: mono.copyWith(fontSize: 12.5, color: colors.textMuted),
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            enabledBorder: border(_wrong ? Theme.of(context).colorScheme.error : colors.line),
            focusedBorder: border(_wrong ? Theme.of(context).colorScheme.error : colors.accent),
          ),
        ),
      ),
    );
  }
}

/// A readout that types where to go when clicked.
class _Clickable extends StatelessWidget {
  const _Clickable({required this.tip, required this.onTap, required this.child});
  final String tip;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Tip(
        message: tip,
        child: MouseRegion(
          cursor: SystemMouseCursors.text,
          child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: child),
        ),
      );
}

/// A quiet "Saving…" while a save (or autosave) runs.
class _SavingIndicator extends StatelessWidget {
  const _SavingIndicator({required this.document});
  final ProjectDocument document;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return FadeSlideSwitcher(
      alignment: Alignment.centerRight,
      offset: const Offset(0, 0.3),
      child: !document.isSaving
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox.square(dimension: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: colors.textMuted)),
                const SizedBox(width: 6),
                Text('Saving…', style: TextStyle(fontSize: 12, color: colors.textMuted)),
              ]),
            ),
    );
  }
}
