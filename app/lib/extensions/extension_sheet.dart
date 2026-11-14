import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart';

import '../app_colors.dart';
import '../app_icons.dart';
import '../dialog_kit.dart';
import '../ui_kit.dart';
import '../l10n/l10n.dart';
import 'extension_lane.dart' show extensionIconOrNull;

/// A table an extension asks for (`ui.sheet`): a row for each thing it holds, a cell for each
/// of its columns, edited as a sheet is. Tab goes across, ↑ / ↓ and Return up and down (Return
/// on the last row presses the `more` button, to add one); Done hands the rows to `done`, and
/// is off while `check` says a row has something wrong. Cancel, or Esc, asks first once
/// something was changed; a click outside it doesn't close it (a sheet typed would go with it).
///
///     ui.sheet{
///       title = "Captions", width = 640,
///       columns = { {id = "from", label = "From", width = 88}, {id = "text", label = "Text", max = 160} },
///       rows = { {from = "1", text = "Hello"} },
///       buttons = { {id = "add", title = "Add", icon = "add"} }, more = "add",
///       press = function(id, sheet) sheet.add({from = "5", text = ""}, "text") end,
///       check = function(rows) return {} end,
///       done = function(rows) … end,
///     }
///
/// A row is the extension's own table: a text for each column's id, and whatever else it keeps
/// there (what the row stands for). [handle] is the `sheet` its functions get.
Future<void> showExtensionSheet(BuildContext context, ExtensionRuntime runtime, LuaTable spec, SheetHandle handle) async {
  final rows =
      await showAppDialog<LuaTable>(context: context, barrierDismissible: false, builder: (context) => _ExtensionSheet(runtime: runtime, spec: spec, handle: handle));
  handle._state = null;
  final done = spec['done'];
  if (rows != null && done is LuaFunction) runtime.call(done, args: [rows], where: 'ui.sheet done');
}

/// The `sheet` an extension's functions get: the open sheet's rows, read and changed. Once the
/// sheet has closed it has no rows and changes nothing.
class SheetHandle {
  _ExtensionSheetState? _state;

  late final LuaTable table = LuaTable.map({
    'rows': LuaBuiltin('rows', (a) => [_state?._rowsNow() ?? LuaTable.list(const [])]),
    'set': LuaBuiltin('set', (a) {
      final rows = a.table(0, 'set');
      _state?._change((s) => s._set(rows));
      return const [];
    }),
    'add': LuaBuiltin('add', (a) {
      final row = a.table(0, 'add'), column = a.stringOr(1, 'add');
      _state?._change((s) => s._add(row, column));
      return const [];
    }),
    'notice': LuaBuiltin('notice', (a) {
      final text = a.stringOr(0, 'notice');
      _state?._change((s) => s._notice = text);
      return const [];
    }),
    'valid': LuaBuiltin('valid', (a) => [_state?._problems.every((p) => p == null) ?? false]),
  });
}

typedef _Column = ({String id, String label, double? width, int? max, String? hint});
typedef _Problem = ({String text, Set<String> cells});

/// One row's cells. [table] is the extension's own row: the cells' texts are written to it
/// before it is handed back.
class _Row {
  _Row(this.table, List<_Column> columns)
      : cells = [for (final c in columns) TextEditingController(text: switch (table[c.id]) { null => '', final v => Lua.show(v) })],
        focus = [for (final _ in columns) FocusNode()];
  final LuaTable table;
  final List<TextEditingController> cells;
  final List<FocusNode> focus;

  void dispose() {
    for (final c in cells) {
      c.dispose();
    }
    for (final f in focus) {
      f.dispose();
    }
  }
}

class _ExtensionSheet extends StatefulWidget {
  const _ExtensionSheet({required this.runtime, required this.spec, required this.handle});
  final ExtensionRuntime runtime;
  final LuaTable spec;
  final SheetHandle handle;

  @override
  State<_ExtensionSheet> createState() => _ExtensionSheetState();
}

class _ExtensionSheetState extends State<_ExtensionSheet> {
  ExtensionRuntime get _runtime => widget.runtime;
  LuaTable get _spec => widget.spec;
  String _tr(Object? text) => text is String ? _runtime.translate(text) : '';

  late final List<_Column> _columns = [
    if (_spec['columns'] case final LuaTable columns)
      for (final c in columns.array.whereType<LuaTable>())
        if (c['id'] case final String id)
          (
            id: id,
            label: _tr(c['label']),
            width: switch (c['width']) { final num n when n >= 24 && n <= 480 => n.toDouble(), _ => null },
            max: switch (c['max']) { final num n when n >= 1 => n.toInt(), _ => null },
            hint: switch (c['hint']) { final String s => _tr(s), _ => null },
          ),
  ];
  final _rows = <_Row>[];
  final _scroll = ScrollController();

  /// What a button last said (`sheet.notice`), shown while no row has a problem.
  String? _notice;

  /// Whether anything was typed, added, removed or set: Cancel asks before it goes.
  bool _edited = false;

  /// What `check` says of each row as they are: asked once a build, and what `sheet.valid`
  /// answers from.
  List<_Problem?> _problems = const [];
  bool _building = false;

  static const _rowHeight = 34.0;

  @override
  void initState() {
    super.initState();
    widget.handle._state = this;
    if (_spec['rows'] case final LuaTable rows) _rows.addAll([for (final r in rows.array.whereType<LuaTable>()) _Row(r, _columns)]);
    if (_spec['focus'] case final LuaTable focus) {
      if ((focus[1], focus[2]) case (final num row, final String column)) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _focusCell(row.toInt() - 1, _column(column)));
      }
    }
  }

  @override
  void dispose() {
    if (identical(widget.handle._state, this)) widget.handle._state = null;
    for (final r in _rows) {
      r.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  int _column(String? id) => math.max(0, _columns.indexWhere((c) => c.id == id));

  /// The rows as the extension has them, each with its cells as typed.
  LuaTable _rowsNow() {
    for (final r in _rows) {
      for (final (i, c) in _columns.indexed) {
        r.table[c.id] = r.cells[i].text;
      }
    }
    return LuaTable.list([for (final r in _rows) r.table]);
  }

  /// A change an extension's function asks for: not while the sheet is being drawn.
  void _change(void Function(_ExtensionSheetState s) change) {
    if (!mounted) return;
    if (_building) throw LuaError('a sheet can’t be changed while it is drawn');
    setState(() => change(this));
  }

  void _set(LuaTable rows) {
    final next = [for (final r in rows.array.whereType<LuaTable>()) _Row(r, _columns)];
    for (final r in _rows) {
      r.dispose();
    }
    _rows
      ..clear()
      ..addAll(next);
    _edited = true;
  }

  void _add(LuaTable row, String? column) {
    _rows.add(_Row(row, _columns));
    _edited = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusCell(_rows.length - 1, _column(column)));
  }

  List<_Problem?> _check() {
    final check = _spec['check'];
    if (check is! LuaFunction) return List.filled(_rows.length, null);
    final said = _runtime.call(check, args: [_rowsNow()], where: 'ui.sheet check')?.firstOrNull;
    return [
      for (var i = 0; i < _rows.length; i++)
        switch (said is LuaTable ? said[i + 1] : null) {
          final String text => (text: text, cells: const <String>{}),
          final LuaTable t when t[1] is String => (text: t[1]! as String, cells: {...t.array.skip(1).whereType<String>()}),
          _ => null,
        },
    ];
  }

  void _focusCell(int row, int column) {
    if (!mounted || row < 0 || row >= _rows.length || column >= _columns.length) return;
    _rows[row].focus[column].requestFocus();
    final field = _rows[row].cells[column];
    field.selection = TextSelection(baseOffset: 0, extentOffset: field.text.length);
    if (_scroll.hasClients) {
      final top = row * _rowHeight, view = _scroll.position.viewportDimension, at = _scroll.offset;
      if (top < at) _scroll.jumpTo(top);
      if (top + _rowHeight > at + view) _scroll.jumpTo(top + _rowHeight - view);
    }
  }

  void _press(String id) {
    final press = _spec['press'];
    if (press is LuaFunction) _runtime.call(press, args: [id, widget.handle.table], where: 'ui.sheet press');
  }

  void _remove(int i) => setState(() {
        _edited = true;
        _rows.removeAt(i).dispose();
      });

  /// Cancel, or Esc: with something changed, asks before the sheet goes.
  Future<void> _cancel() async {
    if (!_edited) return Navigator.pop(context);
    final discard = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: Text('Discard Your Changes?'.tr),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text('Keep Editing'.tr)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text('Discard'.tr)),
        ],
        confirmsOnReturn: false,
      ),
    );
    if (discard == true && mounted) Navigator.pop(context);
  }

  void _done() {
    if (_check().any((p) => p != null)) return;
    Navigator.pop(context, _rowsNow());
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final problems = _problems = _check();
    final problem = [
      for (final (i, p) in problems.indexed)
        if (p != null) '${i + 1}: ${p.text}',
    ].firstOrNull;
    final invalid = problem != null;
    final status = problem ?? _notice;
    final header = TextStyle(fontSize: AppStyle.of(context).isCarbon ? 12 : 12.5, fontWeight: FontWeight.w600, color: colors.textMuted);
    final buttons = [
      if (_spec['buttons'] case final LuaTable buttons)
        for (final b in buttons.array.whereType<LuaTable>())
          if (b['id'] is String) b,
    ];
    // What each button's `enabled` says of the sheet as it is.
    _building = true;
    final List<bool> enabled;
    try {
      enabled = [
        for (final b in buttons)
          switch (b['enabled']) {
            final LuaFunction f => _runtime.call(f, args: [widget.handle.table], where: 'ui.sheet enabled')?.firstOrNull == true,
            _ => true,
          },
      ];
    } finally {
      _building = false;
    }
    return AppDialog(
      title: Text(_tr(_spec['title'])),
      content: SizedBox(
        width: dialogWidth(context, switch (_spec['width']) { final num n when n >= 320 && n <= 960 => n.toDouble(), _ => 640 }),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DecoratedBox(
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: colors.line))),
            child: SizedBox(
              height: 26,
              child: Row(children: [
                SizedBox(width: 32, child: Text('#', style: header, textAlign: TextAlign.center)),
                for (final c in _columns)
                  if (c.width case final width?) SizedBox(width: width, child: _pad(Text(c.label, style: header))) else Expanded(child: _pad(Text(c.label, style: header))),
                const SizedBox(width: 32),
              ]),
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: math.max(_rowHeight, MediaQuery.sizeOf(context).height * 0.5)),
            child: _rows.isEmpty
                ? SizedBox(
                    height: _rowHeight * 2,
                    child: Center(child: Text(_tr(_spec['empty']), style: TextStyle(color: colors.textMuted))),
                  )
                : ListView.builder(
                    controller: _scroll,
                    shrinkWrap: true,
                    itemCount: _rows.length,
                    itemExtent: _rowHeight,
                    itemBuilder: (context, i) => _row(context, i, i < problems.length ? problems[i] : null),
                  ),
          ),
          const SizedBox(height: 8),
        ]),
      ),
      divided: true,
      onEscape: _cancel,
      leading: [
        for (final (i, b) in buttons.indexed)
          if (extensionIconOrNull(b['icon']) case final icon?)
            TextButton.icon(
                onPressed: enabled[i] ? () => _press(b['id']! as String) : null, icon: Icon(icon.of(context), size: 18), label: Text(_tr(b['title'])))
          else
            TextButton(onPressed: enabled[i] ? () => _press(b['id']! as String) : null, child: Text(_tr(b['title']))),
      ],
      status: status == null
          ? null
          : Text(status, style: TextStyle(color: problem != null ? colors.erase : colors.textMuted), overflow: TextOverflow.ellipsis),
      actions: [
        TextButton(onPressed: _cancel, child: Text('Cancel'.tr)),
        FilledButton(onPressed: invalid ? null : _done, child: Text('Done'.tr)),
      ],
    );
  }

  static Widget _pad(Widget child) => Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: child);

  Widget _row(BuildContext context, int i, _Problem? problem) {
    final colors = context.colors;
    const size = 14.0; // a dialog's text
    final r = _rows[i];

    Widget cell(int column) {
      final c = _columns[column], field = r.cells[column];
      final error = problem != null && problem.cells.contains(c.id);
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
            maxLength: c.max,
            style: TextStyle(fontSize: size, color: error ? colors.erase : colors.text),
            decoration: InputDecoration(
              isDense: true,
              counterText: '',
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
              hintText: c.hint,
              hintStyle: TextStyle(fontSize: size, color: colors.textMuted.withValues(alpha: 0.6)),
            ),
            onChanged: (_) => setState(() => _edited = true),
            // Return goes down a row; on the last one, with its last cell typed, to a new row.
            onSubmitted: (_) => i + 1 < _rows.length
                ? _focusCell(i + 1, column)
                : r.cells.last.text.trim().isEmpty || _spec['more'] is! String
                    ? null
                    : _press(_spec['more']! as String),
          ),
        ),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: colors.grid))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          width: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(border: Border(right: BorderSide(color: colors.grid))),
          child: Text('${i + 1}', style: TextStyle(fontSize: 11.5, color: colors.textMuted)),
        ),
        for (final (k, c) in _columns.indexed)
          if (c.width case final width?) SizedBox(width: width, child: cell(k)) else Expanded(child: cell(k)),
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
  }
}

/// A question an extension asks (`ui.ask`): a title, a line under it, and its buttons after
/// the app's Cancel, the last of them the one Return presses. `done` gets the id of the one
/// pressed; Cancel calls nothing.
Future<void> showExtensionAsk(BuildContext context, ExtensionRuntime runtime, LuaTable spec) async {
  String tr(Object? text) => text is String ? runtime.translate(text) : '';
  final buttons = [
    if (spec['buttons'] case final LuaTable buttons)
      for (final b in buttons.array.whereType<LuaTable>())
        if (b['id'] is String) b,
  ];
  final id = await showAppDialog<String>(
    context: context,
    builder: (context) => AppDialog(
      title: Text(tr(spec['title'])),
      content: spec['text'] is String ? SizedBox(width: dialogWidth(context, 380), child: Text(tr(spec['text']))) : null,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel'.tr)),
        for (final (i, b) in buttons.indexed)
          if (i + 1 == buttons.length)
            FilledButton(onPressed: () => Navigator.pop(context, b['id']! as String), child: Text(tr(b['title'])))
          else
            TextButton(onPressed: () => Navigator.pop(context, b['id']! as String), child: Text(tr(b['title']))),
      ],
    ),
  );
  final done = spec['done'];
  if (id != null && done is LuaFunction) runtime.call(done, args: [id], where: 'ui.ask done');
}
