import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'ui_kit.dart';

/// A dialog's own measures in [UiStyle.refined]: roomier than the toolbars' (28 px controls, 13 px
/// text), since a dialog is read and filled in, not scanned.
const _fieldHeight = 36.0, _buttonHeight = 34.0, _pad = 24.0;

/// The space between a dialog's groups of fields: 16 px in [UiStyle.refined] (a field is 36,
/// its label over it), the material dialogs' 12 in [UiStyle.classic].
double dialogGap(BuildContext context) => isRefined(context) ? 16 : 12;

/// An [AppCheckRow]'s height in [UiStyle.refined]: a list in a dialog is this many rows tall.
const dialogRowHeight = 34.0;

/// A dialog body's width: [classic] px in [UiStyle.classic], a fifth more in [UiStyle.refined],
/// whose padding and text are larger.
double dialogWidth(BuildContext context, double classic) => isRefined(context) ? (classic * 1.2).roundToDouble() : classic;

/// A dialog for the app: always use it rather than [AlertDialog].
///
/// [UiStyle.classic] is the material [AlertDialog]. [UiStyle.refined] sets it as a desktop editor
/// does: a title, a body that scrolls when the window is short, and a footer with [leading]
/// buttons at its left, a [status] (a problem in what was typed) beside them, and the [actions]
/// at its right, the default one last. [divided] draws a hairline above the footer, for a body that
/// is a list or a table.
class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    required this.title,
    this.content,
    this.leading = const [],
    this.status,
    required this.actions,
    this.divided = false,
    this.contentPadding,
    this.actionsPadding,
  });

  final Widget title;
  final Widget? content;
  final List<Widget> leading;
  final Widget? status;
  final List<Widget> actions;
  final bool divided;

  /// [UiStyle.classic]'s paddings (the material ones, when null).
  final EdgeInsetsGeometry? contentPadding, actionsPadding;

  @override
  Widget build(BuildContext context) {
    if (!isRefined(context)) {
      return AlertDialog(
        title: title,
        content: content,
        contentPadding: contentPadding,
        actionsPadding: actionsPadding,
        actions: [
          if (leading.isEmpty) ...[
            if (status != null) _status(12, const EdgeInsets.only(right: 8)),
            ...actions,
          ] else
            // The material actions are all at the right: a row of them spreads leading to the left.
            Row(children: [
              ...leading,
              const Spacer(),
              if (status != null) Flexible(child: _status(12, const EdgeInsets.only(right: 8))),
              for (final (i, action) in actions.indexed) ...[if (i > 0) const SizedBox(width: 8), action],
            ]),
        ],
      );
    }
    final theme = Theme.of(context);
    final colors = context.colors;
    final dialog = theme.dialogTheme;
    return Dialog(
      insetPadding: const EdgeInsets.all(32),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 380, maxWidth: 820),
        child: IntrinsicWidth(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(_pad, 22, _pad, 6),
              child: DefaultTextStyle(style: dialog.titleTextStyle ?? theme.textTheme.titleLarge!, child: title),
            ),
            if (content != null)
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(_pad, 10, _pad, 18),
                  child: DefaultTextStyle(style: dialog.contentTextStyle ?? theme.textTheme.bodyMedium!, child: content!),
                ),
              )
            else
              const SizedBox(height: 12),
            if (divided) Divider(height: 1, color: colors.line),
            DialogButtons(
              child: Padding(
                padding: EdgeInsets.fromLTRB(_pad, divided ? 16 : 0, _pad, 20),
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
          ]),
        ),
      ),
    );
  }

  /// The [status], in [size] px text, cut short to one line.
  Widget _status(double size, EdgeInsets padding) => Padding(
        padding: padding,
        child: DefaultTextStyle.merge(style: TextStyle(fontSize: size), overflow: TextOverflow.ellipsis, child: status!),
      );
}

/// A dialog's button: 34 px, its label 14 px (the theme's, which names the font).
ButtonStyle dialogButtonStyle(BuildContext context) => ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(76, _buttonHeight)),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 18)),
      textStyle: WidgetStatePropertyAll(
          Theme.of(context).textTheme.labelLarge!.copyWith(fontSize: 14, fontWeight: FontWeight.w500, letterSpacing: 0)),
    );

/// A dialog's footer buttons in [UiStyle.refined]: [dialogButtonStyle]'s size, and a text button
/// (Cancel, an extra action) outlined, so every button's edge, not its label, is where the
/// dialog's content starts and ends.
class DialogButtons extends StatelessWidget {
  const DialogButtons({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!isRefined(context)) return child;
    final theme = Theme.of(context);
    final colors = context.colors;
    final size = dialogButtonStyle(context);
    final outlined = size.merge(theme.outlinedButtonTheme.style);
    return Theme(
      data: theme.copyWith(
        textButtonTheme: TextButtonThemeData(
          style: outlined.copyWith(
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

/// A text field for a dialog. [UiStyle.classic] is the material outlined field with a floating
/// [label]; [UiStyle.refined] a 36 px field under its label, a [helper] beneath it.
///
/// [bad] outlines it in red with no message: the usual way to say a field doesn't read yet.
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
  });

  final TextEditingController controller;
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
    if (!isRefined(context)) {
      return TextField(
        controller: controller,
        autofocus: autofocus,
        maxLength: maxLength,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        onTap: onTap,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: helper,
          counterText: maxLength == null ? null : '',
          errorText: bad ? '' : null,
          errorStyle: const TextStyle(height: 0, fontSize: 0),
        ),
        onChanged: onChanged,
        onSubmitted: onSubmitted,
      );
    }
    final colors = context.colors;
    final error = colors.erase;
    // No gap: it is room for a floating label (the label is over the field), and it moves the
    // text 4 px further in than [fieldInset].
    OutlineInputBorder border(Color color, [double width = 1]) => OutlineInputBorder(
        gapPadding: 0, borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: color, width: width));
    final field = SizedBox(
        height: _fieldHeight,
        child: TextField(
          controller: controller,
          autofocus: autofocus,
          maxLength: maxLength,
          keyboardType: keyboardType,
          inputFormatters: inputFormatters,
          onTap: onTap,
          // Proportional figures: a tabular 1 stands in a wide slot, its text looking indented.
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            hintStyle: TextStyle(fontSize: 14, color: colors.textMuted.withValues(alpha: 0.6)),
            counterText: '',
            contentPadding: const EdgeInsets.symmetric(horizontal: fieldInset, vertical: 8),
            enabledBorder: border(bad ? error : colors.line),
            focusedBorder: border(bad ? error : colors.accent, 1.5),
            border: border(colors.line),
          ),
          onChanged: onChanged,
          onSubmitted: onSubmitted,
        ),
      );
    return FieldLabel(
      label: label,
      child: helper == null
          ? field
          : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              field,
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Text(helper!, style: TextStyle(fontSize: 12.5, color: colors.textMuted)),
              ),
            ]),
    );
  }
}

/// A row of a list of choices: a checkbox and its [label], a [trailing] widget at the right.
/// [UiStyle.classic] is the material [CheckboxListTile]; [UiStyle.refined] a 34 px row.
class AppCheckRow extends StatelessWidget {
  const AppCheckRow({
    super.key,
    required this.value,
    required this.onChanged,
    required this.label,
    this.tristate = false,
    this.bold = false,
    this.trailing,
    this.indent = false,
  });

  /// Null is the middle state of a [tristate] row.
  final bool? value;
  final ValueChanged<bool?> onChanged;
  final String label;
  final bool tristate;
  final bool bold;
  final Widget? trailing;

  /// [UiStyle.classic] only: the list tile's own padding, not none.
  final bool indent;

  @override
  Widget build(BuildContext context) {
    final style = bold ? const TextStyle(fontWeight: FontWeight.w600) : null;
    if (!isRefined(context)) {
      return CheckboxListTile(
        dense: true,
        contentPadding: indent ? null : EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        tristate: tristate,
        value: value,
        onChanged: onChanged,
        title: Text(label, style: style),
        secondary: trailing,
      );
    }
    // Flush with the dialog's other content: no inset, and no hover tint that would need one.
    return InkWell(
      hoverColor: Colors.transparent,
      highlightColor: Colors.transparent,
      // As a checkbox goes: off, on, then (tristate) the middle, then off.
      onTap: () => onChanged(switch (value) { false => true, true => tristate ? null : false, null => false }),
      child: SizedBox(
        height: dialogRowHeight,
        child: Row(children: [
          SizedBox.square(
            dimension: 18,
            child: IgnorePointer(child: Checkbox(tristate: tristate, value: value, onChanged: (_) {})),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: style, overflow: TextOverflow.ellipsis)),
          ?trailing,
        ]),
      ),
    );
  }
}

/// A small button that puts something in a field (a symbol): [UiStyle.classic] a material
/// [ActionChip], [UiStyle.refined] a 34 px outlined button.
class AppChip extends StatelessWidget {
  const AppChip({super.key, required this.label, required this.tooltip, required this.onPressed});
  final String label, tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (!isRefined(context)) return ActionChip(label: Text(label), tooltip: tooltip, onPressed: onPressed);
    return Tip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onPressed,
        child: Container(
          width: 40,
          height: dialogRowHeight,
          alignment: Alignment.center,
          decoration: BoxDecoration(border: Border.all(color: context.colors.line), borderRadius: BorderRadius.circular(8)),
          child: Text(label, style: const TextStyle(fontSize: 16)),
        ),
      ),
    );
  }
}
