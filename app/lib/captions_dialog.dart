import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'dialog_kit.dart';
import 'edit_dialogs.dart';
import 'editor_controller.dart';
import 'error_text.dart';
import 'file_names.dart';
import 'ui_kit.dart';
import 'l10n/l10n.dart';

/// The Captions sheet (double-click the Captions lane): every caption as a row of From, Until
/// and Text cells, in the order they show. Tab goes across, ↑ / ↓ and Enter up and down;
/// Done applies everything as one Undo step, and a row left without text goes. [focus] (an
/// index into the captions) starts on that caption's text. Import… brings in an SRT or WebVTT
/// file's subtitles as rows (placed in the score by the sync), Export… writes the rows as one,
/// timed as the recording plays them.
Future<void> showCaptionsDialog(BuildContext context, EditorController c, {int? focus}) async {
  final result = await showAppDialog<List<Caption>>(
      context: context, builder: (context) => CaptionsDialog(controller: c, focus: focus));
  if (result != null) c.captions.replaceAll(result);
}

class CaptionsDialog extends StatefulWidget {
  const CaptionsDialog({super.key, required this.controller, this.focus});
  final EditorController controller;
  final int? focus;

  @override
  State<CaptionsDialog> createState() => _CaptionsDialogState();
}

/// One caption's cells. [caption] is what it was (or was drafted as): a cell still showing
/// its edge as written keeps that edge exactly, as in the region dialog. [index] is where it
/// is among the captions; null: added here.
class _Row {
  _Row(this.caption, BeatGrid beats, [this.index])
      : from = TextEditingController(text: beats.format(caption.start)),
        to = TextEditingController(text: beats.format(caption.end)),
        text = TextEditingController(text: caption.text);
  final Caption caption;
  final int? index;
  final TextEditingController from, to, text;
  final focus = [FocusNode(), FocusNode(), FocusNode()];

  void dispose() {
    from.dispose();
    to.dispose();
    text.dispose();
    for (final f in focus) {
      f.dispose();
    }
  }
}

class _CaptionsDialogState extends State<CaptionsDialog> {
  EditorController get c => widget.controller;
  BeatGrid get _beats => c.beats;
  late final List<_Row> _rows;
  final _scroll = ScrollController();

  /// What Import… or Export… last did, shown while no row has a problem.
  String? _notice;

  static const _types = [XTypeGroup(label: 'SubRip', extensions: ['srt']), XTypeGroup(label: 'WebVTT', extensions: ['vtt'])];

  static const _rowHeight = 34.0;

  @override
  void initState() {
    super.initState();
    final captions = c.captions.captions;
    final order = [for (var i = 0; i < captions.length; i++) i]..sort((a, b) => captions[a].start.compareTo(captions[b].start));
    _rows = [for (final i in order) _Row(captions[i], _beats, i)];
    final at = widget.focus == null ? -1 : order.indexOf(widget.focus!);
    if (at >= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusCell(at, 2));
    }
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  double? _read(TextEditingController field, double edge) => field.text == _beats.format(edge) ? edge : _beats.parse(field.text);
  double? _start(_Row r) => _read(r.from, r.caption.start);
  double? _end(_Row r) => _read(r.to, r.caption.end);

  /// What's wrong with each row's timing (null: nothing). Rows can't overlap (one caption
  /// shows at a time): sorted by start, one running into the next is flagged.
  List<String?> _problems() {
    final times = [for (final r in _rows) (_start(r), _end(r))];
    final problems = [
      for (final (a, b) in times)
        a == null || b == null
            ? 'Enter a bar or bar.beat, like 12 or 12.3'
            : b <= a
                ? 'Set Until after From'
                : null,
    ];
    final order = [for (var i = 0; i < _rows.length; i++) if (problems[i] == null) i]
      ..sort((x, y) => times[x].$1!.compareTo(times[y].$1!));
    for (var k = 0; k + 1 < order.length; k++) {
      final i = order[k], j = order[k + 1];
      if (times[i].$2! > times[j].$1! + 1e-9) problems[j] = 'Overlaps the caption in row {n}'.fill({'n': i + 1});
    }
    return problems;
  }

  void _focusCell(int row, int column) {
    if (row < 0 || row >= _rows.length) return;
    final node = _rows[row].focus[column];
    node.requestFocus();
    final field = [_rows[row].from, _rows[row].to, _rows[row].text][column];
    field.selection = TextSelection(baseOffset: 0, extentOffset: field.text.length);
    if (_scroll.hasClients) {
      final top = row * _rowHeight, view = _scroll.position.viewportDimension, at = _scroll.offset;
      if (top < at) _scroll.jumpTo(top);
      if (top + _rowHeight > at + view) _scroll.jumpTo(top + _rowHeight - view);
    }
  }

  /// A new row after the last caption (or from the playhead when there is none), its text to type.
  /// It fits among the rows as they are here (not the captions as they were).
  void _add() {
    final rows = [
      for (final r in _rows)
        if ((_start(r), _end(r)) case (final a?, final b?) when b > a) Caption(a, b, ''),
    ];
    final last = _rows.isEmpty ? null : _end(_rows.last);
    final draft = (last != null && last < _beats.totalQuarters - 1e-9 ? c.captions.draft(last, rows) : null) ??
        c.captions.draft(c.timeline.quarterAtSeconds(c.playback.time.value), rows);
    if (draft == null) return;
    setState(() => _rows.add(_Row(draft, _beats)));
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusCell(_rows.length - 1, 2));
  }

  void _remove(int i) => setState(() => _rows.removeAt(i).dispose());

  /// The rows as captions, those whose bars read.
  List<Caption> get _valid => [
        for (final r in _rows)
          if ((_start(r), _end(r)) case (final a?, final b?) when b > a) Caption(a, b, r.text.text),
      ];

  /// Reads a subtitle file into rows: in place of these, or (Add) around them, a subtitle
  /// running into a row left out.
  Future<void> _import() async {
    final file = await openFile(acceptedTypeGroups: _types);
    if (file == null || !mounted) return;
    final List<Caption> read;
    try {
      if (await file.length() > maxSubtitleBytes) throw const SubtitleException('This subtitle file is too large.');
      read = captionsFromCues(parseSubtitles(decodeSubtitles(await file.readAsBytes())), c.timeline, _beats.totalQuarters);
    } catch (e) {
      if (mounted) setState(() => _notice = describeError(e));
      return;
    }
    if (!mounted) return;
    if (read.isEmpty) return setState(() => _notice = 'No subtitles fall within the music.'.tr);
    var add = false;
    if (_rows.isNotEmpty) {
      final replace = await showAppDialog<bool>(
        context: context,
        builder: (context) => AppDialog(
          title: Text('Replace the captions?'.tr),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel'.tr)),
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text('Add'.tr)),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text('Replace'.tr)),
          ],
        ),
      );
      if (replace == null || !mounted) return;
      add = !replace;
    }
    final kept = add ? _valid : const <Caption>[];
    final taken = [for (final cap in read) if (captionOverlapping(kept, cap.start, cap.end) == null) cap];
    setState(() {
      if (!add) {
        for (final r in _rows) {
          r.dispose();
        }
        _rows.clear();
      }
      _rows
        ..addAll([for (final cap in taken) _Row(cap, _beats)])
        ..sort((a, b) => (_start(a) ?? 0).compareTo(_start(b) ?? 0));
      final left = read.length - taken.length;
      _notice = (left > 0 ? '{n} imported, {left} overlapping left out' : '{n} imported').fill({'n': taken.length, 'left': left});
    });
  }

  /// Writes the rows as SRT or WebVTT (the name chosen says which).
  Future<void> _export() async {
    final captions = _valid;
    final title = c.score?.metadata.title.replaceAll(RegExp(r'[/\\:]'), '-').trim() ?? '';
    final location = await getSaveLocation(acceptedTypeGroups: _types, suggestedName: '${title.isEmpty ? 'Captions'.tr : title}.srt');
    if (location == null || !mounted) return;
    final format = SubtitleFormat.ofPath(location.path) ??
        (location.activeFilter?.label == SubtitleFormat.vtt.label ? SubtitleFormat.vtt : SubtitleFormat.srt);
    final path = await confirmSavePath(context, location.path, format.extension);
    if (path == null || !mounted) return;
    try {
      await File(path).writeAsString(writeSubtitles(captionCues(captions, c.timeline), format));
      if (mounted) setState(() => _notice = 'Exported “{name}”'.fill({'name': fileNameOf(path)}));
    } catch (e) {
      if (mounted) setState(() => _notice = describeError(e));
    }
  }

  void _done() {
    if (_problems().any((p) => p != null)) return;
    // In the captions' own order (new ones last), so a sheet left as it was changes nothing.
    final kept = [for (final r in _rows) if (r.index != null) r]..sort((a, b) => a.index!.compareTo(b.index!));
    Navigator.pop(context, [
      for (final r in [...kept, ..._rows.where((r) => r.index == null)]) Caption(_start(r)!, _end(r)!, r.text.text),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final problems = _problems();
    final problem = [
      for (final (i, p) in problems.indexed)
        if (p != null) '${i + 1}: $p',
    ].firstOrNull;
    final invalid = problem != null;
    final status = problem ?? _notice;
    final header = TextStyle(fontSize: AppStyle.of(context).isCarbon ? 12 : 12.5, fontWeight: FontWeight.w600, color: colors.textMuted);
    return AppDialog(
      title: Text('Captions'.tr),
      content: SizedBox(
        width: dialogWidth(context, 640),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DecoratedBox(
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: colors.line))),
            child: SizedBox(
              height: 26,
              child: Row(children: [
                SizedBox(width: 32, child: Text('#', style: header, textAlign: TextAlign.center)),
                SizedBox(width: 88, child: _pad(Text('From'.tr, style: header))),
                SizedBox(width: 88, child: _pad(Text('Until'.tr, style: header))),
                Expanded(child: _pad(Text('Text'.tr, style: header))),
                const SizedBox(width: 32),
              ]),
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: math.max(_rowHeight, MediaQuery.sizeOf(context).height * 0.5)),
            child: _rows.isEmpty
                ? SizedBox(
                    height: _rowHeight * 2,
                    child: Center(child: Text('No captions'.tr, style: TextStyle(color: colors.textMuted))),
                  )
                : ListView.builder(
                    controller: _scroll,
                    shrinkWrap: true,
                    itemCount: _rows.length,
                    itemExtent: _rowHeight,
                    itemBuilder: (context, i) => _row(context, i, problems[i]),
                  ),
          ),
          const SizedBox(height: 8),
        ]),
      ),
      divided: true,
      leading: [
        TextButton.icon(onPressed: _add, icon: Icon(AppIcon.add.of(context), size: 18), label: Text('Add'.tr)),
        TextButton(onPressed: _import, child: Text('Import…'.tr)),
        TextButton(onPressed: invalid || _rows.isEmpty ? null : _export, child: Text('Export…'.tr)),
      ],
      status: status == null
          ? null
          : Text(status.tr, style: TextStyle(color: problem != null ? colors.erase : colors.textMuted), overflow: TextOverflow.ellipsis),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel'.tr)),
        FilledButton(onPressed: invalid ? null : _done, child: Text('Done'.tr)),
      ],
    );
  }

  static Widget _pad(Widget child) => Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: child);

  Widget _row(BuildContext context, int i, String? problem) {
    final colors = context.colors;
    const size = 14.0; // a dialog's text
    final r = _rows[i];
    final a = _start(r), b = _end(r);
    // The cells at fault: a bar that isn't one, an end too soon, or (an overlap) the start.
    bool bad(int column) =>
        problem != null && (column == 0 ? a == null || (b != null && b > a) : b == null || (a != null && b <= a));

    Widget cell(int column, TextEditingController field) {
      final error = column < 2 && bad(column);
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => _focusCell(i - 1, column),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () => _focusCell(i + 1, column),
        },
        child: Container(
          decoration: BoxDecoration(
            color: error ? colors.erase.withValues(alpha: 0.10) : null,
            border: Border(right: BorderSide(color: colors.grid)),
          ),
          alignment: Alignment.centerLeft,
          child: TextField(
            controller: field,
            focusNode: r.focus[column],
            maxLength: column == 2 ? 160 : null,
            style: TextStyle(fontSize: size, color: error ? colors.erase : colors.text),
            decoration: InputDecoration(
              isDense: true,
              counterText: '',
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
              hintText: column == 2 ? 'Leave empty to remove' : null,
              hintStyle: TextStyle(fontSize: size, color: colors.textMuted.withValues(alpha: 0.6)),
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _focusCell(i + 1, column),
          ),
        ),
      );
    }

    final row = DecoratedBox(
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: colors.grid))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          width: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(border: Border(right: BorderSide(color: colors.grid))),
          child: Text('${i + 1}', style: TextStyle(fontSize: 11.5, color: colors.textMuted)),
        ),
        SizedBox(width: 88, child: cell(0, r.from)),
        SizedBox(width: 88, child: cell(1, r.to)),
        Expanded(child: cell(2, r.text)),
        SizedBox(
          width: 32,
          child: Tip(
            message: 'Remove'.tr,
            child: IconButton(
              iconSize: 16,
              padding: EdgeInsets.zero,
              icon: Icon(AppIcon.close.of(context), color: colors.textMuted),
              onPressed: () => _remove(i),
            ),
          ),
        ),
      ]),
    );
    return row;
  }
}
