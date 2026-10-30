import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'ui_kit.dart';
import 'l10n/l10n.dart';

/// A popup menu's row: a desktop menu's ([AppStyle.menuRow]), not Material's 48 px.
double menuRowHeight(BuildContext context) => AppStyle.of(context).menuRow;

EdgeInsets _itemPadding(BuildContext context) => EdgeInsets.symmetric(horizontal: AppStyle.of(context).menuInset);

/// A [PopupMenuItem] at [menuRowHeight]. Use it, not the item itself, in a menu.
PopupMenuItem<T> menuItem<T>(BuildContext context, {T? value, bool enabled = true, required Widget child}) =>
    PopupMenuItem<T>(
      value: value,
      enabled: enabled,
      height: menuRowHeight(context),
      padding: _itemPadding(context),
      child: child,
    );

/// A menu's heading: a muted row that can't be chosen, its text on the same edge as the items'.
PopupMenuItem<T> menuHeader<T>(BuildContext context, String text) => PopupMenuItem<T>(
      enabled: false,
      height: menuRowHeight(context),
      padding: _itemPadding(context),
      child: Text(text.tr, style: TextStyle(fontSize: 12, letterSpacing: AppStyle.of(context).isCarbon ? 0.32 : null)),
    );

/// A [PopupMenuDivider] with the space of a [menuRowHeight]'s row.
PopupMenuDivider menuDivider(BuildContext context) =>
    PopupMenuDivider(height: 9, color: CarbonColors.maybeOf(context)?.borderSubtle);

/// A checked item at [menuRowHeight], its check before it (the material one is a list tile, 40 px
/// at the least however its theme is set).
PopupMenuItem<T> checkedMenuItem<T>(BuildContext context,
    {required T value, required bool checked, bool enabled = true, required Widget child}) {
  return PopupMenuItem<T>(
    value: value,
    enabled: enabled,
    height: menuRowHeight(context),
    padding: _itemPadding(context),
    child: Semantics(
      role: SemanticsRole.menuItemCheckbox,
      checked: checked,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 16, child: checked ? Icon(AppIcon.check.of(context), size: 16) : null),
        SizedBox(width: AppStyle.of(context).isCarbon ? 8 : 6),
        child,
      ]),
    ),
  );
}

/// A [PopupMenuButton] that opens and shuts in the style's time ([AppStyle.menuOpen]; the material
/// menu takes 300 ms), its rows set close. Fill it with [menuItem] and [checkedMenuItem].
class AppPopupMenuButton<T> extends StatelessWidget {
  const AppPopupMenuButton({
    super.key,
    required this.itemBuilder,
    this.onSelected,
    this.enabled = true,
    this.tooltip,
    this.position,
    this.style,
    this.icon,
    this.iconSize,
    this.padding = const EdgeInsets.all(8),
    this.constraints,
    this.child,
  });

  final PopupMenuItemBuilder<T> itemBuilder;
  final PopupMenuItemSelected<T>? onSelected;
  final bool enabled;
  final String? tooltip;
  final PopupMenuPosition? position;
  final ButtonStyle? style;
  final Widget? icon;
  final double? iconSize;
  final EdgeInsetsGeometry padding;
  final BoxConstraints? constraints;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      itemBuilder: itemBuilder,
      onSelected: onSelected,
      enabled: enabled,
      tooltip: tooltip?.tr,
      position: position,
      style: style,
      icon: icon,
      iconSize: iconSize,
      padding: padding,
      constraints: constraints,
      popUpAnimationStyle: AnimationStyle(
        duration: AppStyle.of(context).menuOpen,
        reverseDuration: AppStyle.of(context).menuClose,
        curve: AppStyle.of(context).enterCurve,
        reverseCurve: AppStyle.of(context).exitCurve,
      ),
      child: child,
    );
  }
}

/// A select for the app: a field whose menu of [MenuItemButton]s, [AppStyle.menuRow] rows, fades
/// in over [AppStyle.menuOpen] (the material dropdown's rows are 48 px, its menu 300 ms).
///
/// With a [label] it is a labelled field (the label over it). Without, it is bare: [boxed]
/// outlines it (Carbon: fills it, a line under it), and [icon] replaces its arrow. Boxed or
/// labelled, it is a dialog's field: [AppStyle.field] tall, 14 px text.
class AppDropdown<T> extends StatefulWidget {
  const AppDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.hint,
    this.isExpanded = false,
    this.dense = false,
    this.boxed = false,
    this.label,
    this.icon,
    this.style,
  });

  final T? value;
  final List<DropdownMenuItem<T>> items;

  /// What a choice does; null disables the select.
  final ValueChanged<T?>? onChanged;

  /// Shown when no item has [value].
  final Widget? hint;
  final bool isExpanded;
  final bool dense;
  final bool boxed;
  final String? label;
  final Widget? icon;
  final TextStyle? style;

  @override
  State<AppDropdown<T>> createState() => _AppDropdownState<T>();
}

class _AppDropdownState<T> extends State<AppDropdown<T>> {
  final _menu = MenuController();
  final _focus = FocusNode();
  double _width = 0;
  bool _open = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _toggle() {
    if (_menu.isOpen) return _menu.close();
    _width = (context.findRenderObject() as RenderBox).size.width;
    _menu.open();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final colors = context.colors;
    final theme = Theme.of(context);
    final app = AppStyle.of(context);
    final k = CarbonColors.maybeOf(context);
    final enabled = w.onChanged != null;
    final selected = w.items.where((item) => item.value == w.value).firstOrNull;
    // In a dialog (boxed, labelled) it is the dialog's size: 36 px, 14 px text.
    final inDialog = w.boxed || w.label != null;
    final style = (w.style ?? theme.textTheme.bodyMedium!.copyWith(fontSize: inDialog ? 14 : 13))
        .copyWith(color: enabled ? (w.style?.color ?? colors.text) : colors.textMuted.withValues(alpha: 0.6));
    Widget label = DefaultTextStyle.merge(
      style: style,
      overflow: TextOverflow.ellipsis,
      child: selected?.child ?? w.hint ?? const SizedBox.shrink(),
    );
    final arrow = IconTheme.merge(
      data: IconThemeData(size: inDialog && k == null ? 18 : 16, color: k?.textPrimary ?? colors.textMuted),
      child: w.icon ?? Icon(AppIcon.select.of(context)),
    );
    Widget field = Row(mainAxisSize: w.isExpanded ? MainAxisSize.max : MainAxisSize.min, children: [
      if (w.isExpanded) Expanded(child: label) else Flexible(child: label),
      const SizedBox(width: 4),
      arrow,
    ]);
    if (inDialog) {
      field = Container(
        height: app.field,
        padding: EdgeInsets.symmetric(horizontal: app.fieldInset),
        color: fieldFill(context),
        // Over the field, not around it: a border in the decoration adds its width to the
        // padding, moving the text off [AppStyle.fieldInset] (and half a pixel more when open).
        foregroundDecoration: k != null
            ? BoxDecoration(
                border: _open
                    ? Border.all(color: k.focus, width: 2)
                    : Border(bottom: BorderSide(color: k.borderStrong)))
            : BoxDecoration(
                border: Border.all(color: _open ? colors.accent : colors.line, width: _open ? 1.5 : 1),
                borderRadius: BorderRadius.circular(8),
              ),
        child: field,
      );
    } else {
      field = Padding(padding: EdgeInsets.symmetric(vertical: w.dense ? 2 : 4), child: field);
    }
    // A dialog's menu is in the dialog's measures: 30 px rows (Carbon's small, 32), 14 px text.
    final dialogRow = MenuItemButton.styleFrom(
        minimumSize: Size(0, k != null ? 32 : 30),
        textStyle: theme.textTheme.bodyMedium!.copyWith(fontSize: 14, letterSpacing: k != null ? 0.16 : 0));
    // Carbon marks the chosen item with $layer-selected as well as its check.
    final chosenRow = k == null ? null : ButtonStyle(backgroundColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.hovered) || s.contains(WidgetState.pressed) ? null : k.layerSelected));
    final menu = MenuAnchor(
      controller: _menu,
      childFocusNode: _focus,
      onOpen: () => setState(() => _open = true),
      onClose: () => setState(() => _open = false),
      alignmentOffset: const Offset(0, 2),
      // The anchor's own panel is bare: [_MenuCard] draws the theme's, so it can fade in whole.
      clipBehavior: Clip.none,
      style: const MenuStyle(
        backgroundColor: WidgetStatePropertyAll(Colors.transparent),
        shadowColor: WidgetStatePropertyAll(Colors.transparent),
        elevation: WidgetStatePropertyAll(0),
        padding: WidgetStatePropertyAll(EdgeInsets.zero),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder()),
        visualDensity: VisualDensity.standard,
      ),
      menuChildren: [
        _MenuCard(
          minWidth: _width,
          children: [
            for (final item in w.items)
              MenuItemButton(
                style: switch ((inDialog ? dialogRow : null, item.value == w.value ? chosenRow : null)) {
                  (final row?, final chosen?) => chosen.merge(row),
                  (final row, final chosen) => row ?? chosen,
                },
                onPressed: item.enabled
                    ? () {
                        item.onTap?.call();
                        w.onChanged?.call(item.value);
                      }
                    : null,
                leadingIcon: SizedBox(
                  width: 16,
                  child: item.value == w.value ? Icon(AppIcon.check.of(context), size: 16, color: k?.textPrimary ?? colors.text) : null,
                ),
                child: item.child,
              ),
          ],
        ),
      ],
      child: InkWell(
        focusNode: _focus,
        onTap: enabled ? _toggle : null,
        borderRadius: app.radius(5),
        child: field,
      ),
    );
    return w.label == null ? menu : FieldLabel(label: w.label!, child: menu);
  }
}

/// A select as Settings shows one: an [AppDropdown] in a 32 px field with a border, and under
/// it [error] when there is one.
class SettingsDropdown<T> extends StatelessWidget {
  const SettingsDropdown(
      {super.key, required this.value, required this.items, required this.onChanged, this.width, this.error});
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T>? onChanged;

  /// The field's width; null: its value's.
  final double? width;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final k = CarbonColors.maybeOf(context);
    final onChanged = this.onChanged;
    // Carbon: a small (32 px) select, filled, a line under it.
    final field = Container(
      height: 32,
      width: width,
      padding: k != null ? const EdgeInsets.only(left: 16, right: 8) : const EdgeInsets.only(left: 10, right: 4),
      decoration: k != null
          ? BoxDecoration(color: k.field, border: Border(bottom: BorderSide(color: k.borderStrong)))
          : BoxDecoration(border: Border.all(color: colors.line), borderRadius: BorderRadius.circular(8)),
      child: AppDropdown<T>(
        value: value,
        dense: true,
        isExpanded: width != null,
        icon: Icon(AppIcon.select.of(context), size: 16, color: k?.textPrimary ?? colors.textMuted),
        style: k != null ? TextStyle(fontSize: 14, letterSpacing: 0.16, color: k.textPrimary) : TextStyle(fontSize: 13, color: colors.text),
        onChanged: onChanged == null ? null : (v) => v == null ? null : onChanged(v),
        items: items,
      ),
    );
    final error = this.error;
    if (error == null) return field;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      field,
      Padding(
        padding: EdgeInsets.only(left: k != null ? 0 : 10, top: 4),
        child: Text(error.tr, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error)),
      ),
    ]);
  }
}

/// The menu of an [AppDropdown]: the theme's menu panel, at least [minWidth] wide and at most
/// 320 px tall (it scrolls), fading in and settling 4 px down over [AppStyle.menuOpen].
class _MenuCard extends StatelessWidget {
  const _MenuCard({required this.minWidth, required this.children});
  final double minWidth;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final style = MenuTheme.of(context).style;
    const states = <WidgetState>{};
    final panel = Material(
      color: style?.backgroundColor?.resolve(states),
      elevation: style?.elevation?.resolve(states) ?? 8,
      shadowColor: style?.shadowColor?.resolve(states),
      surfaceTintColor: Colors.transparent,
      shape: style?.shape?.resolve(states),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: minWidth, maxHeight: 320),
        child: SingleChildScrollView(
          primary: false, // the anchor's panel has the primary controller
          padding: style?.padding?.resolve(states),
          child: IntrinsicWidth(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
          ),
        ),
      ),
    );
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AppStyle.of(context).menuOpen,
      curve: AppStyle.of(context).enterCurve,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (t - 1) * 4), child: child),
      ),
      child: panel,
    );
  }
}
