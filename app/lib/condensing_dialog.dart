import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'editor_controller.dart';

/// Score ▸ Condensing…, as in Dorico (Layout Options ▸ Condensing and Edit Condensing Groups):
/// which pairs of players share a staff, and pairs of the user's own (Flute 1 + Oboe 1,
/// Horn 1 + 3). Every change is made at once, as its own Undo step. The only place
/// condensing is chosen.
Future<void> showCondensingDialog(BuildContext context, EditorController c) => showDialog<void>(
  context: context,
  builder: (context) => _CondensingDialog(controller: c),
);

class _CondensingDialog extends StatefulWidget {
  const _CondensingDialog({required this.controller});
  final EditorController controller;

  @override
  State<_CondensingDialog> createState() => _CondensingDialogState();
}

class _CondensingDialogState extends State<_CondensingDialog> {
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
        final muted = TextStyle(fontSize: 12, color: colors.textMuted);
        final pairs = c.condensable;
        final firsts = _free();
        if (!firsts.contains(_first)) _first = null;
        final seconds = _first == null ? const <String>[] : _free(_first);
        if (!seconds.contains(_second)) _second = null;

        DropdownButton<String> choose(String hint, String? value, List<String> ids, ValueChanged<String?> onChanged) =>
            DropdownButton<String>(
              isExpanded: true,
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

        return AlertDialog(
          title: const Text('Condensing'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Ticked pairs share one staff while both players are shown.', style: muted),
                const SizedBox(height: 8),
                if (pairs.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(firsts.isEmpty ? 'No players in this score can share a staff.' : 'No pairs yet: add one below.'),
                  )
                else ...[
                  if (pairs.length > 1)
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      tristate: true,
                      value: condensed == 0 ? false : (condensed == pairs.length ? true : null),
                      onChanged: (_) => c.setCondensed([for (final p in pairs) p.id], on: condensed < pairs.length),
                      title: const Text('All pairs', style: TextStyle(fontWeight: FontWeight.w600)),
                    ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 300),
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final pair in pairs)
                          CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            value: c.condensed.contains(pair.id),
                            onChanged: (on) => c.setCondensed([pair.id], on: on!),
                            title: Text(c.pairName(pair)),
                            secondary: c.pairs.contains(pair)
                                ? IconButton(
                                    icon: const Icon(Icons.close_rounded, size: 18),
                                    tooltip: 'Remove this pair',
                                    onPressed: () => c.removePair(pair),
                                  )
                                : null,
                          ),
                      ],
                    ),
                  ),
                ],
                if (firsts.isNotEmpty) ...[
                  const Divider(height: 24),
                  Text('Add a pair', style: Theme.of(context).textTheme.titleSmall),
                  Row(
                    children: [
                      Expanded(
                        child: choose('Player', _first, firsts, (id) => setState(() {
                          _first = id;
                          _second = null;
                        })),
                      ),
                      Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text('with', style: muted)),
                      Expanded(child: choose('Player', _second, seconds, (id) => setState(() => _second = id))),
                      const SizedBox(width: 12),
                      FilledButton.tonal(onPressed: _first != null && _second != null ? _add : null, child: const Text('Add')),
                    ],
                  ),
                  if (split.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text('${split.map(c.pairName).join(' and ')} will be split.', style: muted),
                  ],
                ],
                if (c.isReengraving) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 8),
                      Text('Engraving the new staff…', style: muted),
                    ],
                  ),
                ],
              ],
            ),
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
        );
      },
    );
  }
}
