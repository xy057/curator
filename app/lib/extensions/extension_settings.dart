import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart';

import '../app_colors.dart';
import '../dialog_kit.dart';
import '../ui_kit.dart';
import '../l10n/l10n.dart';
import 'extension_reader.dart';

/// An extension's own settings (its `settings` socket), for every project: the dialog its
/// menu's Settings… opens. [runtime]'s `settings.form` gives the rows and takes each change.
Future<void> showExtensionSettings(BuildContext context, ExtensionRuntime runtime) => showAppDialog<void>(
      context: context,
      builder: (context) => AppDialog(
        title: Text(runtime.translate(runtime.package.name)),
        content: ExtensionSettingsForm(runtime: runtime),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text('Done'.tr))],
      ),
    );

/// The settings an extension's `settings.form` describes, a row each with its name at the
/// left: a "switch", "segments" (one of its `options`: {value, label}) or a "font" (a text
/// font's family; '' is none, named `none`). `changed(values)` is called as one is changed,
/// and `preview(values)` says what is drawn under them: {caption, style}, a caption as the
/// scene would draw it.
class ExtensionSettingsForm extends StatefulWidget {
  const ExtensionSettingsForm({super.key, required this.runtime});
  final ExtensionRuntime runtime;

  @override
  State<ExtensionSettingsForm> createState() => _ExtensionSettingsFormState();
}

class _ExtensionSettingsFormState extends State<ExtensionSettingsForm> {
  ExtensionRuntime get _runtime => widget.runtime;
  late final LuaTable? _spec = switch (_runtime.nodes('settings').firstOrNull) {
    final node? => switch (_runtime.ask(node.id, 'form')) { final LuaTable t => t, _ => null },
    null => null,
  };
  late final List<LuaTable> _rows = [
    if (_spec?['rows'] case final LuaTable rows)
      for (final r in rows.array.whereType<LuaTable>())
        if (r['id'] is String) r,
  ];
  late final Map<String, Object?> _values = {for (final r in _rows) r['id']! as String: r['value']};
  var _installed = const <String>[];

  @override
  void initState() {
    super.initState();
    if (_rows.any((r) => r['type'] == 'font')) {
      TextFonts.installed().then((families) {
        if (mounted) setState(() => _installed = families);
      });
    }
  }

  String _tr(Object? text) => text is String ? _runtime.translate(text) : '';
  LuaTable get _table => LuaTable.map({..._values});

  void _set(String id, Object? value) {
    if (_values[id] == value) return;
    setState(() => _values[id] = value);
    if (_spec?['changed'] case final LuaFunction changed) _runtime.call(changed, args: [_table], where: 'settings changed');
  }

  Widget _field(LuaTable row) {
    final id = row['id']! as String, value = _values[id];
    switch (row['type']) {
      case 'font':
        final families = [TextFonts.academico, ..._installed.where((f) => f != TextFonts.academico)];
        final chosen = value is String ? value : '';
        return dialogMenuField(
          context,
          menu: (decoration, textStyle, arrow) => DropdownMenu<String>(
            key: ValueKey((chosen, families.length)),
            expandedInsets: EdgeInsets.zero,
            inputDecorationTheme: decoration,
            textStyle: textStyle,
            trailingIcon: arrow,
            selectedTrailingIcon: arrow,
            initialSelection: chosen,
            enableFilter: true,
            requestFocusOnTap: true,
            menuHeight: 320,
            dropdownMenuEntries: [
              DropdownMenuEntry(value: '', label: _tr(row['none'])),
              for (final f in families) DropdownMenuEntry(value: f, label: f),
            ],
            onSelected: (f) {
              if (f != null) _set(id, f);
            },
          ),
        );
      case 'segments':
        final options = [
          if (row['options'] case final LuaTable options)
            for (final o in options.array.whereType<LuaTable>())
              if (o['value'] != null) o,
        ];
        if (options.isEmpty) return const SizedBox.shrink();
        return AppSegmented<Object>(
          segments: [for (final o in options) ButtonSegment(value: o['value']!, label: Text(_tr(o['label'])))],
          selected: options.any((o) => o['value'] == value) ? value! : options.first['value']!,
          onChanged: (v) => _set(id, v),
        );
      default:
        return AppSwitch(value: value == true, onChanged: (v) => _set(id, v));
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = switch (_spec?['preview']) {
      final LuaFunction preview => switch (_runtime.call(preview, args: [_table], where: 'settings preview')?.firstOrNull) { final LuaTable t => t, _ => null },
      _ => null,
    };
    return SizedBox(
      width: 400,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final row in _rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              SizedBox(width: 88, child: Text(_tr(row['label']))),
              Expanded(child: Align(alignment: Alignment.centerLeft, child: _field(row))),
            ]),
          ),
        if (shown?['caption'] case final String caption) ...[
          const SizedBox(height: 8),
          _CaptionPreview(text: caption, ask: captionAsk(shown?['style'])),
        ],
      ]),
    );
  }
}

/// A caption drawn as [ask] makes it, its countdown part run.
class _CaptionPreview extends StatelessWidget {
  const _CaptionPreview({required this.text, required this.ask});
  final String text;
  final CaptionAsk ask;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final name = ask.font;
    final family = name.isEmpty || name == TextFonts.academico ? TextFonts.familyOf(TextFonts.academico) : TextFonts.familyOf(name);
    return FutureBuilder<void>(
      future: name.isEmpty || name == TextFonts.academico ? null : TextFonts.faces(name).then((f) => f == null ? null : TextFonts.load(name, f)),
      builder: (context, _) => Container(
        height: 96,
        decoration: BoxDecoration(color: colors.scorePaper, border: Border.all(color: colors.line), borderRadius: AppStyle.of(context).radius(8)),
        child: ClipRRect(
          borderRadius: AppStyle.of(context).radius(8),
          child: CustomPaint(
            size: Size.infinite,
            painter: _PreviewPainter(
              text,
              CaptionStyle(fontFamily: family, countdown: ask.countdown, size: ask.size, align: ask.align, plate: ask.plate),
              colors.scoreInk,
              colors.scorePaper,
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewPainter extends CustomPainter {
  _PreviewPainter(this.text, this.style, this.ink, this.paper);
  final String text;
  final CaptionStyle style;
  final Color ink, paper;

  @override
  void paint(Canvas canvas, Size size) {
    // Laid out for this paint alone, and let go after it: a bar keeps its texts until disposed.
    CaptionBar(TextFonts.familyOf(TextFonts.academico), style)
      ..paint(canvas, size, 6, const [(caption: 0, start: 0.0, end: 10.0)], [Caption(0, 1, text)], ink, paper: paper)
      ..dispose();
  }

  @override
  bool shouldRepaint(_PreviewPainter old) => old.text != text || old.style != style || old.ink != ink || old.paper != paper;
}
