import 'package:material_ui/material_ui.dart';

import 'app_colors.dart';
import 'editor_toolbar.dart';
import 'l10n/l10n.dart';
import 'toolbar_layout.dart';

/// View ▸ Customize Toolbar…: under the toolbar, in the editor's place, while the toolbar is
/// customized. It lists what can be added (the [ToolbarLayout.palette]) and what the menu at
/// the bar's end holds; an item is dragged from either onto the bar ([EditorToolbar] takes it
/// there), into the menu's list, or back here, which takes it off. Restore Defaults puts the
/// toolbar back as the app comes; Done (or Esc) ends it.
class ToolbarCustomizer extends StatelessWidget {
  const ToolbarCustomizer({super.key, required this.layout, required this.onLayout, required this.onDone});
  final ToolbarLayout layout;
  final ValueChanged<ToolbarLayout> onLayout;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DragTarget<BarDrag>(
      // Dropped anywhere here, an item of the bar or the menu is off the toolbar.
      onWillAcceptWithDetails: (details) => details.data.from != null,
      onAcceptWithDetails: (details) => onLayout(layout.moved(details.data.item, from: details.data.from)),
      builder: (context, _, _) => ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Drag items onto the toolbar or into the overflow menu.'.tr, style: TextStyle(fontSize: 13, color: colors.textMuted)),
                const SizedBox(height: 16),
                Expanded(
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: SingleChildScrollView(
                        child: Wrap(spacing: 8, runSpacing: 8, children: [for (final item in layout.palette) _Tile(item)]),
                      ),
                    ),
                    const SizedBox(width: 28),
                    SizedBox(width: 260, child: _MenuList(layout: layout, onLayout: onLayout)),
                  ]),
                ),
                const SizedBox(height: 16),
                Row(children: [
                  OutlinedButton(
                    onPressed: layout.isStandard ? null : () => onLayout(ToolbarLayout.standard),
                    child: Text('Restore Defaults'.tr),
                  ),
                  const Spacer(),
                  FilledButton(onPressed: onDone, child: Text('Done'.tr)),
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// An item to add: its icon over its name, dragged from here.
class _Tile extends StatefulWidget {
  const _Tile(this.item);
  final BarItem item;

  @override
  State<_Tile> createState() => _TileState();
}

class _TileState extends State<_Tile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors, item = widget.item;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Draggable<BarDrag>(
      data: (item: item, from: null),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: BarItemChip(item),
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Container(
          key: ValueKey('add ${item.name}'),
          width: 112,
          height: 72,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: _hovered ? (dark ? Colors.white : Colors.black).withValues(alpha: dark ? 0.08 : 0.04) : null,
            border: Border.all(color: colors.line),
            borderRadius: AppStyle.of(context).radius(8),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconTheme.merge(data: IconThemeData(color: colors.text), child: BarItemIcon(item, size: 20)),
            const SizedBox(height: 7),
            Text(item.label.tr,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, height: 1.15, color: colors.text)),
          ]),
        ),
      ),
    );
  }
}

/// What the menu at the bar's end holds, top to bottom: each dragged to another place in it,
/// onto the bar or off; one dropped here goes where the mark is.
class _MenuList extends StatefulWidget {
  const _MenuList({required this.layout, required this.onLayout});
  final ToolbarLayout layout;
  final ValueChanged<ToolbarLayout> onLayout;

  @override
  State<_MenuList> createState() => _MenuListState();
}

class _MenuListState extends State<_MenuList> {
  static const _row = 30.0;
  final _rows = GlobalKey();

  /// While an item is dragged over the list: the place it would go.
  int? _insertAt;

  int _placeAt(Offset global) {
    final box = _rows.currentContext!.findRenderObject()! as RenderBox;
    return (box.globalToLocal(global).dy / _row).round().clamp(0, widget.layout.menu.length);
  }

  void _over(int? place) {
    if (place != _insertAt) setState(() => _insertAt = place);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors, menu = widget.layout.menu;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Overflow Menu'.tr, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: colors.textMuted)),
      const SizedBox(height: 8),
      Flexible(
        child: DragTarget<BarDrag>(
          // A menu has no room to share out.
          onWillAcceptWithDetails: (details) => details.data.item != BarItem.space,
          onMove: (details) => _over(details.data.item == BarItem.space ? null : _placeAt(details.offset)),
          onLeave: (_) => _over(null),
          onAcceptWithDetails: (details) {
            final at = _placeAt(details.offset);
            _over(null);
            widget.onLayout(widget.layout.moved(details.data.item, from: details.data.from, to: (area: BarArea.menu, index: at)));
          },
          builder: (context, _, _) => Container(
            key: const ValueKey('overflow menu'),
            constraints: const BoxConstraints(minHeight: _row * 6 + 10),
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              color: colors.chrome,
              border: Border.all(color: _insertAt == null ? colors.line : colors.accent),
              borderRadius: AppStyle.of(context).radius(8),
            ),
            child: SingleChildScrollView(
              child: Stack(children: [
                Column(key: _rows, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (final (i, item) in menu.indexed) _MenuRow(item: item, index: i, height: _row),
                  if (menu.isEmpty)
                    SizedBox(
                      height: _row * 6,
                      child: Center(child: Text('Drag items here'.tr, style: TextStyle(fontSize: 12, color: colors.textMuted))),
                    ),
                ]),
                if (_insertAt case final at? when menu.isNotEmpty)
                  Positioned(left: 8, right: 8, top: (at * _row - 1).clamp(0, menu.length * _row - 2), height: 2, child: ColoredBox(color: colors.accent)),
              ]),
            ),
          ),
        ),
      ),
    ]);
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.item, required this.index, required this.height});
  final BarItem item;
  final int index;
  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final row = SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: item == BarItem.divider
            ? Center(child: Container(height: 1, color: colors.line))
            : Row(children: [
                IconTheme.merge(data: IconThemeData(color: colors.text), child: BarItemIcon(item, size: 16)),
                const SizedBox(width: 8),
                Expanded(child: Text(item.label.tr, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: colors.text))),
              ]),
      ),
    );
    return Draggable<BarDrag>(
      data: (item: item, from: (area: BarArea.menu, index: index)),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: BarItemChip(item),
      childWhenDragging: Opacity(opacity: 0.25, child: row),
      // The whole row is its handle, the room beside its name too.
      child: MouseRegion(cursor: SystemMouseCursors.grab, child: ColoredBox(color: Colors.transparent, child: row)),
    );
  }
}
