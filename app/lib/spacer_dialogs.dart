import 'package:flutter/material.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'dialog_kit.dart';
import 'editor_controller.dart';
import 'menu_kit.dart';
import 'ui_kit.dart';

/// A vertical spacer's name, transposition, height, staff lines and whether the name and clef
/// show at the left; Remove takes it out.
Future<void> showVerticalSpacerDialog(BuildContext context, EditorController c, String id) =>
    showAppDialog<void>(context: context, builder: (context) => _VerticalSpacerDialog(controller: c, id: id));

class _VerticalSpacerDialog extends StatefulWidget {
  const _VerticalSpacerDialog({required this.controller, required this.id});
  final EditorController controller;
  final String id;

  @override
  State<_VerticalSpacerDialog> createState() => _VerticalSpacerDialogState();
}

class _VerticalSpacerDialogState extends State<_VerticalSpacerDialog> {
  EditorController get c => widget.controller;
  late final VerticalSpacer _spacer = c.spacers.verticalOf(widget.id)!;
  late final ScorePart? _part = c.score!.metadata.parts.where((p) => p.id == widget.id).firstOrNull;
  late final _name = TextEditingController(text: _part == null ? Spacers.nameOf(widget.id) : c.partName(_part));
  late final _height = TextEditingController(text: _number(_spacer.height));
  late SpacerKey _key = _spacer.key;
  late bool _lines = _spacer.lines, _frozen = _spacer.frozen;

  @override
  void dispose() {
    _name.dispose();
    _height.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final height = double.tryParse(_height.text.trim());
    final error = height == null || height < VerticalSpacer.minHeight || height > VerticalSpacer.maxHeight
        ? 'Enter ${_number(VerticalSpacer.minHeight)} to ${_number(VerticalSpacer.maxHeight)} staff spaces'
        : null;
    void save() {
      if (error != null) return;
      final part = _part;
      c.beginEdit(); // one Undo step
      if (part != null && _name.text.trim() != c.partName(part)) c.renamePart(part, name: _name.text, abbreviation: c.partAbbreviation(part));
      c.spacers.setVertical(_spacer.copyWith(key: _key, lines: _lines, frozen: _frozen, height: height));
      c.endEdit();
      Navigator.pop(context);
    }

    return AppDialog(
      title: const Text('Vertical Spacer'),
      content: SizedBox(
        width: dialogWidth(context, 360),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AppTextField(controller: _name, label: 'Name', autofocus: true, onSubmitted: (_) => save()),
          SizedBox(height: dialogGap(context)),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: AppDropdown<SpacerKey>(
                value: _key,
                isExpanded: true,
                label: 'Transposition',
                items: [
                  for (final k in SpacerKey.values)
                    DropdownMenuItem(value: k, child: Text(k == SpacerKey.c ? 'Concert pitch' : 'In ${k.label}')),
                ],
                onChanged: (k) => setState(() => _key = k ?? _key),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: AppTextField(
                controller: _height,
                label: 'Height (staff spaces)',
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => save(),
              ),
            ),
          ]),
          SizedBox(height: dialogGap(context)),
          AppCheckRow(value: _lines, onChanged: (on) => setState(() => _lines = on ?? false), label: 'Staff lines'),
          AppCheckRow(value: _frozen, onChanged: (on) => setState(() => _frozen = on ?? false), label: 'Name and clef'),
        ]),
      ),
      status: error == null ? null : Text(error, style: TextStyle(color: context.colors.erase)),
      leading: [
        TextButton(
          onPressed: () {
            c.spacers.removeVertical(widget.id);
            Navigator.pop(context);
          },
          child: const Text('Remove'),
        ),
      ],
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: error == null ? save : null, child: const Text('Apply')),
      ],
    );
  }
}

/// Horizontal spacer [index]'s width; Remove closes it.
Future<void> showHorizontalSpacerDialog(BuildContext context, EditorController c, int index) =>
    showAppDialog<void>(context: context, builder: (context) => _HorizontalSpacerDialog(controller: c, index: index));

class _HorizontalSpacerDialog extends StatefulWidget {
  const _HorizontalSpacerDialog({required this.controller, required this.index});
  final EditorController controller;
  final int index;

  @override
  State<_HorizontalSpacerDialog> createState() => _HorizontalSpacerDialogState();
}

class _HorizontalSpacerDialogState extends State<_HorizontalSpacerDialog> {
  EditorController get c => widget.controller;
  late final _width = TextEditingController(text: _number(c.spacers.horizontal[widget.index].width));

  @override
  void dispose() {
    _width.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = double.tryParse(_width.text.trim());
    final error = width == null || width < HorizontalSpacer.minWidth || width > HorizontalSpacer.maxWidth
        ? 'Enter ${_number(HorizontalSpacer.minWidth)} to ${_number(HorizontalSpacer.maxWidth)} staff spaces'
        : null;
    void save() {
      if (error != null) return;
      c.spacers.setHorizontalWidth(widget.index, width!);
      Navigator.pop(context);
    }

    return AppDialog(
      title: const Text('Horizontal Spacer'),
      content: SizedBox(
        width: dialogWidth(context, 280),
        child: AppTextField(
          controller: _width,
          label: 'Width (staff spaces)',
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => save(),
        ),
      ),
      status: error == null ? null : Text(error, style: TextStyle(color: context.colors.erase)),
      leading: [
        TextButton(
          onPressed: () {
            c.spacers.removeHorizontal(widget.index);
            Navigator.pop(context);
          },
          child: const Text('Remove'),
        ),
      ],
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: error == null ? save : null, child: const Text('Apply')),
      ],
    );
  }
}

/// [v] without a trailing ".0".
String _number(double v) => v == v.roundToDouble() ? '${v.round()}' : '$v';
