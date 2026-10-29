import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'app_settings.dart';
import 'dialog_kit.dart';
import 'editor_controller.dart';
import 'file_names.dart';
import 'menu_kit.dart';
import 'score_replacement.dart' show ScoreSwap;
import 'ui_kit.dart';
import 'video_export.dart';
import 'l10n/l10n.dart';

/// After importing [fileName]: what of it was left out or isn't supported ([warnings], as
/// [LoadedScore.warnings] gives them), so the score isn't silently shown incomplete.
Future<void> showImportWarnings(BuildContext context, String fileName, List<String> warnings) => showAppDialog<void>(
      context: context,
      builder: (context) => AppDialog(
        title: Text('Some of “{name}” got left out'.fill({'name': fileName})),
        content: SizedBox(
          width: dialogWidth(context, 460),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(warnings.length == 1
                ? 'Not supported:'.tr
                : '{n} items not supported:'.fill({'n': warnings.length})),
            const SizedBox(height: 12),
            _Bullets(warnings),
          ]),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text('OK'.tr))],
      ),
    );

/// Project Info ▸ Replace Score, when the new file differs from the open one ([differences], as
/// [ScoreSwap.differences] gives them): true to replace anyway.
Future<bool> confirmReplaceScore(BuildContext context, String fileName, List<String> differences) async =>
    await showAppDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: Text('Replace with “{name}”?'.fill({'name': fileName})),
        content: SizedBox(
          width: dialogWidth(context, 460),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Here’s what differs:'.tr),
            const SizedBox(height: 12),
            _Bullets(differences),
            const SizedBox(height: 12),
            Text('This one can’t be undone.'.tr, style: TextStyle(color: context.colors.textMuted)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel'.tr)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text('Replace'.tr)),
        ],
      ),
    ) ??
    false;

/// One line per item, selectable, scrolling past a few.
class _Bullets extends StatelessWidget {
  const _Bullets(this.lines);
  final List<String> lines;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 320),
        child: SelectionArea(
          child: ListView(shrinkWrap: true, children: [
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('•  ', style: TextStyle(color: context.colors.textMuted)),
                  Expanded(child: Text(line, style: const TextStyle(fontSize: 13))),
                ]),
              ),
          ]),
        ),
      );
}

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
    return AppDialog(
      title: Text('Rename Instrument'.tr),
      content: SizedBox(
        width: dialogWidth(context, 360),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AppTextField(
            controller: _name,
            label: 'Name',
            autofocus: true,
            onSubmitted: (_) => _rename(),
          ),
          SizedBox(height: dialogGap(context)),
          AppTextField(
            controller: _short,
            label: 'Short name',
            onSubmitted: (_) => _rename(),
          ),
          SizedBox(height: dialogGap(context)),
          Wrap(spacing: 6, children: [
            for (final symbol in const ['♭', '♯', '♮'])
              AppChip(label: symbol, tooltip: 'Insert {symbol}'.fill({'symbol': symbol}), onPressed: () => _insert(symbol)),
          ]),
        ]),
      ),
      leading: [TextButton(onPressed: () => _rename(reset: true), child: Text('Use Name from File'.tr))],
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel'.tr)),
        FilledButton(onPressed: _rename, child: Text('Rename'.tr)),
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
        ? 'Enter a bar or bar.beat, like 12 or 12.3'
        : b <= a
            ? 'Set Until after From'
            : null;
    void save() {
      if (error == null) Navigator.pop(context, Region(a!, b!, transitionIn: _in, transitionOut: _out));
    }

    return AppDialog(
      title: Text('Show {name}'.fill({'name': c.laneName(part)})),
      content: SizedBox(
        width: dialogWidth(context, 320),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: AppTextField(
                controller: _from,
                label: 'From',
                autofocus: true,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => save(),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: AppTextField(
                controller: _to,
                label: 'Until',
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => save(),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: _TransitionField(label: 'Transition in', value: _in, project: c.curation!.transition, onChanged: (s) => setState(() => _in = s))),
            const SizedBox(width: 16),
            Expanded(child: _TransitionField(label: 'Transition out', value: _out, project: c.curation!.transition, onChanged: (s) => setState(() => _out = s))),
          ]),
        ]),
      ),
      status: error == null ? null : Text(error.tr, style: TextStyle(color: context.colors.erase)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel'.tr)),
        FilledButton(onPressed: error == null ? save : null, child: Text('Apply'.tr)),
      ],
    );
  }
}

/// A caption's text and when it shows, as bar or bar.beat ("12" or "12.3"): a new one
/// ([draft]) or caption [index]. An empty text removes it.
Future<void> showCaptionDialog(BuildContext context, EditorController c, {int? index, Caption? draft}) async {
  final caption = index != null ? c.captions.captions[index] : draft!;
  final result = await showAppDialog<Caption>(context: context, builder: (context) => _CaptionDialog(controller: c, caption: caption, index: index));
  if (result == null) return;
  if (index == null) {
    c.captions.add(result);
  } else {
    c.captions.update(index, result);
  }
}

class _CaptionDialog extends StatefulWidget {
  const _CaptionDialog({required this.controller, required this.caption, this.index});
  final EditorController controller;
  final Caption caption;

  /// The caption changed; null: a new one.
  final int? index;
  bool get isNew => index == null;

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
        ? 'Enter a bar or bar.beat, like 12 or 12.3'
        : b <= a
            ? 'Set Until after From'
            : captionOverlapping(widget.controller.captions.captions, a, b, except: widget.index) != null
                ? 'Overlaps another caption'
                : widget.isNew && _text.text.trim().isEmpty
                ? ''
                : null;
    void save() {
      if (error == null) Navigator.pop(context, Caption(a!, b!, _text.text));
    }

    return AppDialog(
      title: Text((widget.isNew ? 'Add Caption' : 'Caption').tr),
      content: SizedBox(
        width: dialogWidth(context, 400),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AppTextField(
            controller: _text,
            label: 'Text',
            hint: '*italic*  **bold**',
            autofocus: true,
            maxLength: 160,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => save(),
          ),
          SizedBox(height: dialogGap(context)),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: AppTextField(
                controller: _from,
                label: 'From',
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => save(),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: AppTextField(
                controller: _to,
                label: 'Until',
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => save(),
              ),
            ),
          ]),
        ]),
      ),
      status: error == null || error.isEmpty ? null : Text(error.tr, style: TextStyle(color: context.colors.erase)),
      leading: [
        if (!widget.isNew)
          TextButton(
            onPressed: () => Navigator.pop(context, widget.caption.copyWith(text: '')),
            child: Text('Remove'.tr),
          ),
      ],
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel'.tr)),
        FilledButton(onPressed: error == null ? save : null, child: Text((widget.isNew ? 'Add' : 'Apply').tr)),
      ],
    );
  }
}

/// How long a region's staff glides at one edge: the project's transition (null, whatever it
/// becomes in Project Settings ▸ Animation) or one of the usual lengths.
class _TransitionField extends StatelessWidget {
  const _TransitionField({required this.label, required this.value, required this.project, required this.onChanged});
  final String label;
  final double? value;
  final double project;
  final ValueChanged<double?> onChanged;

  @override
  Widget build(BuildContext context) => AppDropdown<double?>(
        value: value,
        isExpanded: true,
        label: label,
        items: [
          DropdownMenuItem(value: null, child: Text("Project's ({n} s)".fill({'n': project}))),
          for (final s in {...AppSettings.transitionChoices, ?value}.toList()..sort()) DropdownMenuItem(value: s, child: Text('{n} s'.fill({'n': s}))),
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
      builder: (context, setState) => AppDialog(
        title: Text('Copy {name} to…'.fill({'name': c.laneName(from)})),
        content: SizedBox(
          width: dialogWidth(context, 360),
          height: math.min(420, others.length * dialogRowHeight(context) + 8),
          child: ListView(children: [
            for (final part in others)
              AppCheckRow(
                label: c.laneName(part),
                value: chosen.contains(part.id),
                onChanged: (on) => setState(() => on! ? chosen.add(part.id) : chosen.remove(part.id)),
              ),
          ]),
        ),
        divided: true,
        status: Text('Replaces the chosen lanes’ regions'.tr, style: TextStyle(color: context.colors.textMuted)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text('Cancel'.tr)),
          FilledButton(onPressed: chosen.isEmpty ? null : () => Navigator.pop(context, true), child: Text('Copy'.tr)),
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
    return AppDialog(
      title: Text((plain ? 'Anchor' : 'Warp').tr),
      content: SizedBox(
        width: dialogWidth(context, 240),
        // The arrow is level with the fields, not their labels over them.
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: AppTextField(
              controller: _position,
              label: 'At',
              bad: q == null,
              autofocus: !widget.warp,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => save(),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(10, 0, 10, (AppStyle.of(context).field - 16) / 2),
            child: Icon(AppIcon.forward.of(context), size: 18),
          ),
          Expanded(
            child: AppTextField(
              controller: _jump,
              label: 'Jump to',
              hint: 'none',
              bad: nowhere || (!plain && jump == null),
              autofocus: widget.warp,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => save(),
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel'.tr)),
        FilledButton(onPressed: valid ? save : null, child: Text('Set'.tr)),
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
    return AppDialog(
      title: Text('Video Ratio'.tr),
      content: SizedBox(
        width: dialogWidth(context, 240),
        child: AppTextField(
          controller: _text,
          label: 'Width : height',
          hint: '2.39:1',
          bad: ratio == null,
          autofocus: true,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => save(),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel'.tr)),
        FilledButton(onPressed: ratio == null ? null : save, child: Text('Set'.tr)),
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
  final name = fileNameOf(full);
  final replace = await showAppDialog<bool>(
    context: context,
    builder: (context) => AppDialog(
      title: Text('“{name}” already exists. Replace it?'.fill({'name': name})),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text('Cancel'.tr)),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text('Replace'.tr)),
      ],
    ),
  );
  return replace == true ? full : null;
}

/// Asks for a group's name (Project Settings ▸ Instruments): a new one's, or [rename]'s new
/// name. Null when cancelled.
Future<String?> showNameGroupDialog(BuildContext context, {String? rename}) =>
    showAppDialog<String>(context: context, builder: (context) => _NameGroupDialog(rename: rename));

/// Asks for a recording's new name in the menu, [name] now (the Audio tab's recording menu).
/// Null when cancelled.
Future<String?> showRenameRecordingDialog(BuildContext context, String name) => showAppDialog<String>(
    context: context, builder: (context) => _NameGroupDialog(rename: name, title: 'Rename Recording'));

class _NameGroupDialog extends StatefulWidget {
  const _NameGroupDialog({this.rename, this.title});
  final String? rename;

  /// Its title, renaming: "Rename Group" when null.
  final String? title;

  @override
  State<_NameGroupDialog> createState() => _NameGroupDialogState();
}

class _NameGroupDialogState extends State<_NameGroupDialog> {
  late final _name = TextEditingController(text: widget.rename ?? '');

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _done() {
    final name = _name.text.trim();
    if (name.isNotEmpty) Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    final adding = widget.rename == null;
    return AppDialog(
      title: Text((adding ? 'Add Group' : widget.title ?? 'Rename Group').tr),
      content: SizedBox(
        width: dialogWidth(context, 320),
        child: AppTextField(controller: _name, label: 'Name', autofocus: true, onSubmitted: (_) => _done()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel'.tr)),
        ListenableBuilder(
          listenable: _name,
          builder: (context, _) => FilledButton(
              onPressed: _name.text.trim().isEmpty ? null : _done, child: Text((adding ? 'Add' : 'Rename').tr)),
        ),
      ],
    );
  }
}
