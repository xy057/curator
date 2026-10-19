import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'dialog_kit.dart';
import 'editor_controller.dart';
import 'menu_kit.dart';

/// Project Settings ▸ Condensing ▸ Add a pair: two players of the user's own choosing
/// (Flute 1 + Oboe 1, Horn 1 + 3) made a pair, as in Dorico's Edit Condensing Groups. Says
/// first which built-in pairs it splits. The pairs themselves are the page's rows.
class CondensingAddPair extends StatefulWidget {
  const CondensingAddPair({super.key, required this.controller});
  final EditorController controller;

  /// Whether any player is free to pair, so whether this is offered at all.
  static bool offered(EditorController c) => _free(c).isNotEmpty;

  /// Players free to pair: those with a partner who isn't already in a pair of the user's.
  static List<String> _free(EditorController c, [String? partnerOf]) {
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

  @override
  State<CondensingAddPair> createState() => _CondensingAddPairState();
}

class _CondensingAddPairState extends State<CondensingAddPair> {
  EditorController get c => widget.controller;

  /// The pair being made.
  String? _first, _second;

  void _add() {
    c.addPair(_first!, _second!);
    setState(() => _first = _second = null);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final muted = TextStyle(fontSize: 12, height: 1.35, color: colors.textMuted);
    final firsts = CondensingAddPair._free(c);
    if (!firsts.contains(_first)) _first = null;
    final seconds = _first == null ? const <String>[] : CondensingAddPair._free(c, _first);
    if (!seconds.contains(_second)) _second = null;

    AppDropdown<String> choose(String? value, List<String> ids, ValueChanged<String?> onChanged) => AppDropdown<String>(
          isExpanded: true,
          boxed: true,
          hint: const Text('Player'),
          value: value,
          items: [for (final id in ids) DropdownMenuItem(value: id, child: Text(c.partNameOf(id)))],
          onChanged: ids.isEmpty ? null : onChanged,
        );

    // Adding a pair takes its players out of the built-in pairs they are in: say so first.
    final split = [
      if (_second != null)
        for (final p in c.condensable)
          if (!c.pairs.contains(p) && (p.contains(_first!) || p.contains(_second!))) p,
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: choose(_first, firsts, (id) => setState(() {
              _first = id;
              _second = null;
            })),
          ),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text('with', style: muted)),
          Expanded(child: choose(_second, seconds, (id) => setState(() => _second = id))),
          const SizedBox(width: 10),
          OutlinedButton(
            // As tall as the fields beside it.
            style: dialogButtonStyle(context)
                .copyWith(minimumSize: WidgetStatePropertyAll(Size(64, AppStyle.of(context).field))),
            onPressed: _first != null && _second != null ? _add : null,
            child: const Text('Add'),
          ),
        ]),
        if (split.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('Splits ${split.map(c.pairName).join(' and ')}.', style: muted),
        ],
      ]),
    );
  }
}
