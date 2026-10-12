import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'app_settings.dart';
import 'editor_controller.dart';
import 'engraving_settings.dart';
import 'menu_kit.dart';
import 'ui_kit.dart';

/// Engrave Option (at the foot of the Engraving page, after a warning): every Verovio option
/// that is safe to change ([EngraveOption.all]) by its code name, for those who know Verovio.
/// A change is saved at once (for every score) and re-engraves the open score (or the demo),
/// shown beside the list.
///
/// With [project] (Project Settings ▸ Engraving), the open project's own, over the app's: each
/// change an edit, a reset going back to the app's value.
Future<void> showEngraveOptionsDialog(BuildContext context, AppSettings settings,
        {EditorController? controller, bool project = false}) =>
    showAppDialog<void>(
      context: context,
      builder: (context) =>
          _EngraveOptionsDialog(target: EngravingTarget(settings, controller, project: project)),
    );

class _EngraveOptionsDialog extends StatefulWidget {
  const _EngraveOptionsDialog({required this.target});
  final EngravingTarget target;

  @override
  State<_EngraveOptionsDialog> createState() => _EngraveOptionsDialogState();
}

class _EngraveOptionsDialogState extends State<_EngraveOptionsDialog> {
  final _search = TextEditingController();

  EngravingTarget get target => widget.target;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final size = MediaQuery.sizeOf(context);
    final c = target.controller;
    return Dialog(
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.all(32),
      child: ListenableBuilder(
        listenable: Listenable.merge([target.settings, _search, ?c]),
        builder: (context, _) {
          return SizedBox(
            width: math.min(1200, size.width - 64),
            height: (size.height - 64).clamp(360, 760),
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(width: 400, child: _list(context)),
              VerticalDivider(width: 1, color: colors.line),
              // The open score, or the demo.
              Expanded(child: EngravingPreviewHost(settings: target.settings, controller: c)),
            ]),
          );
        },
      ),
    );
  }

  Widget _list(BuildContext context) {
    final colors = context.colors;
    final q = _search.text.trim().toLowerCase();
    final shown = [for (final o in EngraveOption.all) if (o.key.toLowerCase().contains(q)) o];
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: colors.line));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        child: Row(children: [
          Expanded(
            child: SizedBox(
              height: 30,
              child: TextField(
                controller: _search,
                style: const TextStyle(fontSize: 12.5),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Search',
                  prefixIcon: Icon(Icons.search, size: 15, color: colors.textMuted),
                  prefixIconConstraints: const BoxConstraints(minWidth: 30),
                  contentPadding: const EdgeInsets.symmetric(vertical: 7),
                  border: border,
                  enabledBorder: border,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.restart_alt_rounded, size: 18),
            tooltip: 'Reset All',
            onPressed: target.own.isEmpty ? null : () => target.own = const EngravingOptions(),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 18),
            tooltip: 'Close',
            onPressed: () => Navigator.pop(context),
          ),
        ]),
      ),
      Divider(height: 1, color: colors.line),
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: shown.length,
          itemBuilder: (context, i) {
            final option = shown[i];
            return _OptionRow(
              option: option,
              value: target.valueOf(option),
              changed: target.isChanged(option),
              // The house style's, or in a project the app's.
              base: '${target.project ? 'app' : 'default'} ${formatOptionValue(target.baseOf(option))}',
              onChanged: (v) => target.set(option, v),
            );
          },
        ),
      ),
    ]);
  }
}

/// One option: its code name, its value, and a reset once changed.
class _OptionRow extends StatelessWidget {
  const _OptionRow(
      {required this.option, required this.value, required this.changed, required this.base, required this.onChanged});
  final EngraveOption option;
  final Object value;
  final bool changed;

  /// What a reset goes back to, as the hover text says it ("default 0.62").
  final String base;
  final ValueChanged<Object?> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final control = switch (option.kind) {
      EngraveOptionKind.number || EngraveOptionKind.integer =>
        _NumberField(option: option, value: value as num, onChanged: onChanged),
      EngraveOptionKind.toggle => SizedBox(
          height: 28,
          child: AppSwitch(value: value as bool, onChanged: onChanged),
        ),
      EngraveOptionKind.choice => AppDropdown<String>(
          value: value as String,
          dense: true,
          style: TextStyle(fontSize: 12.5, color: colors.text),
          items: [for (final c in option.choices) DropdownMenuItem(value: c, child: Text(c))],
          onChanged: onChanged,
        ),
    };
    final range = switch (option.kind) {
      EngraveOptionKind.number || EngraveOptionKind.integer =>
        '${formatOptionValue(option.min!)}–${formatOptionValue(option.max!)}, ',
      _ => '',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 1, 4, 1),
      child: Row(children: [
        Expanded(
          child: Tip(
            message: '$range$base',
            waitDuration: const Duration(milliseconds: 500),
            child: Text(
              option.key,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'Menlo',
                fontFamilyFallback: const ['Consolas', 'DejaVu Sans Mono', 'monospace'],
                fontWeight: changed ? FontWeight.w600 : FontWeight.normal,
                color: changed ? colors.accentStrong : colors.text,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        control,
        SizedBox(
          width: 32,
          child: changed
              ? IconButton(
                  icon: const Icon(Icons.restart_alt_rounded, size: 15),
                  tooltip: 'Reset',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onChanged(null),
                )
              : null,
        ),
      ]),
    );
  }
}

/// A number typed in: taken (and clamped into range) on Return or when focus leaves; anything
/// unreadable puts the value back.
class _NumberField extends StatefulWidget {
  const _NumberField({required this.option, required this.value, required this.onChanged});
  final EngraveOption option;
  final num value;
  final ValueChanged<Object?> onChanged;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final _text = TextEditingController(text: formatOptionValue(widget.value));
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(_NumberField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && !_focus.hasFocus) _text.text = formatOptionValue(widget.value);
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    final typed = num.tryParse(_text.text.trim().replaceAll(',', '.'));
    final value = typed == null ? null : widget.option.coerce(typed);
    if (value != null && value != widget.value) widget.onChanged(value);
    _text.text = formatOptionValue(value ?? widget.value);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(5), borderSide: BorderSide(color: colors.line));
    return SizedBox(
      width: 64,
      height: 26,
      child: TextField(
        controller: _text,
        focusNode: _focus,
        textAlign: TextAlign.right,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        style: const TextStyle(fontSize: 12.5),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
          border: border,
          enabledBorder: border,
        ),
        onSubmitted: (_) => _commit(),
      ),
    );
  }
}
