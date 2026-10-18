import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'ui_kit.dart';

/// The space between a dialog's groups of fields (a field is [AppStyle.field] tall, its label
/// over it).
double dialogGap(BuildContext context) => 16;

/// A dialog's row ([AppCheckRow]): a list in a dialog is this many rows tall.
double dialogRowHeight(BuildContext context) => AppStyle.of(context).row;

/// A dialog body's width for [base] px of content: a fifth more, as a dialog's padding and text
/// are larger than Material's.
double dialogWidth(BuildContext context, double base) => (base * 1.2).roundToDouble();

/// A dialog for the app: always use it rather than [AlertDialog].
///
/// A title, a body that scrolls when the window is short, and a footer with [leading] buttons at
/// its left, a [status] (a problem in what was typed) beside them, and the [actions] at its
/// right, the default one last. [divided] draws a hairline above the footer, for a body that is a
/// list or a table. [UiStyle.refined] sets it as a desktop editor does; [UiStyle.carbon] as
/// Carbon's modal: square, its footer's buttons 40 px tall and edge to edge at its right.
class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    required this.title,
    this.content,
    this.leading = const [],
    this.status,
    required this.actions,
    this.divided = false,
  });

  final Widget title;
  final Widget? content;
  final List<Widget> leading;
  final Widget? status;
  final List<Widget> actions;
  final bool divided;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final dialog = theme.dialogTheme;
    final carbon = AppStyle.of(context).isCarbon;
    final pad = carbon ? 16.0 : 24.0;
    final body = <Widget>[
      Padding(
        padding: carbon ? EdgeInsets.fromLTRB(pad, 16, 48, 0) : EdgeInsets.fromLTRB(pad, 22, pad, 6),
        child: DefaultTextStyle(style: dialog.titleTextStyle ?? theme.textTheme.titleLarge!, child: title),
      ),
      if (content != null)
        Flexible(
          child: SingleChildScrollView(
            // Carbon: 8 px under the heading, 48 over the footer.
            padding: carbon ? EdgeInsets.fromLTRB(pad, 8, pad, 48) : EdgeInsets.fromLTRB(pad, 10, pad, 18),
            child: DefaultTextStyle(style: dialog.contentTextStyle ?? theme.textTheme.bodyMedium!, child: content!),
          ),
        )
      else
        SizedBox(height: carbon ? 48 : 12),
      if (divided) Divider(height: 1, color: colors.line),
      if (carbon)
        _carbonFooter(context)
      else
        DialogButtons(
          child: Padding(
            padding: EdgeInsets.fromLTRB(pad, divided ? 16 : 0, pad, 20),
            child: Row(children: [
              ...leading,
              if (status != null)
                Expanded(child: _status(13, EdgeInsets.only(left: leading.isEmpty ? 0 : 12, right: 12)))
              else
                const Spacer(),
              for (final (i, action) in actions.indexed) ...[if (i > 0) const SizedBox(width: 8), action],
            ]),
          ),
        ),
    ];
    return Dialog(
      insetPadding: const EdgeInsets.all(32),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 380, maxWidth: 820),
        child: IntrinsicWidth(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: body),
        ),
      ),
    );
  }

  /// Carbon's modal footer, slim: [_footerHeight] tall, each action a quarter of the dialog wide
  /// (narrower when there are more than two beside [leading] or a [status], which take the rest),
  /// the default one at the right; [leading] as ghost buttons as tall as the footer.
  Widget _carbonFooter(BuildContext context) {
    final extras = leading.isNotEmpty || status != null;
    final slots = math.max(4, actions.length + (extras ? 2 : 0));
    final rest = slots - actions.length;
    return SizedBox(
      height: _footerHeight,
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (rest > 0)
          Expanded(
            flex: rest,
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              ...leading.map((b) => _FooterButtons(ghost: true, child: b)),
              if (status != null) Expanded(child: Align(alignment: Alignment.centerLeft, child: _status(14, const EdgeInsets.symmetric(horizontal: 16)))),
            ]),
          ),
        for (final action in actions) Expanded(child: _FooterButtons(child: action)),
      ]),
    );
  }

  /// The [status], in [size] px text, cut short to one line.
  Widget _status(double size, EdgeInsets padding) => Padding(
        padding: padding,
        child: DefaultTextStyle.merge(style: TextStyle(fontSize: size), overflow: TextOverflow.ellipsis, child: status!),
      );
}

/// Carbon's md button height, the modal footer's (its own spec has 64, which sits heavy here).
const _footerHeight = 40.0;

/// A Carbon modal's footer button: filling its slot, [_footerHeight] tall, its label at the left; a
/// secondary one ($button-secondary) for a text or outlined button, or with [ghost] a ghost one
/// as wide as its label.
class _FooterButtons extends StatelessWidget {
  const _FooterButtons({required this.child, this.ghost = false});
  final Widget child;
  final bool ghost;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final k = CarbonColors.maybeOf(context)!;
    final footer = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(ghost ? const Size(0, _footerHeight) : const Size.fromHeight(_footerHeight)),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16)),
      alignment: Alignment.centerLeft,
    );
    final secondary = footer.merge(_carbonSecondary(k)).merge(theme.filledButtonTheme.style);
    return Theme(
      data: theme.copyWith(
        filledButtonTheme: FilledButtonThemeData(style: footer.merge(theme.filledButtonTheme.style)),
        textButtonTheme:
            TextButtonThemeData(style: ghost ? footer.merge(theme.textButtonTheme.style) : secondary),
        outlinedButtonTheme: OutlinedButtonThemeData(style: secondary),
      ),
      child: child,
    );
  }
}

/// Carbon's secondary button: white on $button-secondary.
ButtonStyle _carbonSecondary(CarbonColors k) => ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled)
          ? k.buttonDisabled
          : s.contains(WidgetState.pressed)
              ? k.secondaryActive
              : s.contains(WidgetState.hovered)
                  ? k.secondaryHover
                  : k.secondary),
      foregroundColor:
          WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? k.onColorDisabled : Colors.white),
      side: const WidgetStatePropertyAll(BorderSide.none),
    );

/// A dialog's button: Refined's 34 px with a 14 px label (the theme's, which names the font);
/// Carbon's medium (40 px) button at the normal density.
ButtonStyle dialogButtonStyle(BuildContext context) {
  final label = Theme.of(context).textTheme.labelLarge!;
  if (AppStyle.of(context).isCarbon) {
    return ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
      padding: const WidgetStatePropertyAll(EdgeInsets.fromLTRB(15, 0, 63, 0)),
      textStyle: WidgetStatePropertyAll(label.copyWith(fontSize: 14, fontWeight: FontWeight.w400, letterSpacing: 0.16)),
    );
  }
  return ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(76, 34)),
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 18)),
    textStyle: WidgetStatePropertyAll(label.copyWith(fontSize: 14, fontWeight: FontWeight.w500, letterSpacing: 0)),
  );
}

/// A dialog's footer buttons: [dialogButtonStyle]'s size, and a text button (Cancel, an extra
/// action) outlined in Refined, so every button's edge, not its label, is where the dialog's
/// content starts and ends; Carbon's secondary button in Carbon.
class DialogButtons extends StatelessWidget {
  const DialogButtons({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final size = dialogButtonStyle(context);
    final k = CarbonColors.maybeOf(context);
    final outlined = k != null
        ? size.merge(_carbonSecondary(k)).merge(theme.filledButtonTheme.style)
        : size.merge(theme.outlinedButtonTheme.style);
    return Theme(
      data: theme.copyWith(
        textButtonTheme: TextButtonThemeData(
          style: k != null
              ? outlined
              : outlined.copyWith(
                  side: WidgetStateProperty.resolveWith((s) => BorderSide(
                      color: s.contains(WidgetState.disabled) ? colors.line.withValues(alpha: 0.6) : colors.line)),
                ),
        ),
        filledButtonTheme: FilledButtonThemeData(style: size.merge(theme.filledButtonTheme.style)),
        outlinedButtonTheme: OutlinedButtonThemeData(style: outlined),
      ),
      child: child,
    );
  }
}

/// A text field for a dialog: [AppStyle.field] tall under its label, a [helper] beneath it.
///
/// [bad] outlines it in red with no message (Carbon adds its warning icon): the usual way to say
/// a field doesn't read yet. An empty [label] draws none (a field in a row that names it).
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.helper,
    this.bad = false,
    this.autofocus = false,
    this.maxLength,
    this.keyboardType,
    this.inputFormatters,
    this.onChanged,
    this.onSubmitted,
    this.onTap,
    this.focusNode,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String label;
  final String? hint, helper;
  final bool bad;
  final bool autofocus;
  final int? maxLength;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final style = AppStyle.of(context);
    final k = CarbonColors.maybeOf(context);
    final borders = fieldBorders(context, bad: bad);
    final fill = fieldFill(context);
    final text = k == null ? const TextStyle(fontSize: 14) : TextStyle(fontSize: 14, letterSpacing: 0.16, color: k.textPrimary);
    final field = SizedBox(
        height: style.field,
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          autofocus: autofocus,
          maxLength: maxLength,
          keyboardType: keyboardType,
          inputFormatters: inputFormatters,
          onTap: onTap,
          // Proportional figures: a tabular 1 stands in a wide slot, its text looking indented.
          style: text,
          decoration: InputDecoration(
            isDense: true,
            filled: fill != null,
            fillColor: fill,
            hoverColor: k?.layerHover,
            hintText: hint,
            hintStyle: text.copyWith(color: k?.textPlaceholder ?? colors.textMuted.withValues(alpha: 0.6)),
            counterText: '',
            contentPadding: EdgeInsets.symmetric(horizontal: style.fieldInset, vertical: k == null ? 8 : 11),
            enabledBorder: borders.rest,
            focusedBorder: borders.focused,
            border: borders.rest,
            // Carbon's invalid field: its warning icon at the right.
            suffixIcon: k != null && bad ? Icon(AppIcon.invalid.of(context), size: 16, color: k.error) : null,
            suffixIconConstraints: const BoxConstraints.tightFor(width: 32, height: 16),
          ),
          onChanged: onChanged,
          onSubmitted: onSubmitted,
        ),
      );
    if (label.isEmpty && helper == null) return field;
    return FieldLabel(
      label: label,
      child: helper == null
          ? field
          : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              field,
              Padding(
                padding: EdgeInsets.only(top: k == null ? 5 : 4),
                child: Text(helper!,
                    style: k == null
                        ? TextStyle(fontSize: 12.5, color: colors.textMuted)
                        : TextStyle(fontSize: 12, height: 16 / 12, letterSpacing: 0.32, color: k.textHelper)),
              ),
            ]),
    );
  }
}

/// A [DropdownMenu] (a select that filters as it is typed in) as a dialog's field: an
/// [AppTextField]'s measures and borders, with the select's arrow. Build the menu with the
/// [decoration], [textStyle] and [arrow] given.
Widget dialogMenuField(
  BuildContext context, {
  required Widget Function(InputDecorationTheme decoration, TextStyle textStyle, Widget arrow) menu,
}) {
  final colors = context.colors;
  final style = AppStyle.of(context);
  final borders = fieldBorders(context);
  final fill = fieldFill(context);
  return IconButtonTheme(
    // The menu's arrow button no bigger than the field, so it sits in its middle.
    data: IconButtonThemeData(
      style: IconButton.styleFrom(
        padding: EdgeInsets.zero,
        minimumSize: const Size(24, 24),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
    ),
    child: menu(
      InputDecorationTheme(
        isDense: true,
        filled: fill != null,
        fillColor: fill,
        contentPadding: EdgeInsets.symmetric(horizontal: style.fieldInset, vertical: style.isCarbon ? 11 : 8),
        constraints: BoxConstraints.tightFor(height: style.field),
        suffixIconConstraints: BoxConstraints.tightFor(width: style.field, height: style.field),
        border: borders.rest,
        enabledBorder: borders.rest,
        focusedBorder: borders.focused,
      ),
      TextStyle(fontSize: 14, letterSpacing: style.isCarbon ? 0.16 : null),
      Icon(AppIcon.select.of(context), size: 16, color: style.isCarbon ? colors.text : colors.textMuted),
    ),
  );
}

/// A row of a list of choices: a checkbox and its [label], a [trailing] widget at the right;
/// [dialogRowHeight] tall, flush with the dialog's other content.
class AppCheckRow extends StatelessWidget {
  const AppCheckRow({
    super.key,
    required this.value,
    required this.onChanged,
    required this.label,
    this.tristate = false,
    this.bold = false,
    this.trailing,
  });

  /// Null is the middle state of a [tristate] row.
  final bool? value;
  final ValueChanged<bool?> onChanged;
  final String label;
  final bool tristate;
  final bool bold;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final style = bold ? const TextStyle(fontWeight: FontWeight.w600) : null;
    final carbon = AppStyle.of(context).isCarbon;
    Widget box = IgnorePointer(child: Checkbox(tristate: tristate, value: value, onChanged: (_) {}));
    // Carbon's checkbox is 16 px; Material's 18.
    if (carbon) box = Transform.scale(scale: 16 / 18, child: box);
    // Flush with the dialog's other content: no inset, and no hover tint that would need one.
    return InkWell(
      hoverColor: Colors.transparent,
      highlightColor: Colors.transparent,
      // As a checkbox goes: off, on, then (tristate) the middle, then off.
      onTap: () => onChanged(switch (value) { false => true, true => tristate ? null : false, null => false }),
      child: SizedBox(
        height: dialogRowHeight(context),
        child: Row(children: [
          SizedBox.square(dimension: 18, child: box),
          SizedBox(width: carbon ? 8 : 10),
          Expanded(child: Text(label, style: style, overflow: TextOverflow.ellipsis)),
          ?trailing,
        ]),
      ),
    );
  }
}

/// A small button that puts something in a field (a symbol): a [dialogRowHeight] outlined button.
class AppChip extends StatelessWidget {
  const AppChip({super.key, required this.label, required this.tooltip, required this.onPressed});
  final String label, tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final style = AppStyle.of(context);
    final edge = CarbonColors.maybeOf(context)?.borderSubtle ?? context.colors.line;
    return Tip(
      message: tooltip,
      child: InkWell(
        borderRadius: style.radius(8),
        onTap: onPressed,
        child: Container(
          width: 40,
          height: dialogRowHeight(context),
          alignment: Alignment.center,
          decoration: BoxDecoration(border: Border.all(color: edge), borderRadius: style.radius(8)),
          child: Text(label, style: const TextStyle(fontSize: 16)),
        ),
      ),
    );
  }
}
