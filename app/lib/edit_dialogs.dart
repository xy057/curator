import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'app_settings.dart';
import 'editor_controller.dart';
import 'ui_kit.dart';
import 'video_export.dart';

/// After importing [fileName]: what of it was left out or isn't supported ([warnings], as
/// [LoadedScore.warnings] gives them), so the score isn't silently shown incomplete.
Future<void> showImportWarnings(BuildContext context, String fileName, List<String> warnings) => showAppDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Some of “$fileName” isn’t shown'),
        content: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(warnings.length == 1
                ? 'This was left out or isn’t supported:'
                : 'These ${warnings.length} things were left out or aren’t supported:'),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: SelectionArea(
                child: ListView(shrinkWrap: true, children: [
                  for (final warning in warnings)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('•  ', style: TextStyle(color: context.colors.textMuted)),
                        Expanded(child: Text(warning, style: const TextStyle(fontSize: 13))),
                      ]),
                    ),
                ]),
              ),
            ),
          ]),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );

/// Rename an instrument: the full name and the short name used when space is tight.
Future<void> showRenameDialog(BuildContext context, EditorController c, ScorePart part) =>
    showAppDialog<void>(context: context, builder: (context) => _RenameDialog(controller: c, part: part));

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
    showAppDialog<void>(context: context, builder: (context) => _TextsDialog(controller: c));

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

/// A region's properties: where it starts and ends, typed as bar or bar.beat ("12" or
/// "12.3"), and how long its staff takes to glide in at its start and out at its end.
Future<void> showRegionDialog(BuildContext context, EditorController c, RegionRef ref) async {
  final region = await showAppDialog<Region>(context: context, builder: (context) => _RegionDialog(controller: c, ref: ref));
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
  late double? _in = widget.ref.region.transitionIn, _out = widget.ref.region.transitionOut;

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
    // A field as it was shown is the region's own edge, not the text's rounding of it (an
    // edge between beats reads "12.1.33"), so changing only a transition moves nothing.
    double? read(TextEditingController field, double edge) =>
        field.text == _beats.format(edge) ? edge : _beats.parse(field.text);
    final a = read(_from, widget.ref.region.start), b = read(_to, widget.ref.region.end);
    final error = a == null || b == null
        ? 'Type a bar, or bar.beat — e.g. 12 or 12.3'
        : b <= a
            ? 'It has to end after it starts'
            : null;
    void save() {
      if (error == null) Navigator.pop(context, Region(a!, b!, transitionIn: _in, transitionOut: _out));
    }

    return AlertDialog(
      title: Text('Show ${c.laneName(part)}'),
      content: SizedBox(
        width: 320,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
          const SizedBox(height: 16),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: _TransitionField(label: 'Glides in over', value: _in, project: c.curation!.transition, onChanged: (s) => setState(() => _in = s))),
            const SizedBox(width: 16),
            Expanded(child: _TransitionField(label: 'Glides out over', value: _out, project: c.curation!.transition, onChanged: (s) => setState(() => _out = s))),
          ]),
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

/// A caption's text and when it shows, as bar or bar.beat ("12" or "12.3"): a new one
/// ([draft]) or caption [index]. An empty text removes it.
Future<void> showCaptionDialog(BuildContext context, EditorController c, {int? index, Caption? draft}) async {
  final caption = index != null ? c.captions.captions[index] : draft!;
  final result = await showAppDialog<Caption>(context: context, builder: (context) => _CaptionDialog(controller: c, caption: caption, isNew: index == null));
  if (result == null) return;
  if (index == null) {
    c.captions.add(result);
  } else {
    c.captions.update(index, result);
  }
}

class _CaptionDialog extends StatefulWidget {
  const _CaptionDialog({required this.controller, required this.caption, required this.isNew});
  final EditorController controller;
  final Caption caption;
  final bool isNew;

  @override
  State<_CaptionDialog> createState() => _CaptionDialogState();
}

class _CaptionDialogState extends State<_CaptionDialog> {
  BeatGrid get _beats => widget.controller.beats;
  late final _text = TextEditingController(text: widget.caption.text);
  late final _from = TextEditingController(text: _beats.format(widget.caption.start));
  late final _to = TextEditingController(text: _beats.format(widget.caption.end));

  @override
  void dispose() {
    _text.dispose();
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // As in the region dialog: a field as shown is the caption's own edge, not its rounding.
    double? read(TextEditingController field, double edge) =>
        field.text == _beats.format(edge) ? edge : _beats.parse(field.text);
    final a = read(_from, widget.caption.start), b = read(_to, widget.caption.end);
    final error = a == null || b == null
        ? 'Type a bar, or bar.beat — e.g. 12 or 12.3'
        : b <= a
            ? 'It has to end after it starts'
            : widget.isNew && _text.text.trim().isEmpty
                ? ''
                : null;
    void save() {
      if (error == null) Navigator.pop(context, Caption(a!, b!, _text.text));
    }

    return AlertDialog(
      title: Text(widget.isNew ? 'Add Caption' : 'Caption'),
      content: SizedBox(
        width: 400,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            controller: _text,
            autofocus: true,
            maxLength: 160,
            decoration: const InputDecoration(labelText: 'Text', counterText: ''),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => save(),
          ),
          const SizedBox(height: 12),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: TextField(
                controller: _from,
                decoration: const InputDecoration(labelText: 'From'),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => save(),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: TextField(
                controller: _to,
                decoration: const InputDecoration(labelText: 'Until'),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => save(),
              ),
            ),
          ]),
        ]),
      ),
      actions: [
        if (error != null && error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(error, style: TextStyle(fontSize: 12, color: context.colors.erase)),
          ),
        if (!widget.isNew)
          TextButton(
            onPressed: () => Navigator.pop(context, widget.caption.copyWith(text: '')),
            child: const Text('Remove'),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: error == null ? save : null, child: Text(widget.isNew ? 'Add' : 'Apply')),
      ],
    );
  }
}

/// How long a region's staff glides at one edge: the project's transition (null, whatever it
/// becomes in Settings ▸ Animation) or one of the usual lengths.
class _TransitionField extends StatelessWidget {
  const _TransitionField({required this.label, required this.value, required this.project, required this.onChanged});
  final String label;
  final double? value;
  final double project;
  final ValueChanged<double?> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<double?>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: [
          DropdownMenuItem(value: null, child: Text("Project's ($project s)")),
          for (final s in {...AppSettings.transitionChoices, ?value}.toList()..sort()) DropdownMenuItem(value: s, child: Text('$s s')),
        ],
        onChanged: onChanged,
      );
}

/// Copy one lane's regions to other instruments (e.g. Violin I → the rest of the strings).
Future<void> showCopyLaneDialog(BuildContext context, EditorController c, ScorePart from) async {
  final others = c.laneParts.where((p) => p.id != from.id).toList();
  final chosen = <String>{};
  final ok = await showAppDialog<bool>(
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

/// An anchor's position and, for a warp, where the score goes on from: null when cancelled.
/// [warp] starts in the jump's field (making a warp).
Future<({double quarter, double? jumpTo})?> showAnchorDialog(BuildContext context,
        {required BeatGrid beats, required double quarter, double? jumpTo, bool warp = false}) =>
    showAppDialog<({double quarter, double? jumpTo})>(
        context: context,
        builder: (context) => _AnchorDialog(beats: beats, quarter: quarter, jumpTo: jumpTo, warp: warp));

class _AnchorDialog extends StatefulWidget {
  const _AnchorDialog({required this.beats, required this.quarter, required this.jumpTo, required this.warp});
  final BeatGrid beats;
  final double quarter;
  final double? jumpTo;
  final bool warp;

  @override
  State<_AnchorDialog> createState() => _AnchorDialogState();
}

class _AnchorDialogState extends State<_AnchorDialog> {
  late final _position = TextEditingController(text: widget.beats.format(widget.quarter));
  late final _jump = TextEditingController(text: widget.jumpTo == null ? '' : widget.beats.format(widget.jumpTo!));

  @override
  void dispose() {
    _position.dispose();
    _jump.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = widget.beats.parse(_position.text);
    final plain = _jump.text.trim().isEmpty;
    final jump = plain ? null : widget.beats.parse(_jump.text);
    final nowhere = q != null && jump != null && (jump - q).abs() < 1e-6;
    final valid = q != null && (plain || (jump != null && !nowhere));
    void save() {
      if (valid) Navigator.pop(context, (quarter: q, jumpTo: jump));
    }

    // A bad entry is outlined in red (no message): Set stays off until both read as bars.
    InputDecoration field(String label, {required bool bad, String? hint}) => InputDecoration(
        labelText: label, hintText: hint, errorText: bad ? '' : null, errorStyle: const TextStyle(height: 0, fontSize: 0));
    return AlertDialog(
      title: Text(plain ? 'Anchor' : 'Warp'),
      content: SizedBox(
        width: 240,
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _position,
              autofocus: !widget.warp,
              decoration: field('At', bad: q == null),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => save(),
            ),
          ),
          const Padding(padding: EdgeInsets.symmetric(horizontal: 10), child: Icon(Icons.arrow_forward_rounded, size: 18)),
          Expanded(
            child: TextField(
              controller: _jump,
              autofocus: widget.warp,
              decoration: field('Jump to', bad: nowhere || (!plain && jump == null), hint: 'none'),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => save(),
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: valid ? save : null, child: const Text('Set')),
      ],
    );
  }
}

/// A video ratio typed by hand ("2.39:1", "4:5", "1920x800"): null when cancelled.
Future<VideoRatio?> showVideoRatioDialog(BuildContext context, VideoRatio current) =>
    showAppDialog<VideoRatio>(context: context, builder: (context) => _VideoRatioDialog(current: current));

class _VideoRatioDialog extends StatefulWidget {
  const _VideoRatioDialog({required this.current});
  final VideoRatio current;

  @override
  State<_VideoRatioDialog> createState() => _VideoRatioDialogState();
}

class _VideoRatioDialogState extends State<_VideoRatioDialog> {
  late final _text = TextEditingController(text: widget.current.label);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ratio = VideoRatio.parse(_text.text);
    void save() {
      // Read now, not at the last build: Enter may come before the rebuild.
      if (VideoRatio.parse(_text.text) case final r?) Navigator.pop(context, r);
    }

    // A bad entry is outlined in red (no message): Set stays off until it reads as a ratio.
    return AlertDialog(
      title: const Text('Video Ratio'),
      content: SizedBox(
        width: 240,
        child: TextField(
          controller: _text,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Width : height',
            hintText: '2.39:1',
            errorText: ratio == null ? '' : null,
            errorStyle: const TextStyle(height: 0, fontSize: 0),
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => save(),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: ratio == null ? null : save, child: const Text('Set')),
      ],
    );
  }
}

/// [path] ending `.<extension>`, and whether it was added: a save panel asked about the name as
/// typed, so a file with the added extension was never offered to be replaced.
(String, bool) withExtension(String path, String extension) =>
    path.toLowerCase().endsWith('.${extension.toLowerCase()}') ? (path, false) : ('$path.$extension', true);

/// Where to save what the save panel chose ([path]), with its [extension]: when adding it names
/// a file already there, asks before replacing it (the panel didn't). Null: don't save.
Future<String?> confirmSavePath(BuildContext context, String path, String extension) async {
  final (full, added) = withExtension(path, extension);
  if (!added || !File(full).existsSync()) return full;
  final name = full.split(RegExp(r'[/\\]')).last;
  final replace = await showAppDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Replace “$name”?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Replace')),
      ],
    ),
  );
  return replace == true ? full : null;
}
