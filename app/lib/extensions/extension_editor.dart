import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart';

import '../app_icons.dart';
import '../script_editor.dart';
import '../ui_kit.dart';
import '../l10n/l10n.dart';
import 'connector_view.dart';
import 'extension_docs.dart';

/// Opens the extension editor on [package], over the whole window. Returns the extension as
/// edited (Done); null when it was left as it is. With [onRun], Run (⌘R) hands the extension
/// as it stands to the project without closing, and what it then prints and what goes wrong in
/// it ([log], [problems]) show under the code. [readOnly]: one of Curator's own, to read.
Future<ExtensionPackage?> showExtensionEditor(
  BuildContext context,
  ExtensionPackage package, {
  bool readOnly = false,
  bool unsaved = false,
  void Function(ExtensionPackage package)? onRun,
  Map<String, int>? Function()? calls,
  ValueListenable<List<ExtensionProblem>>? problems,
  ValueListenable<List<String>>? log,
}) =>
    Navigator.of(context, rootNavigator: true).push<ExtensionPackage>(PageRouteBuilder(
      fullscreenDialog: true,
      transitionDuration: motion(context, 200),
      reverseTransitionDuration: motion(context, 160),
      pageBuilder: (_, _, _) => ExtensionEditor(package: package, readOnly: readOnly, unsaved: unsaved, onRun: onRun, calls: calls, problems: problems, log: log),
      transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic), child: child),
    ));

/// An extension's files edited together ([ScriptEditorState]), its connector first, as a
/// picture ([ConnectorView]): what Curator calls in it, wired to its functions.
class ExtensionEditor extends ScriptEditor<ExtensionPackage> {
  const ExtensionEditor(
      {super.key, required super.package, super.readOnly, this.unsaved = false, super.onRun, this.calls, super.problems, super.log});

  /// One of Curator's own: edited and run as any, and never saved (it says so by its name).
  final bool unsaved;

  /// How often each of its ports has been called as it runs in the project; null: it isn't running.
  final Map<String, int>? Function()? calls;

  @override
  State<ExtensionEditor> createState() => _ExtensionEditorState();
}

const _connector = '\u0000connector';

class _ExtensionEditorState extends ScriptEditorState<ExtensionEditor, ExtensionPackage> {
  late ConnectorGraph _graph = widget.package.graph;

  /// Each file's functions, read when it last changed; null: it doesn't read.
  final _functions = <String, (String, List<FileFunction>?)>{};

  @override
  List<ScriptProblem> check(ExtensionPackage package) => checkExtension(package);

  @override
  ExtensionPackage packageOf({required Map<String, Object?> manifest, required Map<String, String> sources, required String? readme}) =>
      ExtensionPackage(manifest: manifest, graph: _graph, sources: sources, locales: widget.package.locales, assets: widget.package.assets, readme: readme);

  @override
  String get title => widget.readOnly ? 'Extension'.tr : 'Edit Extension'.tr;
  @override
  String get discardText => 'The extension stays as it was.'.tr;
  @override
  String get shownName => widget.unsaved ? '${package.name} · ${'Not Saved'.tr}' : package.name;
  @override
  String get firstShown => _connector;
  @override
  String get manifestFile => 'extension.json';
  @override
  String? shownFor(String file) => file == 'connect.json' ? _connector : super.shownFor(file);

  @override
  String get guideAsset => extensionGuideAsset;
  @override
  Widget docsBar(String title) => ExtensionDocsBar(title: title);
  @override
  Widget reference(ValueChanged<String>? onInsert) => ExtensionReference(onInsert: onInsert);
  @override
  List<ApiLibrary> get libraries => ExtensionApi.libraries;

  @override
  String? get idHelper =>
      ExtensionPackage.isThirdPartyId(fields['id']!.text.trim()) || widget.readOnly || widget.unsaved ? null : 'Like com.example.notes: lower-case, with a dot'.tr;
  @override
  String get aboutLine => '${'API level'.tr}: ${package.api} · ${'Data version'.tr}: ${package.dataVersion}';

  Map<String, List<FileFunction>?> get _functionsNow => {
        for (final MapEntry(key: path, value: c) in code.entries) path: _functionsOf(path, c.text),
      };

  List<FileFunction>? _functionsOf(String path, String source) {
    final kept = _functions[path];
    if (kept != null && kept.$1 == source) return kept.$2;
    List<FileFunction>? found;
    try {
      found = Lua.functionsIn(source, chunk: path);
    } on LuaError {
      found = null;
    }
    _functions[path] = (source, found);
    return found;
  }

  /// Shows [file] where [function] is in it (a wire opened in the connector), or at its top.
  void _open(String file, String? function) {
    final path = codePath(file), c = code[path];
    goTo(file, function == null || c == null ? null : _functionsOf(path, c.text)?.where((f) => f.name == function).firstOrNull?.line);
  }

  @override
  void fileRenamed(String from, String to) {
    _functions.remove(from);
    _graph = _graph.copyWith(
      wires: [for (final w in _graph.wires) w.file == from ? GraphWire(w.from, '$to#${w.function}') : w],
      files: {for (final MapEntry(:key, :value) in _graph.files.entries) key == from ? to : key: value},
    );
  }

  @override
  void fileRemoved(String path) {
    _functions.remove(path);
    _graph = _graph.copyWith(
      wires: [for (final w in _graph.wires) if (w.file != path) w],
      files: {for (final MapEntry(:key, :value) in _graph.files.entries) if (key != path) key: value},
    );
  }

  /// Writes a function for [port] of [node] into [file], before the `return` at its end when
  /// its functions are on a table; returns its name.
  String? _createFunction(String file, GraphNode node, ApiPort port) {
    final c = code[file];
    if (c == null) return null;
    final source = c.text, taken = {...?_functionsOf(file, source)?.map((f) => f.name)};
    var name = node.type == 'project' ? port.name : '${node.id}_${port.name}';
    for (var n = 2; taken.contains(name); n++) {
      name = '${node.id}_${port.name}$n';
    }
    final open = port.signature.indexOf('('), close = port.signature.indexOf(')');
    final parameters = open < 0 || close < open ? '' : port.signature.substring(open + 1, close);
    final table = RegExp(r'\n\s*return\s+([A-Za-z_][A-Za-z0-9_]*)\s*$').firstMatch(source.trimRight());
    final comment = '-- ${node.id}.${port.name}: ${port.summary}';
    if (table != null) {
      final at = table.start;
      c.text = '${source.substring(0, at).trimRight()}\n\n$comment\nfunction ${table[1]}.$name($parameters)\nend\n${source.substring(at).trimRight()}\n';
    } else {
      c.text = '${source.trimRight()}${source.trim().isEmpty ? '' : '\n\n'}$comment\nfunction $name($parameters)\nend\n';
    }
    return name;
  }

  @override
  List<Widget> leadingTiles(BuildContext context) => [
        SidebarTile(icon: AppIcon.link.of(context), label: 'Connector'.tr, selected: shown == _connector, onTap: () => setState(() => shown = _connector)),
      ];

  @override
  Widget? ownBody(BuildContext context) => shown != _connector
      ? null
      : ConnectorView(
          graph: _graph,
          functions: _functionsNow,
          readOnly: widget.readOnly,
          onChanged: (graph) {
            setState(() => _graph = graph);
            changed();
          },
          onOpen: _open,
          onCreate: _createFunction,
          problems: {
            for (final p in [...?widget.problems?.value])
              if (p.extension == '${manifest['id']}') ?p.where: p.message,
          },
          calls: widget.calls,
        );
}
