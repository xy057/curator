import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'app_colors.dart';
import 'ui_kit.dart';

/// How long a [UiStyle.refined] menu takes to open, and to close.
const menuOpenDuration = Duration(milliseconds: 190);
const menuCloseDuration = Duration(milliseconds: 120);

/// A row of a [UiStyle.refined] menu (the material ones are 48 px; a macOS menu's are 22).
const refinedMenuRow = 22.0;

/// A popup menu's row: 48 px in [UiStyle.classic], a desktop menu's in [UiStyle.refined].
double menuRowHeight(BuildContext context) => isRefined(context) ? refinedMenuRow : kMinInteractiveDimension;

const _refinedItemPadding = EdgeInsets.symmetric(horizontal: 8);

/// A [PopupMenuItem] at [menuRowHeight]. Use it, not the item itself, in a menu.
PopupMenuItem<T> menuItem<T>(BuildContext context, {T? value, bool enabled = true, required Widget child}) =>
    PopupMenuItem<T>(
      value: value,
      enabled: enabled,
      height: menuRowHeight(context),
      padding: isRefined(context) ? _refinedItemPadding : null,
      child: child,
    );

/// A [PopupMenuDivider] with the space of a [menuRowHeight]'s row.
PopupMenuDivider menuDivider(BuildContext context) => PopupMenuDivider(height: isRefined(context) ? 9 : 16);

/// A checked item at [menuRowHeight]. [UiStyle.refined] draws its own: the material one is a
/// list tile, 40 px at the least however its theme is set.
PopupMenuItem<T> checkedMenuItem<T>(BuildContext context,
    {required T value, required bool checked, required Widget child}) {
  if (!isRefined(context)) return CheckedPopupMenuItem<T>(value: value, checked: checked, child: child);
  return PopupMenuItem<T>(
    value: value,
    height: menuRowHeight(context),
    padding: _refinedItemPadding,
    child: Semantics(
      role: SemanticsRole.menuItemCheckbox,
      checked: checked,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 16, child: checked ? const Icon(Icons.done, size: 16) : null),
        const SizedBox(width: 6),
        child,
      ]),
    ),
  );
}

/// A [PopupMenuButton] that opens in [menuOpenDuration] and shuts in [menuCloseDuration] in
/// [UiStyle.refined] (the material menu takes 300 ms), its rows set close. Fill it with
/// [menuItem] and [checkedMenuItem].
class AppPopupMenuButton<T> extends StatelessWidget {
  const AppPopupMenuButton({
    super.key,
    required this.itemBuilder,
    this.onSelected,
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
      tooltip: tooltip,
      position: position,
      style: style,
      icon: icon,
      iconSize: iconSize,
      padding: padding,
      constraints: constraints,
      popUpAnimationStyle: isRefined(context)
          ? AnimationStyle(
              duration: menuOpenDuration,
              reverseDuration: menuCloseDuration,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeIn,
            )
          : null,
      child: child,
    );
  }
}

/// A select for the app. [UiStyle.classic] is the material [DropdownButton] (a form field, with a
/// [label]); [UiStyle.refined] is a field whose menu of [MenuItemButton]s, 22 px rows, fades in
/// over [menuOpenDuration] (the material dropdown's rows are 48 px, its menu 300 ms).
///
/// With a [label] it is a labelled field (the label over it in Refined). Without, it is bare:
/// [boxed] outlines it (the material one underlines it), and [icon] replaces its arrow. Boxed or
/// labelled, it is a dialog's field in Refined: 36 px, 14 px text.
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
    if (!isRefined(context)) {
      if (w.label != null) {
        return DropdownButtonFormField<T>(
          initialValue: w.value,
          isExpanded: w.isExpanded,
          decoration: InputDecoration(labelText: w.label),
          items: w.items,
          onChanged: w.onChanged,
        );
      }
      return DropdownButton<T>(
        value: w.value,
        hint: w.hint,
        isExpanded: w.isExpanded,
        isDense: w.dense,
        icon: w.icon ?? const Icon(Icons.arrow_drop_down),
        style: w.style,
        focusColor: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        underline: w.boxed ? null : const SizedBox.shrink(),
        items: w.items,
        onChanged: w.onChanged,
      );
    }
    final colors = context.colors;
    final theme = Theme.of(context);
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
      data: IconThemeData(size: inDialog ? 18 : 16, color: colors.textMuted),
      child: w.icon ?? const Icon(Icons.unfold_more_rounded),
    );
    Widget field = Row(mainAxisSize: w.isExpanded ? MainAxisSize.max : MainAxisSize.min, children: [
      if (w.isExpanded) Expanded(child: label) else Flexible(child: label),
      const SizedBox(width: 4),
      arrow,
    ]);
    if (inDialog) {
      field = Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          border: Border.all(color: _open ? colors.accent : colors.line, width: _open ? 1.5 : 1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: field,
      );
    } else {
      field = Padding(padding: EdgeInsets.symmetric(vertical: w.dense ? 2 : 4), child: field);
    }
    final dialogRow = MenuItemButton.styleFrom(
        minimumSize: const Size(0, 30), textStyle: theme.textTheme.bodyMedium!.copyWith(fontSize: 14, letterSpacing: 0));
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
                // A dialog's menu is in the dialog's measures: 30 px rows, 14 px text.
                style: inDialog ? dialogRow : null,
                onPressed: item.enabled
                    ? () {
                        item.onTap?.call();
                        w.onChanged?.call(item.value);
                      }
                    : null,
                leadingIcon: SizedBox(
                  width: 16,
                  child: item.value == w.value ? Icon(Icons.done, size: 16, color: colors.text) : null,
                ),
                child: item.child,
              ),
          ],
        ),
      ],
      child: InkWell(
        focusNode: _focus,
        onTap: enabled ? _toggle : null,
        borderRadius: BorderRadius.circular(5),
        child: field,
      ),
    );
    return w.label == null ? menu : FieldLabel(label: w.label!, child: menu);
  }
}

/// The menu of an [AppDropdown]: the theme's menu panel, at least [minWidth] wide and at most
/// 320 px tall (it scrolls), fading in and settling 4 px down over [menuOpenDuration].
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
      duration: menuOpenDuration,
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (t - 1) * 4), child: child),
      ),
      child: panel,
    );
  }
}
