import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'ui_kit.dart';

/// [UiStyle.refined], and the theme has the app's palette (a bare [MaterialApp] hasn't: the
/// material widgets then).
bool _refined(BuildContext context) => isRefined(context) && Theme.of(context).extension<AppColors>() != null;

/// A dialog for the app: always use it rather than [AlertDialog].
///
/// [UiStyle.classic] is the material [AlertDialog]. [UiStyle.refined] sets it as a desktop editor
/// does: a small title, a body that scrolls when the window is short, and a footer with [leading]
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
    if (!_refined(context)) {
      return AlertDialog(
        title: title,
        content: content,
        contentPadding: contentPadding,
        actionsPadding: actionsPadding,
        actions: [
          if (leading.isEmpty) ...[
            if (status != null) Padding(padding: const EdgeInsets.only(right: 8), child: status),
            ...actions,
          ] else
            // The material actions are all at the right: a row of them spreads leading to the left.
            Row(children: [
              ...leading,
              const Spacer(),
              if (status != null) Flexible(child: Padding(padding: const EdgeInsets.only(right: 8), child: status)),
              for (final (i, action) in actions.indexed) ...[if (i > 0) const SizedBox(width: 8), action],
            ]),
        ],
      );
    }
    final theme = Theme.of(context);
    final colors = context.colors;
    final dialog = theme.dialogTheme;
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 320, maxWidth: 720),
        child: IntrinsicWidth(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: DefaultTextStyle(style: dialog.titleTextStyle ?? theme.textTheme.titleLarge!, child: title),
            ),
            if (content != null)
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: DefaultTextStyle(style: dialog.contentTextStyle ?? theme.textTheme.bodyMedium!, child: content!),
                ),
              )
            else
              const SizedBox(height: 8),
            if (divided) Divider(height: 1, color: colors.line),
            Padding(
              padding: EdgeInsets.fromLTRB(12, divided ? 10 : 6, 12, 12),
              child: Row(children: [
                ...leading,
                if (status != null)
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(left: leading.isEmpty ? 4 : 8, right: 8),
                      child: DefaultTextStyle.merge(style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis, child: status!),
                    ),
                  )
                else
                  const Spacer(),
                for (final (i, action) in actions.indexed) ...[if (i > 0) const SizedBox(width: 8), action],
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// A text field for a dialog. [UiStyle.classic] is the material outlined field with a floating
/// [label]; [UiStyle.refined] a 28 px field under its label, a [helper] beneath it.
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
    final colors = context.colors;
    final error = colors.erase;
    if (!_refined(context)) {
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
    OutlineInputBorder border(Color color, [double width = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(5), borderSide: BorderSide(color: color, width: width));
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: colors.textMuted)),
      ),
      SizedBox(
        height: 28,
        child: TextField(
          controller: controller,
          autofocus: autofocus,
          maxLength: maxLength,
          keyboardType: keyboardType,
          inputFormatters: inputFormatters,
          onTap: onTap,
          style: const TextStyle(fontSize: 13, fontFeatures: [FontFeature.tabularFigures()]),
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            hintStyle: TextStyle(fontSize: 13, color: colors.textMuted.withValues(alpha: 0.6)),
            counterText: '',
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            enabledBorder: border(bad ? error : colors.line),
            focusedBorder: border(bad ? error : colors.accent, 1.5),
            border: border(colors.line),
          ),
          onChanged: onChanged,
          onSubmitted: onSubmitted,
        ),
      ),
      if (helper != null)
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(helper!, style: TextStyle(fontSize: 11.5, color: colors.textMuted)),
        ),
    ]);
  }
}

/// A row of a list of choices: a checkbox and its [label], a [trailing] widget at the right.
/// [UiStyle.classic] is the material [CheckboxListTile]; [UiStyle.refined] a 26 px row.
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
    if (!_refined(context)) {
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
    return InkWell(
      borderRadius: BorderRadius.circular(5),
      onTap: () => onChanged(tristate ? (value == null ? true : (value! ? false : null)) : !(value ?? false)),
      child: SizedBox(
        height: 26,
        child: Row(children: [
          const SizedBox(width: 4),
          IgnorePointer(child: Checkbox(tristate: tristate, value: value, onChanged: (_) {})),
          const SizedBox(width: 6),
          Expanded(child: Text(label, style: style, overflow: TextOverflow.ellipsis)),
          ?trailing,
        ]),
      ),
    );
  }
}

/// A small button that puts something in a field (a symbol): [UiStyle.classic] a material
/// [ActionChip], [UiStyle.refined] a 26 px outlined button.
class AppChip extends StatelessWidget {
  const AppChip({super.key, required this.label, required this.tooltip, required this.onPressed});
  final String label, tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (!_refined(context)) return ActionChip(label: Text(label), tooltip: tooltip, onPressed: onPressed);
    return Tip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(5),
        onTap: onPressed,
        child: Container(
          width: 32,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(border: Border.all(color: context.colors.line), borderRadius: BorderRadius.circular(5)),
          child: Text(label, style: const TextStyle(fontSize: 14)),
        ),
      ),
    );
  }
}
