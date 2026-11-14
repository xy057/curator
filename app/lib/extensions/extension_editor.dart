import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:re_editor/re_editor.dart';
import 'package:score_engine/score_engine.dart';

import '../app_colors.dart';
import '../app_icons.dart';
import '../code_view.dart';
import '../dialog_kit.dart';
import '../lilypond_dialog.dart' show monospace;
import '../lua_language.dart';
import '../markdown_text.dart';
import '../menu_kit.dart';
import '../ui_kit.dart';
import '../l10n/l10n.dart';
import 'connector_view.dart';

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

/// The guide the editor's Help shows.
const extensionGuideAsset = 'assets/help/extensions.md';

/// What the editor shows at its right.
enum _Side { none, reference, help }

/// An extension's files edited together: its connector as a picture ([ConnectorView]), its Lua
/// ([CodeView], coloured and prompted by `lua_language.dart`), what extension.json says of it
/// (About), and its README; beside them the API's reference ([ExtensionApi], a click puts a
/// function in the code) and a guide; under them what is wrong with it as it is written
/// ([checkExtension], as it is typed) and, once run, what it printed and what went wrong.
class ExtensionEditor extends StatefulWidget {
  const ExtensionEditor({super.key, required this.package, this.readOnly = false, this.unsaved = false, this.onRun, this.calls, this.problems, this.log});
  final ExtensionPackage package;
  final bool readOnly;

  /// One of Curator's own: edited and run as any, and never saved (it says so by its name).
  final bool unsaved;
  final void Function(ExtensionPackage package)? onRun;

  /// How often each of its ports has been called as it runs in the project; null: it isn't running.
  final Map<String, int>? Function()? calls;
  final ValueListenable<List<ExtensionProblem>>? problems;
  final ValueListenable<List<String>>? log;

  @override
  State<ExtensionEditor> createState() => _ExtensionEditorState();
}

const _connector = '\u0000connector', _about = '\u0000about', _readmeView = '\u0000readme';

class _ExtensionEditorState extends State<ExtensionEditor> {
  late Map<String, Object?> _manifest = {...widget.package.manifest};
  late ConnectorGraph _graph = widget.package.graph;
  late final Map<String, CodeLineEditingController> _code = {
    for (final MapEntry(key: path, value: source) in widget.package.sources.entries) path: _file(source),
  };
  late final _readme = _watched(CodeLineEditingController.fromText(widget.package.readme ?? ''));
  final _finds = <String, CodeFindController>{};
  final _focus = FocusNode(debugLabel: 'extension code');

  /// About's fields, by their key in extension.json.
  late final Map<String, TextEditingController> _fields = {
    for (final key in const ['name', 'id', 'version', 'summary', 'author', 'url', 'keywords'])
      key: TextEditingController(text: switch (_manifest[key]) { final String s => s, _ => '' }),
  };

  String _shown = _connector;
  _Side _side = _Side.reference;

  /// What is wrong with it as written, found a moment after the last change.
  List<ExtensionProblem> _problems = const [];
  Timer? _checking;

  /// Each file's functions, read when it last changed; null: it doesn't read.
  final _functions = <String, (String, List<FileFunction>?)>{};

  CodeLineEditingController _watched(CodeLineEditingController c) => c..addListener(_changed);
  CodeLineEditingController _file(String source) => _watched(luaCode(source));

  @override
  void initState() {
    super.initState();
    _problems = checkExtension(widget.package);
    widget.problems?.addListener(_repaint);
    widget.log?.addListener(_repaint);
  }

  @override
  void dispose() {
    _checking?.cancel();
    widget.problems?.removeListener(_repaint);
    widget.log?.removeListener(_repaint);
    for (final c in [..._code.values, _readme]) {
      c
        ..removeListener(_changed)
        ..dispose();
    }
    for (final f in _finds.values) {
      f.dispose();
    }
    for (final f in _fields.values) {
      f.dispose();
    }
    _focus.dispose();
    super.dispose();
  }

  /// Shown again: now, or after the frame being built (a code view tells of its text as it is
  /// first laid out).
  void _repaint() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _repaint());
    } else {
      setState(() {});
    }
  }

  /// Something of it changed: the toolbar follows now, the check a moment later.
  void _changed() {
    if (!mounted) return;
    _repaint();
    _checking?.cancel();
    _checking = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _problems = checkExtension(_package));
    });
  }

  /// The extension as it stands.
  ExtensionPackage get _package => ExtensionPackage(
        manifest: _manifest,
        graph: _graph,
        sources: {for (final MapEntry(key: path, value: c) in _code.entries) path: c.text},
        locales: widget.package.locales,
        assets: widget.package.assets,
        readme: _readme.text.isEmpty && widget.package.readme == null ? null : _readme.text,
      );

  bool get _edited => _package != widget.package;

  Map<String, List<FileFunction>?> get _functionsNow => {
        for (final MapEntry(key: path, value: c) in _code.entries) path: _functionsOf(path, c.text),
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

  // MARK: Leaving

  Future<void> _cancel() async {
    if (widget.readOnly || !_edited) return Navigator.of(context).pop();
    final discard = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: Text('Discard Your Changes?'.tr),
        content: Text('The extension stays as it was.'.tr),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text('Keep Editing'.tr)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text('Discard'.tr)),
        ],
        confirmsOnReturn: false,
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  void _done() => Navigator.of(context).pop(_edited ? _package : null);

  void _run() {
    if (widget.readOnly) return;
    setState(() => _problems = checkExtension(_package));
    widget.onRun?.call(_package);
  }

  // MARK: Files

  void _goTo(String? file, int? line, [String? function]) {
    final path = file == null ? null : (file.startsWith('src/') ? file.substring(4) : file);
    final c = _code[path];
    if (c == null) {
      if (file == 'connect.json') setState(() => _shown = _connector);
      if (file == 'extension.json') setState(() => _shown = _about);
      return;
    }
    line ??= _functionsOf(path!, c.text)?.where((f) => f.name == function).firstOrNull?.line;
    setState(() => _shown = path!);
    if (line == null) return;
    final index = (line - 1).clamp(0, c.codeLines.length - 1);
    c.selection = CodeLineSelection.collapsed(index: index, offset: 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      c.makeCursorCenterIfInvisible();
      _focus.requestFocus();
    });
  }

  static final _fileName = RegExp(r'^[A-Za-z0-9_]+(/[A-Za-z0-9_]+)*\.lua$');

  /// Asks for a file's name ([from]: the one it has); null: cancelled.
  Future<String?> _askFileName({String? from}) {
    final name = TextEditingController(text: from ?? '');
    return showAppDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, setState) {
        final text = name.text.trim();
        final problem = text.isEmpty || text == from
            ? ''
            : !_fileName.hasMatch(text)
                ? 'Use letters, digits and _, ending in .lua'.tr
                : _code.containsKey(text)
                    ? 'Another file has this name'.tr
                    : null;
        return AppDialog(
          title: Text(from == null ? 'New File'.tr : 'Rename File'.tr),
          content: SizedBox(
            width: dialogWidth(context, 340),
            child: AppTextField(
              controller: name,
              label: 'Name',
              hint: 'util.lua',
              autofocus: true,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => problem == null ? Navigator.pop(context, text) : null,
            ),
          ),
          status: problem == null || problem.isEmpty ? null : Text(problem, style: TextStyle(color: context.colors.erase)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel'.tr)),
            FilledButton(onPressed: problem == null ? () => Navigator.pop(context, text) : null, child: Text(from == null ? 'Add'.tr : 'Rename'.tr)),
          ],
        );
      }),
    ).whenComplete(name.dispose);
  }

  Future<void> _addFile() async {
    final path = await _askFileName();
    if (path == null || !mounted) return;
    setState(() {
      _code[path] = _file('local M = {}\n\nreturn M\n');
      _shown = path;
    });
    _changed();
  }

  Future<void> _renameFile(String path) async {
    final to = await _askFileName(from: path);
    if (to == null || !mounted) return;
    setState(() {
      final c = _code.remove(path)!;
      _code[to] = c;
      _finds.remove(path)?.dispose();
      _functions.remove(path);
      _graph = _graph.copyWith(
        wires: [for (final w in _graph.wires) w.file == path ? GraphWire(w.from, '$to#${w.function}') : w],
        files: {for (final MapEntry(:key, :value) in _graph.files.entries) key == path ? to : key: value},
      );
      if (_shown == path) _shown = to;
    });
    _changed();
  }

  void _removeFile(String path) {
    setState(() {
      _code.remove(path)
        ?..removeListener(_changed)
        ..dispose();
      _finds.remove(path)?.dispose();
      _functions.remove(path);
      _graph = _graph.copyWith(
        wires: [for (final w in _graph.wires) if (w.file != path) w],
        files: {for (final MapEntry(:key, :value) in _graph.files.entries) if (key != path) key: value},
      );
      if (_shown == path) _shown = _connector;
    });
    _changed();
  }

  /// Writes a function for [port] of [node] into [file], before the `return` at its end when
  /// its functions are on a table; returns its name.
  String? _createFunction(String file, GraphNode node, ApiPort port) {
    final c = _code[file];
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

  /// Puts [text] in the code where the caret is (a function clicked in the Reference).
  void _insert(String text) {
    final c = _code[_shown];
    if (c == null || widget.readOnly) return;
    c.replaceSelection(text);
    _focus.requestFocus();
  }

  // MARK: The window

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) _cancel();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyR, meta: true): _run,
          const SingleActivator(LogicalKeyboardKey.keyR, control: true): _run,
        },
        child: Material(
          color: colors.surface,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _toolbar(context),
            Divider(height: 1, color: colors.line),
            Expanded(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _files(context),
                VerticalDivider(width: 1, color: colors.line),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Expanded(child: _body(context)),
                    ..._under(context),
                  ]),
                ),
                if (_side != _Side.none) ...[
                  VerticalDivider(width: 1, color: colors.line),
                  SizedBox(
                    width: 340,
                    child: _side == _Side.reference
                        ? ExtensionReference(onInsert: _code.containsKey(_shown) && !widget.readOnly ? _insert : null)
                        : const _Guide(),
                  ),
                ],
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _toolbar(BuildContext context) {
    final colors = context.colors, style = AppStyle.of(context);
    final c = _code[_shown] ?? (_shown == _readmeView ? _readme : null);
    return Container(
      height: style.toolbar + 8,
      color: colors.chrome,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        Text(widget.readOnly ? 'Extension'.tr : 'Edit Extension'.tr, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: colors.text)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(widget.unsaved ? '${_package.name} · ${'Not Saved'.tr}' : _package.name, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: colors.textMuted)),
        ),
        if (c != null) ...[
          if (!widget.readOnly) ...[
            ToolbarButton(icon: AppIcon.undo.of(context), tooltip: 'Undo ({key})'.fill({'key': shortcut('⌘Z')}), onPressed: c.canUndo ? c.undo : null),
            ToolbarButton(
                icon: AppIcon.redo.of(context), tooltip: 'Redo ({key})'.fill({'key': shortcut('⇧⌘Z', 'Ctrl+Y')}), onPressed: c.canRedo ? c.redo : null),
          ],
          ToolbarButton(
              icon: AppIcon.search.of(context),
              tooltip: 'Find ({key})'.fill({'key': shortcut('⌘F')}),
              onPressed: () => _finds[_shown]
                ?..findMode()
                ..focusOnFindInput()),
          const ToolbarDivider(),
        ],
        ToolbarButton(
          icon: AppIcon.code.of(context),
          tooltip: 'Reference'.tr,
          selected: _side == _Side.reference,
          onPressed: () => setState(() => _side = _side == _Side.reference ? _Side.none : _Side.reference),
        ),
        ToolbarButton(
          icon: AppIcon.website.of(context),
          tooltip: 'Help'.tr,
          selected: _side == _Side.help,
          onPressed: () => setState(() => _side = _side == _Side.help ? _Side.none : _Side.help),
        ),
        const ToolbarDivider(),
        if (widget.readOnly)
          FilledButton(onPressed: () => Navigator.of(context).pop(), child: Text('Close'.tr))
        else ...[
          if (widget.onRun != null) ...[
            Tip(
              message: 'Run ({key})'.fill({'key': shortcut('⌘R')}),
              child: OutlinedButton(onPressed: _run, child: Text('Run'.tr)),
            ),
            const ToolbarDivider(),
          ],
          OutlinedButton(onPressed: _cancel, child: Text('Cancel'.tr)),
          const SizedBox(width: 8),
          FilledButton(onPressed: _done, child: Text('Done'.tr)),
        ],
      ]),
    );
  }

  /// What the extension is made of, to choose what shows: its connector, what it says of
  /// itself, its files, its README.
  Widget _files(BuildContext context) {
    final colors = context.colors;
    final paths = _code.keys.toList()..sort();
    Widget heading(String text, {Widget? trailing}) => Padding(
          padding: const EdgeInsets.fromLTRB(10, 14, 4, 4),
          child: Row(children: [
            Expanded(child: Text(text, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: colors.textMuted))),
            ?trailing,
          ]),
        );
    return Container(
      width: 210,
      color: colors.chrome,
      child: ListView(padding: const EdgeInsets.all(8), children: [
        SidebarTile(icon: AppIcon.link.of(context), label: 'Connector'.tr, selected: _shown == _connector, onTap: () => setState(() => _shown = _connector)),
        SidebarTile(icon: AppIcon.about.of(context), label: 'About'.tr, selected: _shown == _about, onTap: () => setState(() => _shown = _about)),
        heading(
          'Files'.trIn('heading'),
          trailing: widget.readOnly
              ? null
              : Tip(
                  message: 'New File'.tr,
                  child: IconButton(
                    iconSize: 15,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints.tightFor(width: 24, height: 24),
                    padding: EdgeInsets.zero,
                    color: colors.textMuted,
                    onPressed: _addFile,
                    icon: Icon(AppIcon.add.of(context)),
                  ),
                ),
        ),
        for (final path in paths)
          SidebarTile(
            key: ValueKey(path),
            icon: AppIcon.code.of(context),
            label: path,
            selected: _shown == path,
            onTap: () => setState(() => _shown = path),
            trailing: widget.readOnly
                ? null
                : AppPopupMenuButton<VoidCallback>(
                    tooltip: 'File'.tr,
                    padding: EdgeInsets.zero,
                    iconSize: 14,
                    constraints: const BoxConstraints(minWidth: 140),
                    icon: Icon(AppIcon.more.of(context), color: _code[path]!.text != widget.package.sources[path] ? colors.accent : colors.textMuted),
                    onSelected: (action) => action(),
                    itemBuilder: (context) => [
                      menuItem(context, value: () => _renameFile(path), child: Text('Rename…'.tr)),
                      menuItem(context, value: () => _removeFile(path), child: Text('Delete'.tr)),
                    ],
                  ),
          ),
        const SizedBox(height: 6),
        SidebarTile(icon: AppIcon.copy.of(context), label: 'README', selected: _shown == _readmeView, onTap: () => setState(() => _shown = _readmeView)),
      ]),
    );
  }

  Widget _body(BuildContext context) {
    if (_shown == _connector) {
      return ConnectorView(
        graph: _graph,
        functions: _functionsNow,
        readOnly: widget.readOnly,
        onChanged: (graph) {
          setState(() => _graph = graph);
          _changed();
        },
        onOpen: (file, function) => _goTo(file, null, function),
        onCreate: _createFunction,
        problems: {
          for (final p in [...?widget.problems?.value])
            if (p.extension == '${_manifest['id']}') ?p.where: p.message,
        },
        calls: widget.calls,
      );
    }
    if (_shown == _about) return _aboutPage(context);
    final code = _code[_shown] ?? _readme;
    return KeyedSubtree(
      key: ValueKey(_shown),
      child: CodeView(
        controller: code,
        findController: _finds[_shown] ??= CodeFindController(code),
        focusNode: _focus,
        readOnly: widget.readOnly,
        prompts: _shown == _readmeView ? const _NoPrompts() : LuaPrompts(() => code.text),
        kindOf: _kind,
      ),
    );
  }

  static String? _kind(CodePrompt prompt) => prompt is! LuaPrompt
      ? null
      : prompt.function?.signature ??
          switch (prompt.kind) {
            LuaKind.keyword => 'keyword'.trIn('lua'),
            LuaKind.function => 'function'.trIn('lua'),
            LuaKind.library => 'library'.trIn('lua'),
            LuaKind.value => 'value'.trIn('lua'),
            LuaKind.local => null,
          };

  /// What extension.json says: its name, id, version, summary, who made it.
  Widget _aboutPage(BuildContext context) {
    final colors = context.colors;
    void set(String key, String value) {
      setState(() {
        final text = value.trim();
        _manifest = {
          for (final MapEntry(key: k, value: v) in _manifest.entries)
            if (k != key || text.isNotEmpty) k: k == key ? text : v,
          if (!_manifest.containsKey(key) && text.isNotEmpty) key: text,
        };
      });
      _changed();
    }

    Widget field(String key, String label, {String? hint, String? helper, bool locked = false}) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: IgnorePointer(
            ignoring: widget.readOnly || locked,
            child: AppTextField(controller: _fields[key]!, label: label, hint: hint, helper: helper, onChanged: (v) => set(key, v)),
          ),
        );
    final idOk = ExtensionPackage.isThirdPartyId(_fields['id']!.text.trim()) || widget.readOnly || widget.unsaved;
    return ListView(padding: const EdgeInsets.fromLTRB(28, 22, 28, 28), children: [
      Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            field('name', 'Name'.tr),
            // Its id is what a project keeps its switch and its data under: set once.
            field('id', 'ID'.tr, locked: true, helper: idOk ? null : 'Like com.example.notes: lower-case, with a dot'.tr),
            field('version', 'Version'.tr, hint: '1.0.0'),
            field('summary', 'Summary'.tr),
            field('author', 'Author'.tr),
            field('url', 'Website'.tr, hint: 'https://'),
            field('keywords', 'Search Words'.tr),
            Text('${'API level'.tr}: ${_package.api} · ${'Data version'.tr}: ${_package.dataVersion}', style: TextStyle(fontSize: 12, color: colors.textMuted)),
          ]),
        ),
      ),
    ]);
  }

  /// Under what shows: what is wrong with it (as written, then as it ran), and what it printed.
  List<Widget> _under(BuildContext context) {
    final colors = context.colors;
    final id = _package.id;
    final ran = [...?widget.problems?.value.where((p) => p.extension == id)];
    final all = [..._problems.where((p) => !p.warning), ...ran, ..._problems.where((p) => p.warning)];
    final log = widget.log?.value ?? const <String>[];
    return [
      if (all.isNotEmpty) ...[
        Divider(height: 1, color: colors.line),
        CodeProblemList(problems: [
          for (final p in all)
            (
              text: [if (p.file != null) '${p.file}${p.line == null ? '' : ':${p.line}'}: ', p.message, if (p.where != null && p.file == null) ' (${p.where})'].join(),
              error: !p.warning,
              onTap: p.file == null ? null : () => _goTo(p.file, p.line),
            ),
        ]),
      ],
      if (log.isNotEmpty) ...[
        Divider(height: 1, color: colors.line),
        Container(
          height: 92,
          color: colors.chrome,
          child: ListView(
            reverse: true,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            children: [
              for (final line in log.reversed) Text(line, style: monospace.copyWith(fontSize: 12, height: 1.4, color: colors.text)),
            ],
          ),
        ),
      ],
    ];
  }
}

/// Nothing is offered as the README is typed.
class _NoPrompts implements CodeAutocompletePromptsBuilder {
  const _NoPrompts();
  @override
  CodeAutocompleteEditingValue? build(BuildContext context, CodeLine codeLine, CodeLineSelection selection) => null;
}

/// The guide to writing an extension ([extensionGuideAsset]).
class _Guide extends StatefulWidget {
  const _Guide();
  @override
  State<_Guide> createState() => _GuideState();
}

class _GuideState extends State<_Guide> {
  static String? _text;
  late final Future<String> _loading = _text != null ? Future.value(_text) : rootBundle.loadString(extensionGuideAsset).then((t) => _text = t);

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: context.colors.chrome,
        child: FutureBuilder(
          future: _loading,
          builder: (context, guide) => guide.data == null
              ? const SizedBox.shrink()
              : SingleChildScrollView(padding: const EdgeInsets.fromLTRB(16, 14, 16, 24), child: MarkdownText(guide.data!)),
        ),
      );
}

/// The extension API to look things up in: every socket with its ports and properties, every
/// library with its functions, searched as typed. A click on a function puts its call in the
/// code ([onInsert]); on a port, a function for it.
class ExtensionReference extends StatefulWidget {
  const ExtensionReference({super.key, this.onInsert});
  final ValueChanged<String>? onInsert;

  @override
  State<ExtensionReference> createState() => _ExtensionReferenceState();
}

class _ExtensionReferenceState extends State<ExtensionReference> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  /// A function's call as it would be typed: its signature up to what it gives.
  static String callOf(ApiFunction f) => f.signature.split(' → ').first;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final words = _query.text.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    bool matches(Iterable<String> texts) {
      final all = texts.join(' ').toLowerCase();
      return words.every(all.contains);
    }

    final mono = monospace.copyWith(fontSize: 12.5, color: colors.text, fontWeight: FontWeight.w600);
    final muted = TextStyle(fontSize: 12, height: 1.4, color: colors.textMuted);
    Widget heading(String text, String? summary) => Padding(
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(text, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: colors.text)),
            if (summary != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(summary, style: muted)),
          ]),
        );
    Widget entry(String signature, String summary, {String? example, VoidCallback? onTap, int since = 1}) => InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 7, 14, 7),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text.rich(TextSpan(children: [
                TextSpan(text: signature, style: mono),
                if (since > 1) TextSpan(text: '  API $since', style: muted.copyWith(fontSize: 11)),
              ])),
              const SizedBox(height: 2),
              Text(summary, style: muted),
              if (example != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 6),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: colors.surface, borderRadius: AppStyle.of(context).radius(6)),
                  child: Text(example, style: monospace.copyWith(fontSize: 12, height: 1.4, color: colors.text)),
                ),
            ]),
          ),
        );

    final insert = widget.onInsert;
    final rows = <Widget>[];
    for (final socket in ExtensionApi.sockets) {
      final ports = [for (final p in socket.ports) if (matches([socket.type, socket.title, p.name, p.signature, p.summary])) p];
      final props = [for (final p in socket.props) if (matches([socket.type, socket.title, p.name, p.summary])) p];
      if (ports.isEmpty && props.isEmpty) continue;
      rows.add(heading('${socket.title} · socket', socket.summary));
      for (final p in ports) {
        rows.add(entry(p.signature, p.summary,
            since: p.since, onTap: insert == null ? null : () => insert('-- ${socket.type}.${p.name}\nfunction M.${p.signature.split(' → ').first}\nend\n')));
      }
      for (final p in props) {
        rows.add(entry('${p.name}  (${p.type.name}${p.fallback == null ? '' : ', ${p.fallback}'})', p.summary, since: p.since));
      }
    }
    for (final library in ExtensionApi.libraries) {
      final functions = [for (final f in library.functions) if (matches([f.name, f.signature, f.summary])) f];
      final values = [for (final v in library.values) if (matches(['${library.name}.${v.$1}', v.$2])) v];
      if (functions.isEmpty && values.isEmpty) continue;
      rows.add(heading(library.name, library.summary));
      for (final f in functions) {
        rows.add(entry(f.signature, f.summary, example: f.example, since: f.since, onTap: insert == null ? null : () => insert(callOf(f))));
      }
      for (final (name, summary) in values) {
        rows.add(entry('${library.name}.$name', summary, onTap: insert == null ? null : () => insert('${library.name}.$name')));
      }
    }
    return ColoredBox(
      color: colors.chrome,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: AppTextField(controller: _query, label: 'Search'.tr, onChanged: (_) => setState(() {})),
        ),
        Expanded(
          child: rows.isEmpty
              ? Center(child: Text('No results'.tr, style: muted))
              : ListView(padding: const EdgeInsets.only(bottom: 20), children: rows),
        ),
      ]),
    );
  }
}
