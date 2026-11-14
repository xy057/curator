import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart';

import '../app_colors.dart';
import '../dialog_kit.dart';
import '../ui_kit.dart';
import '../l10n/l10n.dart';

/// A dialog an extension asks for (`ui.form`), laid out as the app's own are: [spec] says its
/// title, its fields row by row, its buttons, and the functions that check what is typed and
/// take the answer.
///
///     ui.form{
///       title = "Add Chapter", confirm = "Add", width = 400,
///       rows = { { {id = "name", label = "Name", value = "", max = 80, flex = 3, focus = true},
///                  {id = "at", label = "From", value = "12"} } },
///       leading = { {id = "remove", title = "Remove"} },
///       check = function(values) return values.name == "" and "" or nil end,
///       done = function(values, button) … end,
///     }
///
/// `check` gives nil when the form can be confirmed, a text when it can't (shown), or "" when
/// it can't and there is nothing to say (a field still empty). `done` is called with the values
/// by field id and the button pressed: "confirm", or a leading button's id; Cancel calls nothing.
/// Every text of it is translated as the extension's ([ExtensionRuntime.translate]).
Future<void> showExtensionForm(BuildContext context, ExtensionRuntime runtime, LuaTable spec) async {
  final result = await showAppDialog<({String button, LuaTable values})>(context: context, builder: (context) => _ExtensionForm(runtime: runtime, spec: spec));
  final done = spec['done'];
  if (result == null || done is! LuaFunction) return;
  runtime.call(done, args: [result.values, result.button], where: 'ui.form done');
}

/// A line of an extension's, shown for a moment at the window's foot.
void showExtensionMessage(BuildContext context, String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

class _Field {
  _Field(this.id, this.spec, this.kind);
  final String id;
  final LuaTable spec;

  /// "text" or "switch".
  final String kind;
  TextEditingController? text;
  bool on = false;

  String get label => switch (spec['label']) { final String s => s, _ => '' };
  int get flex => switch (spec['flex']) { final num n when n >= 1 => n.toInt(), _ => 1 };
}

class _ExtensionForm extends StatefulWidget {
  const _ExtensionForm({required this.runtime, required this.spec});
  final ExtensionRuntime runtime;
  final LuaTable spec;

  @override
  State<_ExtensionForm> createState() => _ExtensionFormState();
}

class _ExtensionFormState extends State<_ExtensionForm> {
  late final List<List<_Field>> _rows = _read();

  ExtensionRuntime get _runtime => widget.runtime;
  String _tr(Object? text) => text is String ? _runtime.translate(text) : '';

  List<List<_Field>> _read() {
    final rows = <List<_Field>>[];
    final spec = widget.spec['rows'];
    if (spec is! LuaTable) return rows;
    for (final row in spec.array) {
      if (row is! LuaTable) continue;
      // A field alone is a row of one.
      final fields = row['id'] is String ? [row] : row.array.whereType<LuaTable>();
      rows.add([
        for (final f in fields)
          if (f['id'] case final String id) _field(id, f),
      ]);
    }
    return rows;
  }

  _Field _field(String id, LuaTable spec) {
    final kind = spec['type'] == 'switch' ? 'switch' : 'text';
    final field = _Field(id, spec, kind);
    if (kind == 'switch') {
      field.on = spec['value'] == true;
    } else {
      field.text = TextEditingController(text: switch (spec['value']) { null => '', final v => Lua.show(v) });
    }
    return field;
  }

  @override
  void dispose() {
    for (final row in _rows) {
      for (final f in row) {
        f.text?.dispose();
      }
    }
    super.dispose();
  }

  LuaTable get _values {
    final values = LuaTable()..shape = LuaShape.map;
    for (final row in _rows) {
      for (final f in row) {
        values[f.id] = f.kind == 'switch' ? f.on : f.text!.text;
      }
    }
    return values;
  }

  /// What `check` says of the form as it is: null when it can be confirmed.
  String? get _problem {
    final check = widget.spec['check'];
    if (check is! LuaFunction) return null;
    final result = _runtime.call(check, args: [_values], where: 'ui.form check');
    return switch (result?.firstOrNull) { final String s => s, _ => result == null ? '' : null };
  }

  void _close(String button) => Navigator.pop(context, (button: button, values: _values));

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec, problem = _problem;
    void confirm() {
      if (problem == null) _close('confirm');
    }

    Widget control(_Field f) {
      if (f.kind == 'switch') {
        return AppCheckRow(value: f.on, named: true, label: _tr(f.label), onChanged: (v) => setState(() => f.on = v ?? false));
      }
      return AppTextField(
        controller: f.text!,
        label: _tr(f.label),
        hint: f.spec['hint'] is String ? _tr(f.spec['hint']) : null,
        autofocus: f.spec['focus'] == true,
        maxLength: switch (f.spec['max']) { final num n when n >= 1 => n.toInt(), _ => null },
        lines: switch (f.spec['lines']) { final num n when n >= 1 => n.toInt(), _ => 1 },
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => confirm(),
      );
    }

    final leading = spec['leading'];
    return AppDialog(
      title: Text(_tr(spec['title'])),
      content: SizedBox(
        width: dialogWidth(context, switch (spec['width']) { final num n when n >= 200 && n <= 640 => n.toDouble(), _ => 400 }),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final (i, row) in _rows.indexed) ...[
            if (i > 0) const SizedBox(height: 12),
            if (row.length == 1)
              control(row.single)
            else
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final (k, f) in row.indexed) ...[
                  if (k > 0) const SizedBox(width: 16),
                  Expanded(flex: f.flex, child: control(f)),
                ],
              ]),
          ],
        ]),
      ),
      status: problem == null || problem.isEmpty ? null : Text(_tr(problem), style: TextStyle(color: context.colors.erase)),
      leading: [
        if (leading is LuaTable)
          for (final b in leading.array.whereType<LuaTable>())
            if (b['id'] case final String id) TextButton(onPressed: () => _close(id), child: Text(_tr(b['title']))),
      ],
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel'.tr)),
        FilledButton(onPressed: problem == null ? confirm : null, child: Text(_tr(spec['confirm'] ?? 'OK'))),
      ],
    );
  }
}
