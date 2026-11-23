import 'package:material_ui/material_ui.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'audio_panel.dart';
import 'custom_bar.dart';
import 'editor_controller.dart';
import 'instruments_toolbar.dart';
import 'key_bindings.dart';
import 'toolbar_layout.dart';
import 'ui_kit.dart';
import 'video_panel.dart';
import 'l10n/l10n.dart';

/// The timeline's bar: the switch between its tabs, then the tools of the one shown, a toolbar
/// of its own for each ([BarKind.instruments], [BarKind.audio], [BarKind.video]), whose items
/// and where they are is the user's ([layoutOf], View ▸ Customize Toolbar…, a [CustomBar]):
/// those it has no room for, and those kept there, are in the menu at its end (»).
class PanelBar extends StatelessWidget {
  const PanelBar({
    super.key,
    required this.controller,
    this.layoutOf,
    this.onLayout,
    this.customizing = false,
    this.onCustomize,
    this.commands,
    this.commandsChanged,
  });
  final EditorController controller;

  /// Where each tab's tools are (null: as the app comes); [onLayout] changes one (an item's
  /// own menu, a drop while [customizing]); null: they stay.
  final ToolbarLayout Function(BarKind kind)? layoutOf;
  final ValueChanged<ToolbarLayout>? onLayout;

  /// Whether the toolbar of the tab shown is being customized: its items do nothing and are
  /// dragged (the switch still changes tab, to customize another's). [onCustomize] starts that
  /// (null: no such item in its menu).
  final bool customizing;
  final VoidCallback? onCustomize;

  /// The app's commands by id as they can be chosen now (null: not now), for the items that do
  /// one ([BarItem.command]), and what says they changed. Without, those items are greyed out.
  final Map<String, VoidCallback?> Function()? commands;
  final Listenable? commandsChanged;

  static const _switch = Duration(milliseconds: 220);

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return ListenableBuilder(
      listenable: Listenable.merge([c, ?commandsChanged]),
      // (Its own listenable: the curation and the sync are another project's once one is opened.)
      builder: (context, _) => ListenableBuilder(
        listenable: Listenable.merge([?c.curation, ?c.sync]),
        builder: (context, _) => _bar(context),
      ),
    );
  }

  Widget _bar(BuildContext context) {
    final c = controller, colors = context.colors;
    final kind = BarKind.ofTab(c.tab.index);
    return Container(
      height: AppStyle.of(context).panelBar,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(color: colors.chrome, border: Border(bottom: BorderSide(color: colors.line))),
      child: Row(children: [
        _TabSwitch(value: c.tab, onChanged: (tab) => c.tab = tab),
        const ToolbarDivider(),
        Expanded(
          child: c.score == null || c.curation == null || c.sync == null
              ? const SizedBox.shrink()
              : AnimatedSwitcher(
                  duration: AppStyle.of(context).moving(_switch),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  layoutBuilder: (current, previous) => Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
                  transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
                  child: CustomBar(
                    key: ValueKey(kind),
                    layout: layoutOf?.call(kind) ?? ToolbarLayout.standard(kind),
                    onLayout: onLayout,
                    items: PanelItems(kind: kind, controller: c, commands: commands),
                    customizing: customizing,
                    onCustomize: onCustomize,
                  ),
                ),
        ),
      ]),
    );
  }
}

/// The items of the timeline's bar in one of its tabs ([kind]): any toolbar's ([BarItems]),
/// the timeline's (the lanes' tools, its zoom, the speed) and that tab's own. One of the
/// selection's (or of a sync that is edited) is there only while there is one; the bar's first
/// space says what is selected.
class PanelItems extends BarItems {
  const PanelItems({required this.kind, required super.controller, super.commands});
  final BarKind kind;

  @override
  Listenable get changes => Listenable.merge([controller, ?controller.curation, ?controller.sync]);

  static const _fading = {BarItem.trimStart, BarItem.trimEnd, BarItem.remove, BarItem.transition, BarItem.staves, BarItem.viewFade};

  @override
  bool fades(BarItem item) => _fading.contains(item);

  /// Whether [item] is one this bar makes: a control of the timeline's or, on the Audio tab,
  /// the sync's own Tap and Warp in the commands' place.
  bool _own(BarItem item) => item.command == null
      ? !item.repeats
      : kind == BarKind.audio && (item == BarItem.tapAnchors || item == BarItem.warp);

  static const _buttons = {
    BarItem.zoomOut, BarItem.zoomIn, BarItem.fit, BarItem.trimStart, BarItem.trimEnd, BarItem.remove, BarItem.autoCurate, BarItem.clearLanes, //
    BarItem.addRecording, BarItem.align, BarItem.warp,
  };

  /// What [item], one of [_buttons], says on hover and does (null: greyed out); null while it
  /// has nothing to show.
  ({String tip, VoidCallback? action})? _button(BuildContext context, BarItem item) {
    final c = controller, v = c.viewport;
    switch (item) {
      case BarItem.zoomOut:
        return (tip: 'Zoom out ({key} or pinch)'.fill({'key': shortcut('⌘-scroll')}), action: () => v.zoom(1 / 1.5));
      case BarItem.zoomIn:
        return (tip: 'Zoom in ({key} or pinch)'.fill({'key': shortcut('⌘-scroll')}), action: () => v.zoom(1.5));
      case BarItem.fit:
        return (tip: 'Fit'.tr, action: v.fit);
      case BarItem.trimStart when c.lanes.selected.isNotEmpty:
        return (
          tip: keyed(context, KeyCommand.trimStart, (key) => 'Start at the playhead ({key})'.fill({'key': key}), 'Start at the playhead'.tr),
          action: () => c.lanes.trimToPlayhead(start: true),
        );
      case BarItem.trimEnd when c.lanes.selected.isNotEmpty:
        return (
          tip: keyed(context, KeyCommand.trimEnd, (key) => 'End at the playhead ({key})'.fill({'key': key}), 'End at the playhead'.tr),
          action: () => c.lanes.trimToPlayhead(start: false),
        );
      case BarItem.remove when kind == BarKind.video:
        return c.automation.selectedStretch == null ? null : (tip: 'Remove (Delete)'.tr, action: c.automation.removeSelected);
      case BarItem.remove when c.lanes.selected.isNotEmpty:
        return (tip: 'Remove (Delete)'.tr, action: c.commands.delete);
      case BarItem.autoCurate:
        return (tip: 'Auto-curate'.tr, action: c.canAutoCurate ? c.lanes.autoCurate : null);
      case BarItem.clearLanes:
        return (tip: 'Clear all lanes'.tr, action: c.lanes.clear);
      case BarItem.addRecording:
        return (
          tip: c.track == null ? 'Add Recording… (or drop one here)'.tr : 'Add Recording…'.tr,
          action: c.isLoadingAudio ? null : () => pickAudio(context, c, add: true),
        );
      // A PDF score has no notes to align to: its anchors are tapped.
      case BarItem.align when c.editsSync && !c.usesMidiTempo && c.hasNotes:
        return (tip: 'Align'.tr, action: c.anchors.aligning != null || c.track == null || c.isLoadingAudio ? null : () => align(context, c));
      case BarItem.warp when c.editsSync:
        return (
          tip: '${keyed(context, KeyCommand.warp, (key) => 'Warp ({key})'.fill({'key': key}), 'Warp'.tr)}\n'
              '${c.anchors.selected.length == 1 && !c.usesMidiTempo ? 'Make this anchor jump to another bar'.tr : 'Jump to another bar here'.tr}',
          action: () => editWarp(context, c),
        );
      default:
        return null;
    }
  }

  @override
  Widget? item(BuildContext context, BarItem item, {bool first = false}) {
    final c = controller;
    if (item == BarItem.space && first) return _says(context);
    if (!_own(item)) return super.item(context, item, first: first);
    if (_buttons.contains(item) && item != BarItem.align) {
      final button = _button(context, item);
      return button == null ? null : ToolbarButton(glyph: BarItemIcon(item), tooltip: button.tip, onPressed: button.action);
    }
    final syncs = c.editsSync, taps = syncs && !c.usesMidiTempo;
    return switch (item) {
      // The recordings' lanes have regions only once there are two.
      BarItem.laneTools when kind == BarKind.audio && c.takes.length < 2 => null,
      BarItem.laneTools => Padding(
          padding: EdgeInsets.only(left: kind == BarKind.audio ? 2 : 0, right: 4),
          child: InstrumentsToolbar.toolGroup(context, c),
        ),
      BarItem.speed => SpeedMenu(controller: c),
      BarItem.transition => c.lanes.selected.isEmpty ? null : TransitionMenu(controller: c),
      BarItem.staves => c.lanes.selected.isEmpty || c.lanes.selectedStaffCount < 2 ? null : StavesMenu(controller: c),
      BarItem.tidy => TidyMenu(controller: c, lanes: c.lanes.selectedPartIds.length),
      BarItem.script => ToolbarButton(
          glyph: BarItemIcon(item),
          tooltip: 'Script\nCurate by writing'.tr,
          selected: c.lanes.scripting,
          onPressed: () => c.lanes.scripting = !c.lanes.scripting,
        ),
      BarItem.crossfade => c.takes.length < 2 ? null : CrossfadeMenu(controller: c),
      // (Filled, with its name, while the recording has no anchors.)
      BarItem.align => _button(context, item) == null ? null : Padding(padding: const EdgeInsets.only(right: 2), child: AlignButton(controller: c)),
      BarItem.tapAnchors => taps ? TapButton(controller: c) : null,
      BarItem.syncStep => taps ? Padding(padding: const EdgeInsets.only(left: 2), child: StepMenu(controller: c)) : null,
      BarItem.startsAt => syncs ? Padding(padding: const EdgeInsets.only(left: 4), child: StartField(controller: c)) : null,
      BarItem.syncMenu => syncs ? SyncMenu(controller: c) : null,
      _ => VideoToolbar.item(context, c, item),
    };
  }

  /// What the tab has to say, in the bar's first space: what is selected in the lanes; the
  /// anchors selected; that the project has no player map for a view to show.
  Widget _says(BuildContext context) {
    final c = controller, style = TextStyle(fontSize: 12, color: context.colors.textMuted);
    return switch (kind) {
      BarKind.instruments => Align(
          alignment: Alignment.centerLeft,
          child: Padding(padding: const EdgeInsets.only(left: 8), child: FadingText(InstrumentsToolbar.status(c), style: style)),
        ),
      // However narrow, the chip is whole or cut, never squeezed.
      BarKind.audio => ClipRect(
          child: OverflowBox(minWidth: 0, maxWidth: double.infinity, alignment: Alignment.centerRight, child: AnchorsChip(controller: c)),
        ),
      BarKind.video when c.playerMap.map == null => Align(
          alignment: Alignment.centerRight,
          child: Padding(padding: const EdgeInsets.only(right: 8), child: FadingText('No player map'.tr, style: style)),
        ),
      _ => const SizedBox.shrink(),
    };
  }

  @override
  List<PopupMenuEntry<VoidCallback>> entries(BuildContext context, BarItem item) {
    if (!_own(item)) return super.entries(context, item);
    if (_buttons.contains(item)) {
      final button = _button(context, item);
      return [if (button != null) row(context, item, button.action)];
    }
    if (item == BarItem.script) return [row(context, item, () => controller.lanes.scripting = !controller.lanes.scripting, selected: controller.lanes.scripting)];
    if (this.item(context, item) == null) return const [];
    // Tap is a choice as the commands are; the rest are the controls themselves.
    return item == BarItem.tapAnchors ? super.entries(context, item) : [control(item)];
  }
}

/// Instruments | Audio | Video, as three icons with a highlight that slides between them.
class _TabSwitch extends StatelessWidget {
  const _TabSwitch({required this.value, required this.onChanged});
  final BottomTab value;
  final ValueChanged<BottomTab> onChanged;

  static const _tabs = [
    (BottomTab.instruments, AppIcon.lanes, 'Instruments'),
    (BottomTab.audio, AppIcon.audio, 'Audio'),
    (BottomTab.video, AppIcon.frame, 'Video'),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // In a well, the chosen icon in the text colour; Carbon's icon content switcher: edged in
    // $border-inverse, the chosen one inverse.
    final style = AppStyle.of(context);
    final k = CarbonColors.maybeOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final size = k != null ? 30.0 : 26.0;
    final well = k != null ? Colors.transparent : colors.well;
    final knob = k?.selectedInverse ?? (dark ? RefinedGreys.dark600 : colors.surface);
    final chosen = k?.textInverse ?? colors.text;
    final index = _tabs.indexWhere((t) => t.$1 == value);
    return Container(
      padding: EdgeInsets.all(k != null ? 0 : 2),
      decoration: BoxDecoration(color: well, border: Border.all(color: k?.borderInverse ?? colors.line), borderRadius: style.radius(7)),
      child: Stack(children: [
        AnimatedPositioned(
          duration: motion(context, 220),
          curve: style.curve,
          left: index * size,
          top: 0,
          width: size,
          height: size,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: knob,
              borderRadius: style.radius(5),
              boxShadow: [if (k == null) BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 3, offset: const Offset(0, 1))],
              border: k != null ? null : Border.all(color: colors.line),
            ),
          ),
        ),
        Row(mainAxisSize: MainAxisSize.min, children: [
          for (final (tab, icon, tip) in _tabs)
            Tip(
              message: tip,
              child: InkWell(
                borderRadius: style.radius(5),
                onTap: () => onChanged(tab),
                child: SizedBox.square(
                  dimension: size,
                  child: TweenAnimationBuilder<Color?>(
                    duration: stateDuration(motion(context, 200)),
                    tween: ColorTween(end: tab == value ? chosen : k?.textSecondary ?? colors.textMuted),
                    builder: (context, color, _) => Icon(icon.of(context), size: 16, color: color),
                  ),
                ),
              ),
            ),
        ]),
      ]),
    );
  }
}
