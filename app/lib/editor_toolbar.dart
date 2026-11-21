import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'assets_dialog.dart';
import 'edit_dialogs.dart';
import 'editor_controller.dart';
import 'key_bindings.dart';
import 'menu_kit.dart';
import 'phrase_search_window.dart';
import 'plugins/plugins.dart';
import 'project_document.dart';
import 'toolbar_layout.dart';
import 'toolbar_strip.dart';
import 'ui_kit.dart';
import 'video_export.dart';
import 'l10n/l10n.dart';

/// The one bar above the score: playback on the left, the score's own controls on the right,
/// as the app comes. Which items it has, and where, is the user's ([layout], View ▸ Customize
/// Toolbar…): those it has no room for, and those kept there, are in the menu at its end (»).
/// The document's name is in the window's title bar; files are in the File menu.
class EditorToolbar extends StatefulWidget {
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
    this.layout = ToolbarLayout.standard,
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

  /// Where its items are; [onLayout] changes that (an item's own menu, a drop while
  /// [customizing]); null: they stay.
  final ToolbarLayout layout;
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
  State<EditorToolbar> createState() => _EditorToolbarState();
}

class _EditorToolbarState extends State<EditorToolbar> {
  final _strip = GlobalKey();

  /// How many of the bar's items it has room for ([ToolbarStrip.onFit]): the rest are in its menu.
  int _fit = BarItem.values.length * 4;

  /// While an item is dragged over the bar: the place it would go.
  int? _insertAt;

  EditorController get _c => widget.controller;
  RenderToolbarStrip get _box => _strip.currentContext!.findRenderObject()! as RenderToolbarStrip;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.commandsChanged ?? const AlwaysStoppedAnimation(0),
        builder: (context, _) => Select(
          listenable: _c,
          select: () => (
            undo: _c.canUndo,
            redo: _c.canRedo,
            playing: _c.playback.isPlaying,
            metronome: _c.playback.metronome,
            images: _c.images.enabled,
            reengraving: _c.isReengraving,
            export: _c.canExport,
            notes: _c.hasNotes,
            tapping: _c.anchors.tapArmed,
            staffSpace: _c.staffSpace,
            midiView: (_c.hasMidiView, _c.showsMidiView),
          ),
          builder: (context, _) => _bar(context),
        ),
      );

  Widget _bar(BuildContext context) {
    final colors = context.colors;
    final layout = widget.layout, bar = layout.bar, customizing = widget.customizing;
    final fit = math.min(_fit, bar.length);
    // One of a kind keeps its state wherever it is put; a space or a divider is the nth.
    final nth = <BarItem, int>{};
    final firstSpace = bar.indexOf(BarItem.space);
    final strip = ToolbarStrip(
      key: _strip,
      showMore: layout.menu.isNotEmpty,
      insertAt: _insertAt,
      markColor: colors.accent,
      onFit: (fit) {
        if (mounted) setState(() => _fit = fit);
      },
      items: [
        for (final (i, item) in bar.indexed)
          StripItem(
            key: ValueKey('${item.name} ${nth[item] = (nth[item] ?? 0) + 1}'),
            space: item != BarItem.space ? null : customizing ? 28 : 0,
            rule: item == BarItem.divider,
            // One the bar has no room for is laid out still: not reached by Tab meanwhile.
            child: ExcludeFocus(
              excluding: i >= fit || customizing,
              child: customizing ? _dragged(context, i, item) : _item(context, item, saving: i == firstSpace),
            ),
          ),
      ],
      more: customizing
          ? IgnorePointer(child: Opacity(opacity: 0.4, child: ToolbarButton(icon: AppIcon.overflow.of(context), tooltip: 'More tools'.tr, onPressed: () {})))
          : _MoreMenu(entries: (context) => _tidied([
                for (final item in bar.skip(fit)) ..._entries(context, item),
                if (fit < bar.length && layout.menu.isNotEmpty) menuDivider(context),
                for (final item in layout.menu) ..._entries(context, item),
              ])),
    );
    return Container(
      height: EditorToolbar.heightOf(context),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: colors.chrome, border: Border(bottom: BorderSide(color: colors.line))),
      child: Row(children: [
        if (widget.onShowTabBar case final onShowTabBar?) ...[
          ToolbarButton(
            icon: AppIcon.tabBar.of(context),
            tooltip: keyed(context, KeyCommand.showTabBar, (key) => 'Show tab bar ({key})'.fill({'key': key}), 'Show tab bar'.tr),
            onPressed: onShowTabBar,
          ),
          const ToolbarDivider(),
        ],
        Expanded(
          child: customizing
              ? DragTarget<BarDrag>(
                  onMove: (details) => _over(_box.placeAt(_box.globalToLocal(details.offset).dx)),
                  onLeave: (_) => _over(null),
                  onAcceptWithDetails: (details) {
                    final at = _box.placeAt(_box.globalToLocal(details.offset).dx);
                    _over(null);
                    widget.onLayout?.call(layout.moved(details.data.item, from: details.data.from, to: (area: BarArea.bar, index: at)));
                  },
                  builder: (context, _, _) => strip,
                )
              // A right click on an item: its own menu; on the bar: Customize Toolbar….
              : GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onSecondaryTapUp: widget.onCustomize == null ? null : (details) => _itemMenu(context, details.globalPosition),
                  child: strip,
                ),
        ),
      ]),
    );
  }

  void _over(int? place) {
    if (place != _insertAt) setState(() => _insertAt = place);
  }

  /// The menu of the item under a right click (none: the bar's): to the menu at the bar's end,
  /// off the toolbar, or Customize Toolbar….
  Future<void> _itemMenu(BuildContext context, Offset at) async {
    final layout = widget.layout;
    // (Room between items is the bar itself: nothing there to see, so nothing to move.)
    final i = switch (_box.itemAt(_box.globalToLocal(at))) { final i? when layout.bar[i] != BarItem.space => i, _ => null };
    final item = i == null ? null : layout.bar[i];
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromRect(at & Size.zero, Offset.zero & overlay.size),
      popUpAnimationStyle: AnimationStyle(duration: AppStyle.of(context).menuOpen, reverseDuration: AppStyle.of(context).menuClose),
      items: [
        if (item != null && widget.onLayout != null) ...[
          menuItem(
            context,
            value: () => widget.onLayout!(layout.moved(item, from: (area: BarArea.bar, index: i!), to: (area: BarArea.menu, index: layout.menu.length))),
            child: Text('Move to Overflow Menu'.tr),
          ),
          menuItem(
            context,
            value: () => widget.onLayout!(layout.moved(item, from: (area: BarArea.bar, index: i!))),
            child: Text('Remove from Toolbar'.tr),
          ),
          menuDivider(context),
        ],
        menuItem(context, value: widget.onCustomize, child: Text('Customize Toolbar…'.tr)),
      ],
    );
    action?.call();
  }

  // MARK: Items on the bar

  /// What choosing the app's command [id] does now, as plugins have it; null while it can't be.
  VoidCallback? _does(BuildContext context, String id) {
    final action = widget.commands?.call()[id];
    return action == null ? null : () => Plugins.doOwn(context, id, action);
  }

  VoidCallback get _goToStart => () => Plugins.doOwn(context, 'goToStart', () => _c.playback.seek(0));
  VoidCallback get _goToEnd => () => Plugins.doOwn(context, 'goToEnd', () => _c.playback.seek(_c.playback.duration));
  VoidCallback get _playPause => () => Plugins.doOwn(context, 'playPause', _c.playback.togglePlay);
  VoidCallback get _metronome => () => Plugins.doOwn(context, 'metronome', () => _c.playback.metronome = !_c.playback.metronome);
  VoidCallback? get _undo => _c.canUndo ? () => Plugins.doOwn(context, 'undo', _c.undo) : null;
  VoidCallback? get _redo => _c.canRedo ? () => Plugins.doOwn(context, 'redo', _c.redo) : null;
  VoidCallback? get _findPhrase =>
      !_c.hasNotes ? null : () => Plugins.doOwn(context, 'findPhrase', () => PhraseSearchWindow.toggle(Overlay.of(context), _c));
  VoidCallback get _assets => () => showAssetsDialog(context, _c);

  /// The view's switch: the score (a MIDI project's rows), a score's MIDI view where it has one,
  /// the player map; each with whether it shows and what shows it. None without a switch.
  List<({String label, Widget glyph, bool selected, VoidCallback show, KeyCommand command})> get _views {
    final onPlayerMap = widget.onPlayerMap, onMidiView = widget.onMidiView;
    if (onPlayerMap == null) return const [];
    return [
      (
        label: _c.isMidi ? 'MIDI View' : 'Score',
        glyph: Icon(AppIcon.score.of(context)),
        selected: !widget.playerMap && !_c.showsMidiView,
        show: () {
          onMidiView?.call(false);
          onPlayerMap(false);
        },
        command: KeyCommand.showPlayerMap,
      ),
      if (onMidiView != null && _c.hasMidiView)
        (
          label: 'MIDI View',
          glyph: const _MidiViewGlyph(),
          selected: !widget.playerMap && _c.showsMidiView,
          show: () {
            onMidiView(true);
            onPlayerMap(false);
          },
          command: KeyCommand.showMidiView,
        ),
      (label: 'Player Map', glyph: const _PlayerMapGlyph(), selected: widget.playerMap, show: () => onPlayerMap(true), command: KeyCommand.showPlayerMap),
    ];
  }

  /// The buttons plugins put on the toolbar (app.command's `toolbar`).
  List<PluginEntry> get _added => PluginScope.of(context)?.commandsWhere((command) => command.toolbar) ?? const [];

  /// [item] as it is on the bar; with [saving], a space that says Saving… at its end.
  Widget _item(BuildContext context, BarItem item, {bool saving = false}) {
    final c = _c, colors = context.colors;
    switch (item) {
      case BarItem.goToStart:
        return ToolbarButton(
          icon: AppIcon.toStart.of(context),
          tooltip: keyed(context, KeyCommand.goToStart, (key) => 'Go to start ({key})'.fill({'key': key}), 'Go to start'.tr),
          // As its key does it: what a plugin put around the command is what the button does.
          onPressed: _goToStart,
        );
      case BarItem.playPause:
        return _PlayButton(controller: c);
      case BarItem.goToEnd:
        return ToolbarButton(
          icon: AppIcon.toEnd.of(context),
          tooltip: keyed(context, KeyCommand.goToEnd, (key) => 'Go to end ({key})'.fill({'key': key}), 'Go to end'.tr),
          onPressed: _goToEnd,
        );
      case BarItem.metronome:
        return ToolbarButton(
          glyph: const _MetronomeGlyph(),
          tooltip: keyed(context, KeyCommand.metronome, (key) => 'Metronome ({key})'.fill({'key': key}), 'Metronome'.tr),
          selected: c.playback.metronome,
          onPressed: _metronome,
        );
      case BarItem.readout:
        return Padding(padding: const EdgeInsets.only(left: 10, right: 2), child: TimeReadout(key: widget.readout, controller: c));
      case BarItem.findPhrase:
        return ValueListenableBuilder(
          valueListenable: PhraseSearchWindow.shown,
          builder: (context, shown, _) => ToolbarButton(
            icon: AppIcon.search.of(context),
            tooltip: keyed(context, KeyCommand.findPhrase, (key) => 'Find phrase ({key})'.fill({'key': key}), 'Find phrase'.tr),
            selected: shown,
            onPressed: _findPhrase,
          ),
        );
      case BarItem.viewSwitch:
        // The score, its notes in rows (where it has them beside its engraving) or the player
        // map in its place: one lit, as a segmented switch.
        return Row(mainAxisSize: MainAxisSize.min, children: [
          for (final view in _views)
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
      case BarItem.undo || BarItem.redo:
        return undoRedoButtons(context, undo: _undo, redo: _redo)[item == BarItem.undo ? 0 : 1];
      case BarItem.assets:
        if (!c.images.enabled) return const SizedBox.shrink();
        return ToolbarButton(icon: AppIcon.assets.of(context), tooltip: 'Manage assets…'.tr, onPressed: _assets);
      case BarItem.plugins:
        final plugins = PluginScope.of(context);
        return Row(mainAxisSize: MainAxisSize.min, children: [
          for (final entry in _added)
            ToolbarButton(
              key: ValueKey('plugin ${entry.command.id}'),
              icon: Plugins.iconOf(context, entry),
              tooltip: plugins!.tipOf(entry, KeyMap.of(context)),
              selected: entry.runtime.isChecked(entry.command),
              onPressed: plugins.actionOf(entry),
            ),
        ]);
      case BarItem.export:
        return _ExportMenu(enabled: c.canExport, onVideo: widget.onExportVideo, onWeb: widget.onExportWeb);
      case BarItem.videoRatio:
        return RatioMenu(ratio: widget.videoRatio, onSelected: widget.onVideoRatio);
      case BarItem.scoreSize:
        return Row(mainAxisSize: MainAxisSize.min, children: [
          Tip(message: 'Score size'.tr, child: Icon(AppIcon.scoreSize.of(context), size: 16, color: colors.textMuted)),
          SizedBox(
            width: 132,
            // At the top of the window the value shows below the thumb, not above it.
            child: _sizeSlider(context),
          ),
        ]);
      case BarItem.space:
        if (!saving) return const SizedBox.shrink();
        // However narrow, its line is whole or cut, never squeezed.
        return ClipRect(
          child: OverflowBox(
            minWidth: 0,
            maxWidth: double.infinity,
            alignment: Alignment.centerRight,
            child: _SavingIndicator(document: widget.document),
          ),
        );
      case BarItem.divider:
        return const ToolbarDivider();
      default:
        // One of the app's commands, as its menu item has it.
        return ToolbarButton(
          glyph: BarItemIcon(item),
          tooltip: _tip(context, item),
          selected: item == BarItem.tapAnchors && c.anchors.tapArmed,
          onPressed: _does(context, item.command!),
        );
    }
  }

  Widget _sizeSlider(BuildContext context) => OverlaySemantics(
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(valueIndicatorShape: const BelowValueIndicatorShape()),
          child: Slider(
            value: _c.staffSpace,
            min: EditorController.minStaffSpace,
            max: EditorController.maxStaffSpace,
            divisions: 14,
            label: _c.staffSpace.toStringAsFixed(1),
            onChanged: (v) => _c.setStaffSpace(v, dragging: true),
            onChangeEnd: _c.setStaffSpace,
          ),
        ),
      );

  /// A command's name with its key, as a button's tip has them: "Save (⌘S)".
  static String _tip(BuildContext context, BarItem item) {
    final name = item.label.tr.replaceFirst(RegExp(r'(…|\.\.\.)$'), '');
    final key = switch (KeyCommand.values.asNameMap()[item.command]) { final command? => KeyMap.of(context)[command], null => null };
    return key == null ? name : '$name (${key.label})';
  }

  /// [item] at place [i] of the bar while the toolbar is customized: as it looks, doing
  /// nothing, dragged to another place or off the bar.
  Widget _dragged(BuildContext context, int i, BarItem item) {
    final colors = context.colors;
    final face = switch (item) {
      BarItem.space => Container(
          height: 22,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(border: Border.all(color: colors.line), borderRadius: AppStyle.of(context).radius(4)),
        ),
      // What isn't there now (no images, no plugin's button) still has its place.
      BarItem.assets when !_c.images.enabled => _placeholder(context, item),
      BarItem.plugins when _added.isEmpty => _placeholder(context, item),
      _ => _item(context, item),
    };
    return Draggable<BarDrag>(
      data: (item: item, from: (area: BarArea.bar, index: i)),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: BarItemChip(item),
      childWhenDragging: Opacity(opacity: 0.25, child: AbsorbPointer(child: face)),
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: Tip(message: item.label.tr, waitDuration: const Duration(milliseconds: 600), child: AbsorbPointer(child: face)),
      ),
    );
  }

  Widget _placeholder(BuildContext context, BarItem item) => SizedBox.square(
        dimension: AppStyle.of(context).control,
        child: Center(child: Opacity(opacity: 0.45, child: BarItemIcon(item, size: 16))),
      );

  // MARK: Items in the menu

  /// A menu's row for something chosen: its icon, its name, ticked while [selected].
  PopupMenuItem<VoidCallback> _row(BuildContext context, Widget icon, String label, VoidCallback? action, {bool selected = false}) => menuItem(
        context,
        value: action,
        enabled: action != null,
        child: Row(children: [
          SizedBox(width: 16, child: IconTheme.merge(data: const IconThemeData(size: 16), child: icon)),
          SizedBox(width: AppStyle.of(context).isCarbon ? 8 : 6),
          Expanded(child: Text(label)),
          if (selected) ...[const SizedBox(width: 16), Icon(AppIcon.check.of(context), size: 16)],
        ]),
      );

  /// [item] as rows of the menu at the bar's end.
  List<PopupMenuEntry<VoidCallback>> _entries(BuildContext context, BarItem item) {
    final c = _c;
    PopupMenuItem<VoidCallback> row(VoidCallback? action, {bool selected = false}) =>
        _row(context, BarItemIcon(item), item.label.tr, action, selected: selected);
    switch (item) {
      case BarItem.goToStart:
        return [row(_goToStart)];
      case BarItem.playPause:
        return [row(_playPause)];
      case BarItem.goToEnd:
        return [row(_goToEnd)];
      case BarItem.metronome:
        return [row(_metronome, selected: c.playback.metronome)];
      case BarItem.readout:
        return [_MenuWidget(child: TimeReadout(controller: c))];
      case BarItem.findPhrase:
        return [row(_findPhrase, selected: PhraseSearchWindow.shown.value)];
      case BarItem.viewSwitch:
        return [for (final view in _views) _row(context, view.glyph, view.label.tr, view.show, selected: view.selected)];
      case BarItem.undo:
        return [row(_undo)];
      case BarItem.redo:
        return [row(_redo)];
      case BarItem.assets:
        return [if (c.images.enabled) row(_assets)];
      case BarItem.plugins:
        final plugins = PluginScope.of(context);
        return [
          for (final entry in _added)
            _row(context, Icon(Plugins.iconOf(context, entry)), plugins!.titleOf(entry), plugins.actionOf(entry),
                selected: entry.runtime.isChecked(entry.command)),
        ];
      case BarItem.export:
        return [
          _row(context, Icon(AppIcon.export.of(context)), 'Export Video…'.tr, c.canExport ? widget.onExportVideo : null),
          _row(context, Icon(AppIcon.website.of(context)), 'Export to Web…'.tr, c.canExport ? widget.onExportWeb : null),
        ];
      case BarItem.videoRatio:
        return [
          menuHeader(context, 'Video ratio'),
          ...RatioMenu.entries(context, widget.videoRatio, (r) => () => RatioMenu.choose(context, widget.videoRatio, r, widget.onVideoRatio)),
        ];
      case BarItem.scoreSize:
        return [
          _MenuWidget(
            child: Row(children: [
              Icon(AppIcon.scoreSize.of(context), size: 16, color: context.colors.textMuted),
              // Its value follows the drag: the menu isn't built again as the bar is.
              Expanded(child: ListenableBuilder(listenable: c, builder: (context, _) => _sizeSlider(context))),
            ]),
          ),
        ];
      case BarItem.space:
        return const [];
      case BarItem.divider:
        return [menuDivider(context)];
      default:
        return [row(_does(context, item.command!), selected: item == BarItem.tapAnchors && c.anchors.tapArmed)];
    }
  }

  /// [entries] with no divider first, last or after another.
  static List<PopupMenuEntry<VoidCallback>> _tidied(List<PopupMenuEntry<VoidCallback>> entries) {
    final out = <PopupMenuEntry<VoidCallback>>[];
    for (final entry in entries) {
      if (entry is PopupMenuDivider && (out.isEmpty || out.last is PopupMenuDivider)) continue;
      out.add(entry);
    }
    if (out.isNotEmpty && out.last is PopupMenuDivider) out.removeLast();
    return out;
  }
}

/// The menu at the bar's end (»): the items it has no room for, then those kept there.
class _MoreMenu extends StatelessWidget {
  const _MoreMenu({required this.entries});
  final List<PopupMenuEntry<VoidCallback>> Function(BuildContext context) entries;

  @override
  Widget build(BuildContext context) => OverlaySemantics(
        child: AppPopupMenuButton<VoidCallback>(
          tooltip: 'More tools'.tr,
          position: PopupMenuPosition.under,
          iconSize: 16,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 220),
          style: IconButton.styleFrom(
            fixedSize: Size.square(AppStyle.of(context).control),
            minimumSize: Size.square(AppStyle.of(context).control),
            shape: RoundedRectangleBorder(borderRadius: AppStyle.of(context).radius(5)),
          ),
          icon: Icon(AppIcon.overflow.of(context)),
          onSelected: (action) => action(),
          itemBuilder: entries,
        ),
      );
}

/// A menu's row that is a control, not a choice (the time, the score's size): the menu stays
/// open while it is used.
class _MenuWidget extends PopupMenuEntry<VoidCallback> {
  const _MenuWidget({required this.child});
  final Widget child;

  @override
  double get height => 32;

  @override
  bool represents(VoidCallback? value) => false;

  @override
  State<_MenuWidget> createState() => _MenuWidgetState();
}

class _MenuWidgetState extends State<_MenuWidget> {
  @override
  Widget build(BuildContext context) => Container(
        height: widget.height,
        padding: EdgeInsets.symmetric(horizontal: AppStyle.of(context).menuInset),
        alignment: Alignment.centerLeft,
        child: widget.child,
      );
}

/// A toolbar item's icon ([BarItem]): where it is listed to be added, in the menu at the bar's
/// end, and on the bar for one that is a command.
class BarItemIcon extends StatelessWidget {
  const BarItemIcon(this.item, {super.key, this.size});
  final BarItem item;
  final double? size;

  static const _icons = {
    BarItem.goToStart: AppIcon.toStart,
    BarItem.playPause: AppIcon.play,
    BarItem.goToEnd: AppIcon.toEnd,
    BarItem.findPhrase: AppIcon.search,
    BarItem.viewSwitch: AppIcon.score,
    BarItem.undo: AppIcon.undo,
    BarItem.redo: AppIcon.redo,
    BarItem.assets: AppIcon.assets,
    BarItem.plugins: AppIcon.plugins,
    BarItem.export: AppIcon.export,
    BarItem.videoRatio: AppIcon.frame,
    BarItem.scoreSize: AppIcon.scoreSize,
    BarItem.newProject: AppIcon.add,
    BarItem.open: AppIcon.open,
    BarItem.importScore: AppIcon.drop,
    BarItem.save: AppIcon.save,
    BarItem.exportVideo: AppIcon.export,
    BarItem.exportWeb: AppIcon.website,
    BarItem.followDaw: AppIcon.link,
    BarItem.cut: AppIcon.cut,
    BarItem.copy: AppIcon.copy,
    BarItem.paste: AppIcon.paste,
    BarItem.delete: AppIcon.delete,
    BarItem.tapAnchors: AppIcon.tap,
    BarItem.warp: AppIcon.warp,
    BarItem.showPreview: AppIcon.show,
    BarItem.showTimeline: AppIcon.timeline,
    BarItem.projectSettings: AppIcon.settings,
    BarItem.settings: AppIcon.general,
  };

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final size = this.size ?? theme.size ?? 18;
    final color = theme.color ?? context.colors.text;
    final glyph = switch (item) {
      BarItem.metronome => const _MetronomeGlyph(),
      // The time, as the bar writes it.
      BarItem.readout => FittedBox(
          child: Text('0:00', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color, fontFeatures: const [FontFeature.tabularFigures()])),
        ),
      BarItem.space => CustomPaint(size: Size.square(size), painter: _SpaceGlyphPainter(color, divider: false)),
      BarItem.divider => CustomPaint(size: Size.square(size), painter: _SpaceGlyphPainter(color, divider: true)),
      _ => Icon(_icons[item]!.of(context)),
    };
    return IconTheme.merge(
      data: IconThemeData(size: size, color: color),
      child: SizedBox.square(dimension: size, child: Center(child: glyph)),
    );
  }
}

/// Room between items (arrows apart, to both ends), or the rule between groups of them.
class _SpaceGlyphPainter extends CustomPainter {
  const _SpaceGlyphPainter(this.color, {required this.divider});
  final Color color;
  final bool divider;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (divider) {
      canvas.drawLine(const Offset(12, 4), const Offset(12, 20), line);
      return;
    }
    canvas.drawLine(const Offset(3.5, 5), const Offset(3.5, 19), line);
    canvas.drawLine(const Offset(20.5, 5), const Offset(20.5, 19), line);
    canvas.drawLine(const Offset(7.5, 12), const Offset(16.5, 12), line);
    canvas.drawPath(
        Path()
          ..moveTo(10, 9.5)
          ..lineTo(7.5, 12)
          ..lineTo(10, 14.5)
          ..moveTo(14, 9.5)
          ..lineTo(16.5, 12)
          ..lineTo(14, 14.5),
        line);
  }

  @override
  bool shouldRepaint(_SpaceGlyphPainter old) => old.color != color || old.divider != divider;
}

/// A toolbar item as it is carried: its icon and name on a chip, centred under the pointer.
class BarItemChip extends StatelessWidget {
  const BarItemChip(this.item, {super.key});
  final BarItem item;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return FractionalTranslation(
      translation: const Offset(-0.5, -0.5),
      child: Material(
        color: colors.chrome,
        elevation: 6,
        shape: RoundedRectangleBorder(borderRadius: AppStyle.of(context).radius(8), side: BorderSide(color: colors.line)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            IconTheme.merge(data: IconThemeData(color: colors.text), child: BarItemIcon(item, size: 16)),
            const SizedBox(width: 8),
            Text(item.label.tr, style: TextStyle(fontSize: 12.5, color: colors.text)),
          ]),
        ),
      ),
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

/// Play / pause: the icon morphs between the two.
class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.controller});
  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final playing = controller.playback.isPlaying;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Refined: a transport button like the others, its icon in the accent. Carbon: its primary
    // icon button, white on the accent.
    final tip = playing ? 'Pause (Space)' : 'Play (Space)';
    final icon = playing ? AppIcon.pause.of(context) : AppIcon.play.of(context);
    if (CarbonColors.maybeOf(context) case final k?) {
      return OverlaySemantics(
        child: IconButton(
          tooltip: tip.tr,
          onPressed: () => Plugins.doOwn(context, 'playPause', controller.playback.togglePlay),
          iconSize: 16,
          constraints: BoxConstraints.tightFor(width: AppStyle.of(context).control, height: AppStyle.of(context).control),
          padding: EdgeInsets.zero,
          style: Theme.of(context).filledButtonTheme.style!.copyWith(
                minimumSize: WidgetStatePropertyAll(Size.square(AppStyle.of(context).control)),
                padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                alignment: Alignment.center,
                iconColor: const WidgetStatePropertyAll(Colors.white),
                foregroundColor: const WidgetStatePropertyAll(Colors.white),
                backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.pressed)
                    ? k.primaryActive
                    : s.contains(WidgetState.hovered)
                        ? k.primaryHover
                        : k.primary),
              ),
          icon: Icon(icon),
        ),
      );
    }
    return ToolbarButton(
      icon: icon,
      tooltip: tip,
      color: dark ? colors.accent : colors.accentStrong,
      selected: playing,
      onPressed: () => Plugins.doOwn(context, 'playPause', controller.playback.togglePlay),
    );
  }
}

/// A metronome: its case and the pendulum swung to the right.
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

class _MetronomeGlyph extends StatelessWidget {
  const _MetronomeGlyph();

  @override
  Widget build(BuildContext context) {
    final icon = IconTheme.of(context);
    final size = icon.size ?? 18;
    return CustomPaint(
        size: Size.square(size), painter: _MetronomePainter(icon.color ?? context.colors.text, AppStyle.of(context).isCarbon));
  }
}

/// Drawn as its style's icons are: Material Symbols' light rounded stroke, or Carbon's square 2-unit one.
class _MetronomePainter extends CustomPainter {
  const _MetronomePainter(this.color, this.carbon);
  final Color color;
  final bool carbon;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = carbon ? 1.5 : 1.6
      ..strokeJoin = carbon ? StrokeJoin.miter : StrokeJoin.round
      ..strokeCap = carbon ? StrokeCap.butt : StrokeCap.round;
    canvas.drawPath(
        Path()
          ..moveTo(9.5, 3.5)
          ..lineTo(14.5, 3.5)
          ..lineTo(19, 20.5)
          ..lineTo(5, 20.5)
          ..close(),
        line);
    canvas.drawLine(const Offset(7, 16), const Offset(17, 16), line);
    canvas.drawLine(const Offset(12, 16), const Offset(17.5, 6), line);
    canvas.drawCircle(const Offset(15.6, 9.5), 1.6, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_MetronomePainter old) => old.color != color || old.carbon != carbon;
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
