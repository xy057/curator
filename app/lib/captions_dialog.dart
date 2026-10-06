import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'editor_controller.dart';
import 'ui_kit.dart';

/// The Captions sheet (double-click the Captions lane): every caption as a row of From, Until
/// and Text cells, in the order they show. Tab goes across, ↑ / ↓ and Enter up and down;
/// Done applies everything as one Undo step, and a row left without text goes. [focus] (an
/// index into the captions) starts on that caption's text.
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
/// its edge as written keeps that edge exactly, as in the region dialog.
class _Row {
  _Row(this.caption, BeatGrid beats)
      : from = TextEditingController(text: beats.format(caption.start)),
        to = TextEditingController(text: beats.format(caption.end)),
        text = TextEditingController(text: caption.text);
  final Caption caption;
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

  static const _rowHeight = 34.0;

  @override
  void initState() {
    super.initState();
    final captions = c.captions.captions;
    final order = [for (var i = 0; i < captions.length; i++) i]..sort((a, b) => captions[a].start.compareTo(captions[b].start));
    _rows = [for (final i in order) _Row(captions[i], _beats)];
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
            ? 'Type a bar, or bar.beat — e.g. 12 or 12.3'
            : b <= a
                ? 'It has to end after it starts'
                : null,
    ];
    final order = [for (var i = 0; i < _rows.length; i++) if (problems[i] == null) i]
      ..sort((x, y) => times[x].$1!.compareTo(times[y].$1!));
    for (var k = 0; k + 1 < order.length; k++) {
      final i = order[k], j = order[k + 1];
      if (times[i].$2! > times[j].$1! + 1e-9) problems[j] = 'Overlaps row ${i + 1}';
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
  void _add() {
    final last = _rows.isEmpty ? null : _end(_rows.last);
    final draft = (last != null && last < _beats.totalQuarters - 1e-9 ? c.captions.draft(last) : null) ??
        c.captions.draft(c.timeline.quarterAtSeconds(c.playback.time.value));
    if (draft == null) return;
    setState(() => _rows.add(_Row(draft, _beats)));
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusCell(_rows.length - 1, 2));
  }

  void _remove(int i) => setState(() => _rows.removeAt(i).dispose());

  void _done() {
    if (_problems().any((p) => p != null)) return;
    Navigator.pop(context, [for (final r in _rows) Caption(_start(r)!, _end(r)!, r.text.text)]);
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
    final header = TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: colors.textMuted);
    return AlertDialog(
      title: const Text('Captions'),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      content: SizedBox(
        width: 640,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DecoratedBox(
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: colors.line))),
            child: SizedBox(
              height: 26,
              child: Row(children: [
                SizedBox(width: 32, child: Text('#', style: header, textAlign: TextAlign.center)),
                SizedBox(width: 88, child: _pad(Text('From', style: header))),
                SizedBox(width: 88, child: _pad(Text('Until', style: header))),
                Expanded(child: _pad(Text('Text', style: header))),
                const SizedBox(width: 32),
              ]),
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: math.max(_rowHeight, MediaQuery.sizeOf(context).height * 0.5)),
            child: _rows.isEmpty
                ? SizedBox(
                    height: _rowHeight * 2,
                    child: Center(child: Text('No captions', style: TextStyle(color: colors.textMuted))),
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
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 24, 20),
      actions: [
        Row(children: [
          TextButton.icon(onPressed: _add, icon: const Icon(Icons.add, size: 18), label: const Text('Add')),
          const Spacer(),
          if (problem != null)
            Flexible(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(problem, style: TextStyle(fontSize: 12, color: colors.erase), overflow: TextOverflow.ellipsis),
              ),
            ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          const SizedBox(width: 8),
          FilledButton(onPressed: invalid ? null : _done, child: const Text('Done')),
        ]),
      ],
    );
  }

  static Widget _pad(Widget child) => Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: child);

  Widget _row(BuildContext context, int i, String? problem) {
    final colors = context.colors;
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
            style: TextStyle(fontSize: 13, color: error ? colors.erase : colors.text),
            decoration: InputDecoration(
              isDense: true,
              counterText: '',
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
              hintText: column == 2 ? 'Empty: removed' : null,
              hintStyle: TextStyle(fontSize: 13, color: colors.textMuted.withValues(alpha: 0.6)),
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
            message: 'Remove',
            child: IconButton(
              iconSize: 16,
              padding: EdgeInsets.zero,
              icon: Icon(Icons.close_rounded, color: colors.textMuted),
              onPressed: () => _remove(i),
            ),
          ),
        ),
      ]),
    );
    return row;
  }
}
