import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'dialog_kit.dart';
import 'editor_controller.dart';
import 'menu_kit.dart';
import 'ui_kit.dart';

/// Project Settings ▸ Condensing, as in Dorico (Layout Options ▸ Condensing and Edit
/// Condensing Groups): which pairs of players share a staff, and pairs of the user's own
/// (Flute 1 + Oboe 1, Horn 1 + 3). Every change is made at once, as its own Undo step. The
/// only place condensing is chosen. The pairs fill the space it is given and scroll; adding
/// one stays under them.
class CondensingEditor extends StatefulWidget {
  const CondensingEditor({super.key, required this.controller});
  final EditorController controller;

  @override
  State<CondensingEditor> createState() => _CondensingEditorState();
}

class _CondensingEditorState extends State<CondensingEditor> {
  EditorController get c => widget.controller;

  /// The pair being made.
  String? _first, _second;

  /// Players free to pair: those with a partner who isn't already in a pair of the user's.
  List<String> _free([String? partnerOf]) {
    final taken = {for (final p in c.pairs) ...p.partIds};
    return [
      for (final part in c.score!.metadata.parts)
        if (!taken.contains(part.id) &&
            (partnerOf == null
                ? c.partnersOf(part.id).any((id) => !taken.contains(id))
                : c.partnersOf(partnerOf).contains(part.id)))
          part.id,
    ];
  }

  void _add() {
    c.addPair(_first!, _second!);
    setState(() => _first = _second = null);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        if (c.score == null) return const SizedBox.shrink();
        final colors = context.colors;
        final muted = TextStyle(fontSize: AppStyle.of(context).isCarbon ? 12 : 13, color: colors.textMuted);
        final pairs = c.condensable;
        final firsts = _free();
        if (!firsts.contains(_first)) _first = null;
        final seconds = _first == null ? const <String>[] : _free(_first);
        if (!seconds.contains(_second)) _second = null;

        AppDropdown<String> choose(String hint, String? value, List<String> ids, ValueChanged<String?> onChanged) =>
            AppDropdown<String>(
              isExpanded: true,
              boxed: true,
              hint: Text(hint),
              value: value,
              items: [for (final id in ids) DropdownMenuItem(value: id, child: Text(c.partNameOf(id)))],
              onChanged: ids.isEmpty ? null : onChanged,
            );

        // Adding a pair takes its players out of the built-in pairs they are in: say so first.
        final split = [
          for (final p in pairs)
            if (!c.pairs.contains(p) && (p.contains(_first ?? '') || p.contains(_second ?? '')) && _second != null) p,
        ];
        final condensed = pairs.where((p) => c.condensed.contains(p.id)).length;

        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Selected pairs share a staff.', style: muted),
              const SizedBox(height: 8),
              if (pairs.isEmpty)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(firsts.isEmpty ? 'No players in this score can share a staff.' : 'No pairs. Add one below.'),
                  ),
                )
              else ...[
                if (pairs.length > 1)
                  AppCheckRow(
                    tristate: true,
                    bold: true,
                    value: condensed == 0 ? false : (condensed == pairs.length ? true : null),
                    onChanged: (_) => c.setCondensed([for (final p in pairs) p.id], on: condensed < pairs.length),
                    label: 'All pairs',
                  ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final pair in pairs)
                        AppCheckRow(
                          value: c.condensed.contains(pair.id),
                          onChanged: (on) => c.setCondensed([pair.id], on: on!),
                          label: c.pairName(pair),
                          trailing: c.pairs.contains(pair)
                              ? ToolbarButton(
                                  icon: AppIcon.close.of(context),
                                  tooltip: 'Remove pair',
                                  onPressed: () => c.removePair(pair),
                                )
                              : null,
                        ),
                    ],
                  ),
                ),
              ],
              if (firsts.isNotEmpty) ...[
                const Divider(height: 20),
                Text('Add a pair', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: choose('Player', _first, firsts, (id) => setState(() {
                        _first = id;
                        _second = null;
                      })),
                    ),
                    Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text('with', style: muted)),
                    Expanded(child: choose('Player', _second, seconds, (id) => setState(() => _second = id))),
                    const SizedBox(width: 12),
                    OutlinedButton(
                      // As tall as the fields beside it.
                      style: dialogButtonStyle(context)
                          .copyWith(minimumSize: WidgetStatePropertyAll(Size(76, AppStyle.of(context).field))),
                      onPressed: _first != null && _second != null ? _add : null,
                      child: const Text('Add'),
                    ),
                  ],
                ),
                if (split.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text('${split.map(c.pairName).join(' and ')} will be split.', style: muted),
                ],
              ],
            ],
          ),
        );
      },
    );
  }
}
