import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'editor_controller.dart';
import 'key_bindings.dart';
import 'macros.dart';
import 'menu_kit.dart';
import 'phrase_search_window.dart';
import 'plugins/plugins.dart';
import 'toolbar_layout.dart';
import 'toolbar_strip.dart';
import 'ui_kit.dart';
import 'l10n/l10n.dart';

/// A toolbar whose items, and where they are, is the user's ([layout], View ▸ Customize
/// Toolbar…): those of [layout]'s bar in a row ([ToolbarStrip]) as [items] makes them, the ones
/// it has no room for, and those kept there, in the menu at its end (»). A right click on an
/// item moves it to that menu or takes it off; on the bar itself, starts customizing it
/// ([onCustomize]). While [customizing] its items do nothing and are dragged: to another
/// place, into the menu's list or off it ([ToolbarCustomizer]), each change told to [onLayout].
class CustomBar extends StatefulWidget {
  const CustomBar({super.key, required this.layout, required this.items, this.onLayout, this.customizing = false, this.onCustomize});

  /// Where its items are; [onLayout] changes that (an item's own menu, a drop while
  /// [customizing]); null: they stay.
  final ToolbarLayout layout;
  final ValueChanged<ToolbarLayout>? onLayout;

  /// What each item is, on the bar and in its menu.
  final BarItems items;

  /// Whether the toolbar is being customized: its items do nothing and are dragged, to another
  /// place or off it. [onCustomize] starts that (null: no such item in its menu).
  final bool customizing;
  final VoidCallback? onCustomize;

  @override
  State<CustomBar> createState() => _CustomBarState();
}

class _CustomBarState extends State<CustomBar> {
  final _strip = GlobalKey();

  /// How many of the bar's items it has room for ([ToolbarStrip.onFit]): the rest are in its menu.
  int _fit = BarItem.values.length * 4;

  /// While an item is dragged over the bar: the place it would go.
  int? _insertAt;

  RenderToolbarStrip get _box => _strip.currentContext!.findRenderObject()! as RenderToolbarStrip;

  @override
  Widget build(BuildContext context) {
    final layout = widget.layout, bar = layout.bar, items = widget.items, customizing = widget.customizing;
    final fit = math.min(_fit, bar.length);
    // One of a kind keeps its state wherever it is put; a space or a divider is the nth.
    final nth = <BarItem, int>{};
    final firstSpace = bar.indexOf(BarItem.space);
    Widget shown(int i, BarItem item) {
      final made = items.item(context, item, first: i == firstSpace);
      // One there only at times comes and goes gently.
      return items.fades(item) ? FadeSlideSwitcher(child: made ?? const SizedBox.shrink()) : made ?? const SizedBox.shrink();
    }

    final strip = ToolbarStrip(
      key: _strip,
      showMore: layout.menu.isNotEmpty,
      // Every rule is there to be dragged.
      collapse: !customizing,
      insertAt: _insertAt,
      markColor: context.colors.accent,
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
              child: customizing ? _dragged(context, i, item) : shown(i, item),
            ),
          ),
      ],
      more: customizing
          ? IgnorePointer(child: Opacity(opacity: 0.4, child: ToolbarButton(icon: AppIcon.overflow.of(context), tooltip: 'More tools'.tr, onPressed: () {})))
          : _MoreMenu(entries: (context) => _tidied([
                for (final item in bar.skip(fit)) ...items.entries(context, item),
                if (fit < bar.length && layout.menu.isNotEmpty) menuDivider(context),
                for (final item in layout.menu) ...items.entries(context, item),
              ])),
    );
    if (customizing) {
      return DragTarget<BarDrag>(
        onWillAcceptWithDetails: (details) => details.data.item.on.contains(layout.kind),
        onMove: (details) => _over(_box.placeAt(_box.globalToLocal(details.offset).dx)),
        onLeave: (_) => _over(null),
        onAcceptWithDetails: (details) {
          final at = _box.placeAt(_box.globalToLocal(details.offset).dx);
          _over(null);
          widget.onLayout?.call(layout.moved(details.data.item, from: details.data.from, to: (area: BarArea.bar, index: at)));
        },
        builder: (context, _, _) => strip,
      );
    }
    // A right click on an item: its own menu; on the bar: Customize Toolbar….
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapUp: widget.onCustomize == null ? null : (details) => _itemMenu(context, details.globalPosition),
      child: strip,
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

  /// [item] at place [i] of the bar while the toolbar is customized: as it looks, doing
  /// nothing, dragged to another place or off the bar.
  Widget _dragged(BuildContext context, int i, BarItem item) {
    final colors = context.colors;
    final face = item == BarItem.space
        ? Container(
            height: 22,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(border: Border.all(color: colors.line), borderRadius: AppStyle.of(context).radius(4)),
          )
        // What isn't there now (no images, nothing selected) still has its place.
        : widget.items.item(context, item) ??
            SizedBox.square(
              dimension: AppStyle.of(context).control,
              child: Center(child: Opacity(opacity: 0.45, child: BarItemIcon(item, size: 16))),
            );
    return Draggable<BarDrag>(
      data: (item: item, from: (area: BarArea.bar, index: i)),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: BarItemChip(item),
      childWhenDragging: Opacity(opacity: 0.25, child: AbsorbPointer(child: face)),
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: Tip(message: barItemTitle(context, item), waitDuration: const Duration(milliseconds: 600), child: AbsorbPointer(child: face)),
      ),
    );
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

/// What a [CustomBar]'s items are: each on the bar ([item]) and in the menu at its end
/// ([entries]). As it is, the ones any toolbar takes: a button for each of the app's commands
/// ([BarItem.command]), room and rules; a toolbar adds its own controls to them.
class BarItems {
  const BarItems({required this.controller, this.commands});
  final EditorController controller;

  /// The app's commands by id as they can be chosen now (null: not now), for the items that do
  /// one ([BarItem.command]). Without, those items are greyed out.
  final Map<String, VoidCallback?> Function()? commands;

  /// What says a control shown in the menu ([control]) has something else to show.
  Listenable get changes => controller;

  /// Whether [item] comes and goes (it is there only at times): faded in and out then.
  bool fades(BarItem item) => false;

  /// What choosing the app's command [id] does now, as plugins have it; null while it can't be.
  VoidCallback? does(BuildContext context, String id) {
    final action = commands?.call()[id];
    return action == null ? null : () => Plugins.doOwn(context, id, action);
  }

  /// What [item], one of the app's commands, does now: as its key does it (what a plugin put
  /// around the command is what the button does); null while it can't be chosen.
  VoidCallback? _action(BuildContext context, BarItem item) {
    final c = controller;
    return switch (item) {
      BarItem.goToStart => () => Plugins.doOwn(context, 'goToStart', () => c.playback.seek(0)),
      BarItem.goToEnd => () => Plugins.doOwn(context, 'goToEnd', () => c.playback.seek(c.playback.duration)),
      BarItem.playPause => () => Plugins.doOwn(context, 'playPause', c.playback.togglePlay),
      BarItem.metronome => () => Plugins.doOwn(context, 'metronome', () => c.playback.metronome = !c.playback.metronome),
      BarItem.undo => c.canUndo ? () => Plugins.doOwn(context, 'undo', c.undo) : null,
      BarItem.redo => c.canRedo ? () => Plugins.doOwn(context, 'redo', c.redo) : null,
      BarItem.findPhrase => !c.hasNotes ? null : () => Plugins.doOwn(context, 'findPhrase', () => PhraseSearchWindow.toggle(Overlay.of(context), c)),
      _ => does(context, item.command!),
    };
  }

  bool _selected(BarItem item) => switch (item) {
        BarItem.metronome => controller.playback.metronome,
        BarItem.findPhrase => PhraseSearchWindow.shown.value,
        BarItem.tapAnchors => controller.anchors.tapArmed,
        _ => false,
      };

  /// [item] as it is on the bar; null while it has nothing to show. [first] is the bar's first
  /// space, where a toolbar says what it has to say.
  Widget? item(BuildContext context, BarItem item, {bool first = false}) {
    switch (item) {
      case BarItem.goToStart:
        return ToolbarButton(
          icon: AppIcon.toStart.of(context),
          tooltip: keyed(context, KeyCommand.goToStart, (key) => 'Go to start ({key})'.fill({'key': key}), 'Go to start'.tr),
          onPressed: _action(context, item),
        );
      case BarItem.playPause:
        return PlayButton(controller: controller);
      case BarItem.goToEnd:
        return ToolbarButton(
          icon: AppIcon.toEnd.of(context),
          tooltip: keyed(context, KeyCommand.goToEnd, (key) => 'Go to end ({key})'.fill({'key': key}), 'Go to end'.tr),
          onPressed: _action(context, item),
        );
      case BarItem.metronome:
        return ToolbarButton(
          glyph: const MetronomeGlyph(),
          tooltip: keyed(context, KeyCommand.metronome, (key) => 'Metronome ({key})'.fill({'key': key}), 'Metronome'.tr),
          selected: _selected(item),
          onPressed: _action(context, item),
        );
      case BarItem.findPhrase:
        return ValueListenableBuilder(
          valueListenable: PhraseSearchWindow.shown,
          builder: (context, shown, _) => ToolbarButton(
            icon: AppIcon.search.of(context),
            tooltip: keyed(context, KeyCommand.findPhrase, (key) => 'Find phrase ({key})'.fill({'key': key}), 'Find phrase'.tr),
            selected: shown,
            onPressed: _action(context, item),
          ),
        );
      case BarItem.undo || BarItem.redo:
        return undoRedoButtons(context, undo: _action(context, BarItem.undo), redo: _action(context, BarItem.redo))[item == BarItem.undo ? 0 : 1];
      case BarItem.space:
        return const SizedBox.shrink();
      case BarItem.divider:
        return const ToolbarDivider();
      // A macro's own button, while there is such a macro.
      case _ when item.macro != null:
        final macro = MacrosScope.of(context).elementAtOrNull(item.macro!);
        return macro == null ? null : ToolbarButton(glyph: BarItemIcon(item), tooltip: tipOf(context, item), onPressed: macroAction(context, controller, macro));
      default:
        // One of the app's commands, as its menu item has it.
        return ToolbarButton(glyph: BarItemIcon(item), tooltip: tipOf(context, item), selected: _selected(item), onPressed: _action(context, item));
    }
  }

  /// A command's name with its key, as a button's tip has them: "Save (⌘S)".
  static String tipOf(BuildContext context, BarItem item) {
    // A macro's button: its macro's name, with the key that counts it.
    if (item.macro case final at?) return '${barItemTitle(context, item)} (${KeyCommand.runMacro.also[at].label})';
    final name = item.title.replaceFirst(RegExp(r'(…|\.\.\.)$'), '');
    final key = switch (KeyCommand.values.asNameMap()[item.command]) { final command? => KeyMap.of(context)[command], null => null };
    return key == null ? name : '$name (${key.label})';
  }

  /// [item] as rows of the menu at the bar's end; none while it has nothing to show.
  List<PopupMenuEntry<VoidCallback>> entries(BuildContext context, BarItem item) => switch (item) {
        BarItem.space => const [],
        BarItem.divider => [menuDivider(context)],
        _ when item.macro != null => [
            if (MacrosScope.of(context).elementAtOrNull(item.macro!) case final macro?) row(context, item, macroAction(context, controller, macro)),
          ],
        _ => [row(context, item, _action(context, item), selected: _selected(item))],
      };

  /// A menu's row for [item] chosen: its icon and name ([icon] and [label], given them), ticked
  /// while [selected], greyed out with no [action].
  PopupMenuItem<VoidCallback> row(BuildContext context, BarItem item, VoidCallback? action, {bool selected = false, Widget? icon, String? label}) => menuItem(
        context,
        value: action,
        enabled: action != null,
        child: Row(children: [
          SizedBox(width: 16, child: IconTheme.merge(data: const IconThemeData(size: 16), child: icon ?? BarItemIcon(item))),
          SizedBox(width: AppStyle.of(context).isCarbon ? 8 : 6),
          Expanded(child: Text(label ?? barItemTitle(context, item))),
          if (selected) ...[const SizedBox(width: 16), Icon(AppIcon.check.of(context), size: 16)],
        ]),
      );

  /// A menu's row that is [item]'s control itself (a menu of its own, a field), after its name:
  /// the menu stays open while it is used, the control showing what it has set.
  PopupMenuEntry<VoidCallback> control(BarItem item) => MenuWidget(
        child: ListenableBuilder(
          listenable: changes,
          builder: (context, _) => Row(children: [
            Expanded(child: Text(barItemTitle(context, item), overflow: TextOverflow.ellipsis, style: PopupMenuTheme.of(context).textStyle ?? Theme.of(context).textTheme.labelLarge)),
            const SizedBox(width: 12),
            this.item(context, item) ?? const SizedBox.shrink(),
          ]),
        ),
      );
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
          style: ToolbarButton.styleOf(context),
          icon: Icon(AppIcon.overflow.of(context)),
          onSelected: (action) => action(),
          itemBuilder: entries,
        ),
      );
}

/// A menu's row that is a control, not a choice (the time, the score's size): the menu stays
/// open while it is used.
class MenuWidget extends PopupMenuEntry<VoidCallback> {
  const MenuWidget({super.key, required this.child});
  final Widget child;

  @override
  double get height => 32;

  @override
  bool represents(VoidCallback? value) => false;

  @override
  State<MenuWidget> createState() => _MenuWidgetState();
}

class _MenuWidgetState extends State<MenuWidget> {
  @override
  Widget build(BuildContext context) => Container(
        height: widget.height,
        padding: EdgeInsets.symmetric(horizontal: AppStyle.of(context).menuInset),
        alignment: Alignment.centerLeft,
        child: widget.child,
      );
}

/// [item]'s name as shown where [context] is: its own, or for a macro's button its macro's
/// (Macro 3, while there is no third).
String barItemTitle(BuildContext context, BarItem item) => switch (item.macro) {
      null => item.title,
      final at => switch (MacrosScope.of(context).elementAtOrNull(at)) {
          final macro? => macroName(macro),
          null => 'Macro {n}'.fill({'n': at + 1}),
        },
    };

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
    BarItem.laneTools: AppIcon.pointer,
    BarItem.zoomOut: AppIcon.zoomOut,
    BarItem.zoomIn: AppIcon.zoomIn,
    BarItem.fit: AppIcon.fit,
    BarItem.speed: AppIcon.speed,
    BarItem.trimStart: AppIcon.trimStart,
    BarItem.trimEnd: AppIcon.trimEnd,
    BarItem.remove: AppIcon.delete,
    BarItem.transition: AppIcon.transition,
    BarItem.staves: AppIcon.lanes,
    BarItem.tidy: AppIcon.tidy,
    BarItem.autoCurate: AppIcon.autoCurate,
    BarItem.clearLanes: AppIcon.clearLanes,
    BarItem.script: AppIcon.code,
    BarItem.macros: AppIcon.repeat,
    BarItem.addRecording: AppIcon.addAudio,
    BarItem.crossfade: AppIcon.transition,
    BarItem.align: AppIcon.align,
    BarItem.syncStep: AppIcon.snap,
    BarItem.startsAt: AppIcon.leadIn,
    BarItem.syncMenu: AppIcon.more,
    BarItem.viewKind: AppIcon.show,
    BarItem.mapPlace: AppIcon.pin,
    BarItem.mapSize: AppIcon.expand,
    BarItem.viewFade: AppIcon.transition,
  };

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final size = this.size ?? theme.size ?? 18;
    final color = theme.color ?? context.colors.text;
    final glyph = switch (item) {
      BarItem.metronome => const MetronomeGlyph(),
      // The time, as the bar writes it.
      BarItem.readout => FittedBox(
          child: Text('0:00', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color, fontFeatures: const [FontFeature.tabularFigures()])),
        ),
      BarItem.space => CustomPaint(size: Size.square(size), painter: _SpaceGlyphPainter(color, divider: false)),
      BarItem.divider => CustomPaint(size: Size.square(size), painter: _SpaceGlyphPainter(color, divider: true)),
      // A macro's button: its macro's icon (every macro's, while there is no such macro).
      _ when item.macro != null => Icon(macroIcon(MacrosScope.of(context).elementAtOrNull(item.macro!)).of(context)),
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
            Text(barItemTitle(context, item), style: TextStyle(fontSize: 12.5, color: colors.text)),
          ]),
        ),
      ),
    );
  }
}

/// Play / pause: the icon morphs between the two.
class PlayButton extends StatelessWidget {
  const PlayButton({super.key, required this.controller});
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
class MetronomeGlyph extends StatelessWidget {
  const MetronomeGlyph({super.key});

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

