import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'assets_dialog.dart';
import 'custom_bar.dart';
import 'edit_dialogs.dart';
import 'editor_controller.dart';
import 'key_bindings.dart';
import 'menu_kit.dart';
import 'plugins/plugins.dart';
import 'project_document.dart';
import 'toolbar_layout.dart';
import 'ui_kit.dart';
import 'video_export.dart';
import 'l10n/l10n.dart';

/// The one bar above the score: playback on the left, the score's own controls on the right,
/// as the app comes. Which items it has, and where, is the user's ([layout], View ▸ Customize
/// Toolbar…, a [CustomBar]): those it has no room for, and those kept there, are in the menu
/// at its end (»). The document's name is in the window's title bar; files are in the File menu.
class EditorToolbar extends StatelessWidget {
  const EditorToolbar({
    super.key,
    required this.controller,
    required this.document,
    required this.onExportVideo,
    required this.onExportWeb,
    required this.videoRatio,
    required this.onVideoRatio,
    this.onShowTabBar,
    this.readout,
    this.playerMap = false,
    this.onPlayerMap,
    this.onMidiView,
    this.layout,
    this.onLayout,
    this.customizing = false,
    this.onCustomize,
    this.commands,
    this.commandsChanged,
  });
  final EditorController controller;
  final ProjectDocument document;
  final VoidCallback onExportVideo, onExportWeb;

  /// The video's ratio, which the frame shows and the video is exported at.
  final VideoRatio videoRatio;
  final ValueChanged<VideoRatio> onVideoRatio;

  /// Shows the tab bar (View ▸ Show Tab Bar), Home and the other projects in it; null (no
  /// button) while it shows.
  final VoidCallback? onShowTabBar;

  /// Whether the player map shows in the score's place; [onPlayerMap] switches (null: no switch).
  final bool playerMap;
  final ValueChanged<bool>? onPlayerMap;

  /// Shows the score as engraved (false) or as its notes in rows (the MIDI view): a third
  /// button of the switch, where the score has one ([EditorController.hasMidiView]).
  final ValueChanged<bool>? onMidiView;

  /// The time readout, which ⌘G opens to type where to go.
  final GlobalKey<TimeReadoutState>? readout;

  /// Where its items are (null: as the app comes); [onLayout] changes that (an item's own
  /// menu, a drop while [customizing]); null: they stay.
  final ToolbarLayout? layout;
  final ValueChanged<ToolbarLayout>? onLayout;

  /// Whether the toolbar is being customized: its items do nothing and are dragged, to another
  /// place or off it. [onCustomize] starts that (null: no such item in its menu).
  final bool customizing;
  final VoidCallback? onCustomize;

  /// The app's commands by id as they can be chosen now (null: not now), for the items that do
  /// one ([BarItem.command]), and what says they changed. Without, those items are greyed out.
  final Map<String, VoidCallback?> Function()? commands;
  final Listenable? commandsChanged;

  /// A desktop toolbar's height, as the style has it.
  static double heightOf(BuildContext context) => AppStyle.of(context).toolbar;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return ListenableBuilder(
      listenable: commandsChanged ?? const AlwaysStoppedAnimation(0),
      builder: (context, _) => Select(
        listenable: c,
        select: () => (
          undo: c.canUndo,
          redo: c.canRedo,
          playing: c.playback.isPlaying,
          metronome: c.playback.metronome,
          images: c.images.enabled,
          reengraving: c.isReengraving,
          export: c.canExport,
          notes: c.hasNotes,
          tapping: c.anchors.tapArmed,
          staffSpace: c.staffSpace,
          midiView: (c.hasMidiView, c.showsMidiView),
          // What a macro's own button goes by ([macroAction]): where its steps would be done.
          macros: (c.tab, c.lanes.scripting, c.anchors.aligning != null, c.isLoadingAudio, c.curation != null),
        ),
        builder: (context, _) => _bar(context),
      ),
    );
  }

  Widget _bar(BuildContext context) {
    final colors = context.colors;
    return Container(
      height: EditorToolbar.heightOf(context),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: colors.chrome, border: Border(bottom: BorderSide(color: colors.line))),
      child: Row(children: [
        if (onShowTabBar case final onShowTabBar?) ...[
          ToolbarButton(
            icon: AppIcon.tabBar.of(context),
            tooltip: keyed(context, KeyCommand.showTabBar, (key) => 'Show tab bar ({key})'.fill({'key': key}), 'Show tab bar'.tr),
            onPressed: onShowTabBar,
          ),
          const ToolbarDivider(),
        ],
        Expanded(
          child: CustomBar(
            layout: layout ?? ToolbarLayout.standard(BarKind.editor),
            onLayout: onLayout,
            items: _EditorItems(this),
            customizing: customizing,
            onCustomize: onCustomize,
          ),
        ),
      ]),
    );
  }
}

/// The editor's toolbar's items: any toolbar's ([BarItems]) and its own controls.
class _EditorItems extends BarItems {
  _EditorItems(this.bar) : super(controller: bar.controller, commands: bar.commands);
  final EditorToolbar bar;

  /// The view's switch: the score (a MIDI project's rows), a score's MIDI view where it has one,
  /// the player map; each with whether it shows and what shows it. None without a switch.
  List<({String label, Widget glyph, bool selected, VoidCallback show, KeyCommand command})> _views(BuildContext context) {
    final c = controller, onPlayerMap = bar.onPlayerMap, onMidiView = bar.onMidiView;
    if (onPlayerMap == null) return const [];
    return [
      (
        label: c.isMidi ? 'MIDI View' : 'Score',
        glyph: Icon(AppIcon.score.of(context)),
        selected: !bar.playerMap && !c.showsMidiView,
        show: () {
          onMidiView?.call(false);
          onPlayerMap(false);
        },
        command: KeyCommand.showPlayerMap,
      ),
      if (onMidiView != null && c.hasMidiView)
        (
          label: 'MIDI View',
          glyph: const _MidiViewGlyph(),
          selected: !bar.playerMap && c.showsMidiView,
          show: () {
            onMidiView(true);
            onPlayerMap(false);
          },
          command: KeyCommand.showMidiView,
        ),
      (label: 'Player Map', glyph: const _PlayerMapGlyph(), selected: bar.playerMap, show: () => onPlayerMap(true), command: KeyCommand.showPlayerMap),
    ];
  }

  /// The buttons plugins put on the toolbar (app.command's `toolbar`).
  List<PluginEntry> _added(BuildContext context) => PluginScope.of(context)?.commandsWhere((command) => command.toolbar) ?? const [];

  @override
  Widget? item(BuildContext context, BarItem item, {bool first = false}) {
    final c = controller, colors = context.colors;
    switch (item) {
      case BarItem.readout:
        return Padding(padding: const EdgeInsets.only(left: 10, right: 2), child: TimeReadout(key: bar.readout, controller: c));
      case BarItem.viewSwitch:
        // The score, its notes in rows (where it has them beside its engraving) or the player
        // map in its place: one lit, as a segmented switch.
        final views = _views(context);
        if (views.isEmpty) return null;
        return Row(mainAxisSize: MainAxisSize.min, children: [
          for (final view in views)
            ToolbarButton(
              glyph: view.glyph,
              tooltip: switch (view.label) {
                'Score' => keyed(context, view.command, (key) => 'Score ({key})'.fill({'key': key}), 'Score'.tr),
                'Player Map' => keyed(context, view.command, (key) => 'Player map ({key})'.fill({'key': key}), 'Player Map'.tr),
                _ => keyed(context, view.command, (key) => 'MIDI view ({key})'.fill({'key': key}), 'MIDI View'.tr),
              },
              selected: view.selected,
              onPressed: view.show,
            ),
        ]);
      case BarItem.assets:
        if (!c.images.enabled) return null;
        return ToolbarButton(icon: AppIcon.assets.of(context), tooltip: 'Manage assets…'.tr, onPressed: () => showAssetsDialog(context, c));
      case BarItem.plugins:
        final plugins = PluginScope.of(context), added = _added(context);
        if (added.isEmpty) return null;
        return Row(mainAxisSize: MainAxisSize.min, children: [
          for (final entry in added)
            ToolbarButton(
              key: ValueKey('plugin ${entry.command.id}'),
              icon: Plugins.iconOf(context, entry),
              tooltip: plugins!.tipOf(entry, KeyMap.of(context)),
              selected: entry.runtime.isChecked(entry.command),
              onPressed: plugins.actionOf(entry),
            ),
        ]);
      case BarItem.export:
        return _ExportMenu(enabled: c.canExport, onVideo: bar.onExportVideo, onWeb: bar.onExportWeb);
      case BarItem.videoRatio:
        return RatioMenu(ratio: bar.videoRatio, onSelected: bar.onVideoRatio);
      case BarItem.scoreSize:
        return Row(mainAxisSize: MainAxisSize.min, children: [
          Tip(message: 'Score size'.tr, child: Icon(AppIcon.scoreSize.of(context), size: 16, color: colors.textMuted)),
          SizedBox(
            width: 132,
            // At the top of the window the value shows below the thumb, not above it.
            child: _sizeSlider(context),
          ),
        ]);
      case BarItem.space when first:
        // Saving… at its end. However narrow, its line is whole or cut, never squeezed.
        return ClipRect(
          child: OverflowBox(
            minWidth: 0,
            maxWidth: double.infinity,
            alignment: Alignment.centerRight,
            child: _SavingIndicator(document: bar.document),
          ),
        );
      default:
        return super.item(context, item, first: first);
    }
  }

  Widget _sizeSlider(BuildContext context) => OverlaySemantics(
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(valueIndicatorShape: const BelowValueIndicatorShape()),
          child: Slider(
            value: controller.staffSpace,
            min: EditorController.minStaffSpace,
            max: EditorController.maxStaffSpace,
            divisions: 14,
            label: controller.staffSpace.toStringAsFixed(1),
            onChanged: (v) => controller.setStaffSpace(v, dragging: true),
            onChangeEnd: controller.setStaffSpace,
          ),
        ),
      );

  @override
  List<PopupMenuEntry<VoidCallback>> entries(BuildContext context, BarItem item) {
    final c = controller;
    switch (item) {
      case BarItem.readout:
        return [MenuWidget(child: TimeReadout(controller: c))];
      case BarItem.viewSwitch:
        return [for (final view in _views(context)) row(context, item, view.show, selected: view.selected, icon: view.glyph, label: view.label.tr)];
      case BarItem.assets:
        return [if (c.images.enabled) row(context, item, () => showAssetsDialog(context, c))];
      case BarItem.plugins:
        final plugins = PluginScope.of(context);
        return [
          for (final entry in _added(context))
            row(context, item, plugins!.actionOf(entry),
                selected: entry.runtime.isChecked(entry.command), icon: Icon(Plugins.iconOf(context, entry)), label: plugins.titleOf(entry)),
        ];
      case BarItem.export:
        return [
          row(context, item, c.canExport ? bar.onExportVideo : null, icon: Icon(AppIcon.export.of(context)), label: 'Export Video…'.tr),
          row(context, item, c.canExport ? bar.onExportWeb : null, icon: Icon(AppIcon.website.of(context)), label: 'Export to Web…'.tr),
        ];
      case BarItem.videoRatio:
        return [
          menuHeader(context, 'Video ratio'),
          ...RatioMenu.entries(context, bar.videoRatio, (r) => () => RatioMenu.choose(context, bar.videoRatio, r, bar.onVideoRatio)),
        ];
      case BarItem.scoreSize:
        return [
          MenuWidget(
            child: Row(children: [
              Icon(AppIcon.scoreSize.of(context), size: 16, color: context.colors.textMuted),
              // Its value follows the drag: the menu isn't built again as the bar is.
              Expanded(child: ListenableBuilder(listenable: c, builder: (context, _) => _sizeSlider(context))),
            ]),
          ),
        ];
      default:
        return super.entries(context, item);
    }
  }
}

/// The video's ratio: "16:9 ▾", a preset or Custom… (any ratio, typed).
class RatioMenu extends StatelessWidget {
  const RatioMenu({super.key, required this.ratio, required this.onSelected});
  final VideoRatio ratio;
  final ValueChanged<VideoRatio> onSelected;

  /// Custom…'s value in the menu (a menu's null means it was dismissed).
  static const _custom = VideoRatio(0, 1);

  /// The menu's rows, the one that is [ratio] ticked: each preset and Custom…, its value what
  /// [valueOf] makes of the ratio (Custom…'s is one [choose] knows).
  static List<PopupMenuEntry<T>> entries<T>(BuildContext context, VideoRatio ratio, T Function(VideoRatio ratio) valueOf) {
    final custom = !VideoRatio.presets.contains(ratio);
    return [
      for (final r in VideoRatio.presets) checkedMenuItem(context, value: valueOf(r), checked: r == ratio, child: Text(r.label)),
      menuDivider(context),
      checkedMenuItem(context,
          value: valueOf(_custom), checked: custom, child: Text(custom ? 'Custom ({ratio})…'.fill({'ratio': ratio.label}) : 'Custom…'.tr)),
    ];
  }

  /// A row of [entries] chosen: [picked] is the ratio, or, Custom…'s, one typed first.
  static Future<void> choose(BuildContext context, VideoRatio ratio, VideoRatio picked, ValueChanged<VideoRatio> onSelected) async {
    if (picked != _custom) return onSelected(picked);
    final typed = await showVideoRatioDialog(context, ratio);
    if (typed != null) onSelected(typed);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return OverlaySemantics(
      child: AppPopupMenuButton<VideoRatio>(
        tooltip: 'Video ratio'.tr,
        position: PopupMenuPosition.under,
        style: toolbarMenuStyle(context),
        onSelected: (r) => choose(context, ratio, r, onSelected),
        itemBuilder: (context) => entries(context, ratio, (r) => r),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(ratio.label,
              style: TextStyle(
                  fontSize: 12.5, color: colors.text, fontFeatures: const [FontFeature.tabularFigures()])),
          Icon(AppIcon.dropDown.of(context), size: 18, color: colors.textMuted),
        ]),
      ),
    );
  }
}

/// Export: a video or a web page, chosen from its menu.
class _ExportMenu extends StatelessWidget {
  const _ExportMenu({required this.enabled, required this.onVideo, required this.onWeb});
  final bool enabled;
  final VoidCallback onVideo, onWeb;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final ink = enabled ? colors.text : colors.textMuted.withValues(alpha: 0.5);
    Widget item(String label, [String? key]) => Row(children: [
          Expanded(child: Text(label.tr)),
          if (key != null) ...[
            const SizedBox(width: 24),
            Text(shortcut(key), style: TextStyle(color: colors.textMuted)),
          ],
        ]);
    return OverlaySemantics(
      child: AppPopupMenuButton<VoidCallback>(
        tooltip: 'Export'.tr,
        enabled: enabled,
        position: PopupMenuPosition.under,
        style: toolbarMenuStyle(context),
        onSelected: (export) => export(),
        itemBuilder: (context) => [
          menuItem(context, value: onVideo, child: item('Export Video…', '⌘E')),
          menuItem(context, value: onWeb, child: item('Export to Web…')),
        ],
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(AppIcon.export.of(context), size: 16, color: ink),
          Icon(AppIcon.dropDown.of(context), size: 18, color: enabled ? colors.textMuted : ink),
        ]),
      ),
    );
  }
}

/// The player map's button: players on a bow, as the map seats them.
class _PlayerMapGlyph extends StatelessWidget {
  const _PlayerMapGlyph();

  @override
  Widget build(BuildContext context) {
    final icon = IconTheme.of(context);
    return CustomPaint(size: Size.square(icon.size ?? 18), painter: _PlayerMapGlyphPainter(icon.color ?? context.colors.text));
  }
}

class _PlayerMapGlyphPainter extends CustomPainter {
  const _PlayerMapGlyphPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    final dot = Paint()..color = color;
    // A front bow of five, two behind.
    for (final (x, y, r) in const [(4.0, 15.5, 1.9), (7.6, 10.4, 1.9), (12.0, 8.6, 1.9), (16.4, 10.4, 1.9), (20.0, 15.5, 1.9), (9.2, 4.2, 1.5), (14.8, 4.2, 1.5)]) {
      canvas.drawCircle(Offset(x, y), r, dot);
    }
    canvas.drawCircle(const Offset(12, 19.5), 1.3, dot..color = color.withValues(alpha: 0.6)); // the conductor
  }

  @override
  bool shouldRepaint(_PlayerMapGlyphPainter old) => old.color != color;
}

/// The MIDI view's: notes as bars of ink, each at its height.
class _MidiViewGlyph extends StatelessWidget {
  const _MidiViewGlyph();

  @override
  Widget build(BuildContext context) {
    final icon = IconTheme.of(context);
    return CustomPaint(size: Size.square(icon.size ?? 18), painter: _MidiViewGlyphPainter(icon.color ?? context.colors.text));
  }
}

class _MidiViewGlyphPainter extends CustomPainter {
  const _MidiViewGlyphPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    final bar = Paint()..color = color;
    for (final (x, y, w) in const [(3.0, 4.6, 8.0), (12.5, 8.2, 8.5), (5.5, 11.8, 5.5), (12.5, 15.4, 5.0), (3.0, 15.4, 7.5), (19.0, 11.8, 2.0)]) {
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, 2.6), const Radius.circular(1.1)), bar);
    }
  }

  @override
  bool shouldRepaint(_MidiViewGlyphPainter old) => old.color != color;
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
    // Built again only as what it says changes (a tenth of a second, a beat), not at every frame.
    return Select<(String, String, String)>(
      listenable: playback.time,
      select: () => (_clock(playback.time.value), _clock(playback.duration), _position(playback.time.value)),
      builder: (context, shown) => Row(mainAxisSize: MainAxisSize.min, children: [
        _Clickable(
          tip: keyed(context, KeyCommand.goTo, (key) => 'Go to time ({key})'.fill({'key': key}), 'Go to time'.tr),
          onTap: () => edit(time: true),
          child: Text.rich(TextSpan(children: [
            TextSpan(text: shown.$1, style: mono.copyWith(fontWeight: FontWeight.w500)),
            TextSpan(text: '  /  ${shown.$2}', style: mono.copyWith(color: colors.textMuted)),
          ])),
        ),
        const SizedBox(width: 10),
        _Clickable(
          tip: keyed(context, KeyCommand.goTo, (key) => 'Go to bar ({key})'.fill({'key': key}), 'Go to bar'.tr),
          onTap: edit,
          child: Container(
            height: 24,
            constraints: const BoxConstraints(minWidth: 52),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: fieldFill(context) ?? colors.accentWash,
                borderRadius: AppStyle.of(context).radius(6),
                border: AppStyle.of(context).isCarbon
                    ? Border(bottom: BorderSide(color: CarbonColors.maybeOf(context)!.borderStrong))
                    : Border.all(color: colors.line)),
            child: Text(shown.$3, style: mono.copyWith(fontSize: 12, fontWeight: FontWeight.w500, color: colors.text)),
          ),
        ),
      ]),
    );
  }

  Widget _input(AppColors colors, TextStyle mono) {
    final borders = fieldBorders(context, bad: _wrong, radius: 6);
    final fill = fieldFill(context);
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
            hintText: 'Bar or m:ss'.tr,
            hintStyle: mono.copyWith(fontSize: 12.5, color: colors.textMuted),
            filled: fill != null,
            fillColor: fill,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            enabledBorder: borders.rest,
            focusedBorder: borders.focused,
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

/// A quiet "Saving…" while a save (or autosave) runs, once it has run a moment: a quick
/// autosave shows nothing, rather than a flicker.
class _SavingIndicator extends StatefulWidget {
  const _SavingIndicator({required this.document});
  final ProjectDocument document;

  @override
  State<_SavingIndicator> createState() => _SavingIndicatorState();
}

class _SavingIndicatorState extends State<_SavingIndicator> {
  static const _after = Duration(milliseconds: 400);
  Timer? _timer;
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    widget.document.addListener(_changed);
    _changed();
  }

  @override
  void dispose() {
    widget.document.removeListener(_changed);
    _timer?.cancel();
    super.dispose();
  }

  void _changed() {
    if (widget.document.isSaving) {
      _timer ??= Timer(_after, () {
        if (mounted) setState(() => _shown = true);
      });
    } else {
      _timer?.cancel();
      _timer = null;
      if (_shown) setState(() => _shown = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return FadeSlideSwitcher(
      alignment: Alignment.centerRight,
      offset: const Offset(0, 0.3),
      child: !_shown
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox.square(dimension: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: colors.textMuted)),
                const SizedBox(width: 6),
                Text('Saving…'.tr, style: TextStyle(fontSize: 12, color: colors.textMuted)),
              ]),
            ),
    );
  }
}
