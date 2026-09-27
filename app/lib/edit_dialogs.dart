import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'editor_controller.dart';

/// Rename an instrument: the full name and the short name used when space is tight.
Future<void> showRenameDialog(BuildContext context, EditorController c, ScorePart part) =>
    showDialog<void>(context: context, builder: (context) => _RenameDialog(controller: c, part: part));

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.controller, required this.part});
  final EditorController controller;
  final ScorePart part;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _name = TextEditingController(text: widget.controller.partName(widget.part));
  late final _short = TextEditingController(text: widget.controller.partAbbreviation(widget.part));

  @override
  void dispose() {
    _name.dispose();
    _short.dispose();
    super.dispose();
  }

  void _rename({bool reset = false}) {
    widget.controller.renamePart(widget.part, name: reset ? '' : _name.text, abbreviation: reset ? '' : _short.text);
    Navigator.pop(context);
  }

  void _insert(String symbol) {
    final sel = _name.selection;
    final at = sel.isValid ? sel.start : _name.text.length;
    _name.value = TextEditingValue(
      text: _name.text.replaceRange(at, sel.isValid ? sel.end : at, symbol),
      selection: TextSelection.collapsed(offset: at + symbol.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename instrument'),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name', helperText: 'e.g. "Clarinet in B♭ 1"'),
            onSubmitted: (_) => _rename(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _short,
            decoration: const InputDecoration(labelText: 'Short name', helperText: 'Used when the full name does not fit'),
            onSubmitted: (_) => _rename(),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 6, children: [
            for (final symbol in const ['♭', '♯', '♮'])
              ActionChip(label: Text(symbol), tooltip: 'Insert $symbol', onPressed: () => _insert(symbol)),
          ]),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => _rename(reset: true), child: const Text('Use name from file')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _rename, child: const Text('Rename')),
      ],
    );
  }
}

/// Every text in the score (directions, tempo and rehearsal marks) in one searchable list.
Future<void> showTextsDialog(BuildContext context, EditorController c) =>
    showDialog<void>(context: context, builder: (context) => _TextsDialog(controller: c));

class _TextsDialog extends StatefulWidget {
  const _TextsDialog({required this.controller});
  final EditorController controller;

  @override
  State<_TextsDialog> createState() => _TextsDialogState();
}

class _TextsDialogState extends State<_TextsDialog> {
  final _search = TextEditingController();
  final _fields = <String, TextEditingController>{};

  EditorController get c => widget.controller;

  @override
  void dispose() {
    _search.dispose();
    for (final f in _fields.values) {
      f.dispose();
    }
    super.dispose();
  }

  TextEditingController _field(ScoreText t) =>
      _fields.putIfAbsent(t.id, () => TextEditingController(text: c.currentText(t)));

  Future<void> _apply() async {
    final score = c.score!;
    final changes = <String, String?>{
      for (final t in score.texts)
        if (_fields[t.id] != null && _fields[t.id]!.text != c.currentText(t)) t.id: _fields[t.id]!.text,
    };
    Navigator.pop(context);
    await c.editTexts(changes);
  }

  @override
  Widget build(BuildContext context) {
    final score = c.score!;
    final names = {for (final p in score.metadata.parts) p.id: c.partName(p)};
    final query = _search.text.trim().toLowerCase();
    final texts = [
      for (final t in score.texts)
        if (query.isEmpty ||
            t.text.toLowerCase().contains(query) ||
            c.currentText(t).toLowerCase().contains(query) ||
            (names[t.partId] ?? '').toLowerCase().contains(query))
          t,
    ];
    return AlertDialog(
      title: const Text('Texts in the score'),
      content: SizedBox(
        width: 620,
        height: 460,
        child: Column(children: [
          TextField(
            controller: _search,
            autofocus: true,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search, size: 18),
              hintText: 'Search text or instrument (e.g. "arco")',
              isDense: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          Text(
            'Edit a text to change it; clear it to remove it. Changes are engraved when you apply.',
            style: TextStyle(fontSize: 12, color: context.colors.textMuted),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: texts.isEmpty
                ? Center(child: Text('No texts found', style: TextStyle(color: context.colors.textMuted)))
                : ListView.separated(
                    itemCount: texts.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final t = texts[i];
                      final field = _field(t);
                      final edited = field.text != t.text;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(children: [
                          SizedBox(
                            width: 190,
                            child: Text(
                              'Bar ${t.measure + 1} · ${names[t.partId] ?? t.partId}',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: context.colors.textMuted),
                            ),
                          ),
                          Expanded(
                            child: TextField(
                              controller: field,
                              style: TextStyle(
                                fontSize: 13,
                                fontStyle: t.kind == ScoreTextKind.direction ? FontStyle.italic : FontStyle.normal,
                                fontWeight: t.kind == ScoreTextKind.tempo ? FontWeight.w600 : FontWeight.normal,
                              ),
                              decoration: InputDecoration(
                                isDense: true,
                                hintText: '(removed)',
                                border: InputBorder.none,
                                suffixIcon: edited
                                    ? IconButton(
                                        tooltip: 'Back to "${t.text}"',
                                        icon: const Icon(Icons.undo, size: 16),
                                        onPressed: () => setState(() => field.text = t.text),
                                      )
                                    : null,
                              ),
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                        ]),
                      );
                    },
                  ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _apply, child: const Text('Apply')),
      ],
    );
  }
}

/// Type where a region starts and ends, as bar or bar.beat ("12" or "12.3").
Future<void> showRegionDialog(BuildContext context, EditorController c, RegionRef ref) async {
  final region = await showDialog<Region>(context: context, builder: (context) => _RegionDialog(controller: c, ref: ref));
  if (region != null) c.lanes.setRegion(ref, region);
}

class _RegionDialog extends StatefulWidget {
  const _RegionDialog({required this.controller, required this.ref});
  final EditorController controller;
  final RegionRef ref;

  @override
  State<_RegionDialog> createState() => _RegionDialogState();
}

class _RegionDialogState extends State<_RegionDialog> {
  BeatGrid get _beats => widget.controller.beats;
  late final _from = TextEditingController(text: _beats.format(widget.ref.region.start));
  late final _to = TextEditingController(text: _beats.format(widget.ref.region.end));

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final part = c.score!.metadata.parts.firstWhere((p) => p.id == widget.ref.partId);
    final a = _beats.parse(_from.text), b = _beats.parse(_to.text);
    final error = a == null || b == null
        ? 'Type a bar, or bar.beat — e.g. 12 or 12.3'
        : b <= a
            ? 'It has to end after it starts'
            : null;
    void save() {
      if (error == null) Navigator.pop(context, Region(a!, b!));
    }

    return AlertDialog(
      title: Text('Show ${c.laneName(part)}'),
      content: SizedBox(
        width: 320,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: TextField(
              controller: _from,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'From'),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => save(),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: TextField(
              controller: _to,
              decoration: const InputDecoration(labelText: 'Until', helperText: 'Hidden again from here'),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => save(),
            ),
          ),
        ]),
      ),
      actions: [
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(error, style: TextStyle(fontSize: 12, color: context.colors.erase)),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: error == null ? save : null, child: const Text('Apply')),
      ],
    );
  }
}

/// Copy one lane's regions to other instruments (e.g. Violin I → the rest of the strings).
Future<void> showCopyLaneDialog(BuildContext context, EditorController c, ScorePart from) async {
  final others = c.laneParts.where((p) => p.id != from.id).toList();
  final chosen = <String>{};
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text('Copy ${c.laneName(from)} to…'),
        content: SizedBox(
          width: 360,
          height: math.min(420, others.length * 40.0 + 8),
          child: ListView(children: [
            for (final part in others)
              CheckboxListTile(
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(c.laneName(part)),
                value: chosen.contains(part.id),
                onChanged: (on) => setState(() => on! ? chosen.add(part.id) : chosen.remove(part.id)),
              ),
          ]),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text('Replaces what those lanes show', style: TextStyle(fontSize: 12, color: context.colors.textMuted)),
          ),
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: chosen.isEmpty ? null : () => Navigator.pop(context, true), child: const Text('Copy')),
        ],
      ),
    ),
  );
  if (ok == true) c.lanes.copyLane(from.id, chosen);
}

/// Type one score position, as bar or bar.beat ("12" or "12.3"). Returns it, or null.
Future<double?> showPositionDialog(BuildContext context,
        {required String title, required String initial, required BeatGrid beats}) =>
    showDialog<double>(context: context, builder: (context) => _PositionDialog(title: title, initial: initial, beats: beats));

class _PositionDialog extends StatefulWidget {
  const _PositionDialog({required this.title, required this.initial, required this.beats});
  final String title;
  final String initial;
  final BeatGrid beats;

  @override
  State<_PositionDialog> createState() => _PositionDialogState();
}

class _PositionDialogState extends State<_PositionDialog> {
  late final _field = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = widget.beats.parse(_field.text);
    void save() {
      if (q != null) Navigator.pop(context, q);
    }

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 240,
        child: TextField(
          controller: _field,
          autofocus: true,
          decoration: InputDecoration(labelText: 'Bar or bar.beat', errorText: q == null ? 'e.g. 12 or 12.3' : null),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => save(),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: q == null ? null : save, child: const Text('Set')),
      ],
    );
  }
}
