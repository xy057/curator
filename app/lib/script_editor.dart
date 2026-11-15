import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:re_editor/re_editor.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'code_view.dart';
import 'dialog_kit.dart';
import 'lilypond_dialog.dart' show monospace;
import 'lua_language.dart';
import 'markdown_text.dart';
import 'menu_kit.dart';
import 'ui_kit.dart';
import 'l10n/l10n.dart';

/// What a script editor shows at its right.
enum ScriptSide { none, reference, help }

/// What a script editor shows that isn't one of the package's Lua files.
const scriptAbout = '\u0000about', scriptReadme = '\u0000readme';

/// A script editor's page, as the extension and plugin editors are opened: the package, and
/// what is done with it.
abstract class ScriptEditor<P extends PackageManifest> extends StatefulWidget {
  const ScriptEditor({super.key, required this.package, this.readOnly = false, this.onRun, this.problems, this.log});

  /// The package as it was opened.
  final P package;
  final bool readOnly;

  /// Run (⌘R): the package as it stands handed to what runs it, the editor staying open.
  final void Function(P package)? onRun;

  /// What went wrong as it ran, and what it printed.
  final ValueListenable<List<ScriptProblem>>? problems;
  final ValueListenable<List<String>>? log;
}

/// What the extension and plugin editors share: a package's Lua files edited together
/// ([CodeView], coloured and prompted by `lua_language.dart`), what its manifest says of it
/// (About), and its README; beside them the API's reference (a click puts a function in the
/// code) and a guide; under them what is wrong with it as it is written ([check], as it is
/// typed) and, once run, what it printed and what went wrong. Each editor gives what is its own.
abstract class ScriptEditorState<W extends ScriptEditor<P>, P extends PackageManifest> extends State<W> {
  // MARK: What the editor is given ([ScriptEditor])

  P get original => widget.package;
  bool get readOnly => widget.readOnly;
  void Function(P package)? get onRun => widget.onRun;
  ValueListenable<List<ScriptProblem>>? get ranProblems => widget.problems;
  ValueListenable<List<String>>? get log => widget.log;

  // MARK: What each editor has of its own

  /// What is wrong with [package] as written.
  List<ScriptProblem> check(P package);

  /// The package as it stands, of [manifest], [sources] and [readme] (and what else the editor keeps).
  P packageOf({required Map<String, Object?> manifest, required Map<String, String> sources, required String? readme});

  /// The toolbar's title, and what Discard says stays as it was.
  String get title;
  String get discardText;

  /// What shows first, and once the file showing is deleted.
  String get firstShown;

  /// The manifest's file in the package ("plugin.json"), which a problem in it goes to About for.
  String get manifestFile;

  /// The guide Help shows, the bar over the side, and the Reference.
  String get guideAsset;
  Widget docsBar(String title);
  Widget reference(ValueChanged<String>? onInsert);

  /// The libraries offered as Lua is typed.
  List<ApiLibrary> get libraries;

  /// About's id field's note (what it should look like), and the line under About.
  String? get idHelper => null;
  String get aboutLine;

  /// The name in the toolbar.
  String get shownName => package.name;

  /// Files listed in order; whether one can be renamed and deleted.
  List<String> get sortedPaths => code.keys.toList()..sort();
  bool canChangeFile(String path) => true;

  /// What shows for a problem in [file] that isn't Lua; null: nothing.
  String? shownFor(String file) => file == manifestFile ? scriptAbout : null;

  /// A file renamed or deleted: what the editor keeps of it follows.
  void fileRenamed(String from, String to) {}
  void fileRemoved(String path) {}

  /// Tiles over About in the sidebar, and what shows for one of them; null: not one of them.
  List<Widget> leadingTiles(BuildContext context) => const [];
  Widget? ownBody(BuildContext context) => null;

  // MARK: State

  late Map<String, Object?> manifest = {...original.manifest};
  late final Map<String, CodeLineEditingController> code = {
    for (final MapEntry(key: path, value: source) in original.sources.entries) path: _file(source),
  };
  late final _readme = _watched(CodeLineEditingController.fromText(original.readme ?? ''));
  final _finds = <String, CodeFindController>{};
  final focus = FocusNode(debugLabel: 'script code');

  /// About's fields, by their key in the manifest.
  late final Map<String, TextEditingController> fields = {
    for (final key in const ['name', 'id', 'version', 'summary', 'author', 'url', 'keywords'])
      key: TextEditingController(text: switch (manifest[key]) { final String s => s, _ => '' }),
  };

  late String shown = firstShown;
  ScriptSide _side = ScriptSide.reference;

  /// What is wrong with it as written, found a moment after the last change.
  List<ScriptProblem> _problems = const [];
  Timer? _checking;

  CodeLineEditingController _watched(CodeLineEditingController c) => c..addListener(changed);
  CodeLineEditingController _file(String source) => _watched(luaCode(source));

  @override
  void initState() {
    super.initState();
    _problems = check(original);
    ranProblems?.addListener(_repaint);
    log?.addListener(_repaint);
  }

  @override
  void dispose() {
    _checking?.cancel();
    ranProblems?.removeListener(_repaint);
    log?.removeListener(_repaint);
    for (final c in [...code.values, _readme]) {
      c
        ..removeListener(changed)
        ..dispose();
    }
    for (final f in _finds.values) {
      f.dispose();
    }
    for (final f in fields.values) {
      f.dispose();
    }
    focus.dispose();
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
  void changed() {
    if (!mounted) return;
    _repaint();
    _checking?.cancel();
    _checking = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _problems = check(package));
    });
  }

  /// The package as it stands.
  P get package => packageOf(
        manifest: manifest,
        sources: {for (final MapEntry(key: path, value: c) in code.entries) path: c.text},
        readme: _readme.text.isEmpty && original.readme == null ? null : _readme.text,
      );

  bool get _edited => package != original;

  // MARK: Leaving

  Future<void> _cancel() async {
    if (readOnly || !_edited) return Navigator.of(context).pop();
    final discard = await confirmDiscard(context, content: discardText);
    if (discard && mounted) Navigator.of(context).pop();
  }

  void _done() => Navigator.of(context).pop(_edited ? package : null);

  void _run() {
    if (readOnly) return;
    setState(() => _problems = check(package));
    onRun?.call(package);
  }

  // MARK: Files

  /// The Lua file [file] names (a problem's says src/ first).
  String codePath(String file) => file.startsWith('src/') ? file.substring(4) : file;

  /// Shows [file] at [line], or what a file that isn't Lua is shown in.
  void goTo(String? file, int? line) {
    final path = file == null ? null : codePath(file);
    final c = code[path];
    if (c == null) {
      final other = file == null ? null : shownFor(file);
      if (other != null) setState(() => shown = other);
      return;
    }
    setState(() => shown = path!);
    if (line == null) return;
    final index = (line - 1).clamp(0, c.codeLines.length - 1);
    c.selection = CodeLineSelection.collapsed(index: index, offset: 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      c.makeCursorCenterIfInvisible();
      focus.requestFocus();
    });
  }

  Future<void> _addFile() async {
    final path = await askLuaFileName(context, taken: code.containsKey);
    if (path == null || !mounted) return;
    setState(() {
      code[path] = _file('local M = {}\n\nreturn M\n');
      shown = path;
    });
    changed();
  }

  Future<void> _renameFile(String path) async {
    final to = await askLuaFileName(context, from: path, taken: code.containsKey);
    if (to == null || !mounted) return;
    setState(() {
      code[to] = code.remove(path)!;
      _finds.remove(path)?.dispose();
      fileRenamed(path, to);
      if (shown == path) shown = to;
    });
    changed();
  }

  void _removeFile(String path) {
    setState(() {
      code.remove(path)
        ?..removeListener(changed)
        ..dispose();
      _finds.remove(path)?.dispose();
      fileRemoved(path);
      if (shown == path) shown = firstShown;
    });
    changed();
  }

  /// Puts [text] in the code where the caret is (a function clicked in the Reference).
  void _insert(String text) {
    final c = code[shown];
    if (c == null || readOnly) return;
    c.replaceSelection(text);
    focus.requestFocus();
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
                    ...scriptOutput(context,
                        written: _problems, ran: [...?ranProblems?.value.where((p) => p.extension == package.id)], log: log?.value ?? const [], goTo: goTo),
                  ]),
                ),
                if (_side != ScriptSide.none) ...[
                  VerticalDivider(width: 1, color: colors.line),
                  SizedBox(
                    width: 340,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      docsBar((_side == ScriptSide.reference ? 'Reference' : 'Help').tr),
                      Expanded(
                        child: _side == ScriptSide.reference
                            ? reference(code.containsKey(shown) && !readOnly ? _insert : null)
                            : ScriptGuide(guideAsset),
                      ),
                    ]),
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
    final c = code[shown] ?? (shown == scriptReadme ? _readme : null);
    return Container(
      height: style.toolbar + 8,
      color: colors.chrome,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: colors.text)),
        const SizedBox(width: 10),
        Expanded(child: Text(shownName, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: colors.textMuted))),
        if (c != null) ...[
          if (!readOnly) ...undoRedoButtons(context, undo: c.canUndo ? c.undo : null, redo: c.canRedo ? c.redo : null),
          ToolbarButton(
              icon: AppIcon.search.of(context),
              tooltip: 'Find ({key})'.fill({'key': shortcut('⌘F')}),
              onPressed: () => _finds[shown]
                ?..findMode()
                ..focusOnFindInput()),
          const ToolbarDivider(),
        ],
        ToolbarButton(
          icon: AppIcon.code.of(context),
          tooltip: 'Reference'.tr,
          selected: _side == ScriptSide.reference,
          onPressed: () => setState(() => _side = _side == ScriptSide.reference ? ScriptSide.none : ScriptSide.reference),
        ),
        ToolbarButton(
          icon: AppIcon.website.of(context),
          tooltip: 'Help'.tr,
          selected: _side == ScriptSide.help,
          onPressed: () => setState(() => _side = _side == ScriptSide.help ? ScriptSide.none : ScriptSide.help),
        ),
        const ToolbarDivider(),
        if (readOnly)
          FilledButton(onPressed: () => Navigator.of(context).pop(), child: Text('Close'.tr))
        else ...[
          if (onRun != null) ...[
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

  /// What the package is made of, to choose what shows: what the editor adds, what it says of
  /// itself, its files, its README.
  Widget _files(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: 210,
      color: colors.chrome,
      child: ListView(padding: const EdgeInsets.all(8), children: [
        ...leadingTiles(context),
        SidebarTile(icon: AppIcon.about.of(context), label: 'About'.tr, selected: shown == scriptAbout, onTap: () => setState(() => shown = scriptAbout)),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 14, 4, 4),
          child: Row(children: [
            Expanded(child: Text('Files'.trIn('heading'), style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: colors.textMuted))),
            if (!readOnly)
              Tip(
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
          ]),
        ),
        for (final path in sortedPaths)
          SidebarTile(
            key: ValueKey(path),
            icon: AppIcon.code.of(context),
            label: path,
            selected: shown == path,
            onTap: () => setState(() => shown = path),
            trailing: readOnly || !canChangeFile(path)
                ? null
                : AppPopupMenuButton<VoidCallback>(
                    tooltip: 'File'.tr,
                    padding: EdgeInsets.zero,
                    iconSize: 14,
                    constraints: const BoxConstraints(minWidth: 140),
                    icon: Icon(AppIcon.more.of(context), color: code[path]!.text != original.sources[path] ? colors.accent : colors.textMuted),
                    onSelected: (action) => action(),
                    itemBuilder: (context) => [
                      menuItem(context, value: () => _renameFile(path), child: Text('Rename…'.tr)),
                      menuItem(context, value: () => _removeFile(path), child: Text('Delete'.tr)),
                    ],
                  ),
          ),
        const SizedBox(height: 6),
        SidebarTile(icon: AppIcon.copy.of(context), label: 'README', selected: shown == scriptReadme, onTap: () => setState(() => shown = scriptReadme)),
      ]),
    );
  }

  Widget _body(BuildContext context) {
    if (ownBody(context) case final own?) return own;
    if (shown == scriptAbout) return _aboutPage(context);
    final code = this.code[shown] ?? _readme;
    return KeyedSubtree(
      key: ValueKey(shown),
      child: CodeView(
        controller: code,
        findController: _finds[shown] ??= CodeFindController(code),
        focusNode: focus,
        readOnly: readOnly,
        prompts: shown == scriptReadme ? const NoPrompts() : LuaPrompts(() => code.text, libraries: libraries),
        kindOf: luaPromptKind,
      ),
    );
  }

  /// What the manifest says: its name, id, version, summary, who made it.
  Widget _aboutPage(BuildContext context) {
    final colors = context.colors;
    void set(String key, String value) {
      setState(() {
        final text = value.trim();
        manifest = {
          for (final MapEntry(key: k, value: v) in manifest.entries)
            if (k != key || text.isNotEmpty) k: k == key ? text : v,
          if (!manifest.containsKey(key) && text.isNotEmpty) key: text,
        };
      });
      changed();
    }

    Widget field(String key, String label, {String? hint, String? helper, bool locked = false}) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: IgnorePointer(
            ignoring: readOnly || locked,
            child: AppTextField(controller: fields[key]!, label: label, hint: hint, helper: helper, onChanged: (v) => set(key, v)),
          ),
        );
    return ListView(padding: const EdgeInsets.fromLTRB(28, 22, 28, 28), children: [
      Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            field('name', 'Name'.tr),
            // Its id is what its switch and what it keeps are kept under: set once.
            field('id', 'ID'.tr, locked: true, helper: idHelper),
            field('version', 'Version'.tr, hint: '1.0.0'),
            field('summary', 'Summary'.tr),
            field('author', 'Author'.tr),
            field('url', 'Website'.tr, hint: 'https://'),
            field('keywords', 'Search Words'.tr),
            Text(aboutLine, style: TextStyle(fontSize: 12, color: colors.textMuted)),
          ]),
        ),
      ),
    ]);
  }
}

final _luaFileName = RegExp(r'^[A-Za-z0-9_]+(/[A-Za-z0-9_]+)*\.lua$');

/// Asks for a Lua file's name in a package ([from]: the one it has, renamed), one no file of it
/// has ([taken]); null: cancelled.
Future<String?> askLuaFileName(BuildContext context, {String? from, required bool Function(String path) taken}) {
  final name = TextEditingController(text: from ?? '');
  return showAppDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(builder: (context, setState) {
      final text = name.text.trim();
      final problem = text.isEmpty || text == from
          ? ''
          : !_luaFileName.hasMatch(text)
              ? 'Use letters, digits and _, ending in .lua'.tr
              : taken(text)
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

/// What a word offered as Lua is typed is, shown beside it: an API function's signature, else
/// its kind.
String? luaPromptKind(CodePrompt prompt) => prompt is! LuaPrompt
    ? null
    : prompt.function?.signature ??
        switch (prompt.kind) {
          LuaKind.keyword => 'keyword'.trIn('lua'),
          LuaKind.function => 'function'.trIn('lua'),
          LuaKind.library => 'library'.trIn('lua'),
          LuaKind.value => 'value'.trIn('lua'),
          LuaKind.local => null,
        };

/// Under an editor's code: what is wrong with the package as [written] and as it [ran] (a
/// click goes to the place, [goTo]), then the lines it printed ([log]).
List<Widget> scriptOutput(BuildContext context,
    {required List<ScriptProblem> written, required List<ScriptProblem> ran, required List<String> log, required void Function(String? file, int? line) goTo}) {
  final colors = context.colors;
  final all = [...written.where((p) => !p.warning), ...ran, ...written.where((p) => p.warning)];
  return [
    if (all.isNotEmpty) ...[
      Divider(height: 1, color: colors.line),
      CodeProblemList(problems: [
        for (final p in all)
          (
            text: [if (p.file != null) '${p.file}${p.line == null ? '' : ':${p.line}'}: ', p.message, if (p.where != null && p.file == null) ' (${p.where})'].join(),
            error: !p.warning,
            onTap: p.file == null ? null : () => goTo(p.file, p.line),
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

/// Nothing is offered as the README is typed.
class NoPrompts implements CodeAutocompletePromptsBuilder {
  const NoPrompts();
  @override
  CodeAutocompleteEditingValue? build(BuildContext context, CodeLine codeLine, CodeLineSelection selection) => null;
}

/// A guide an editor's Help shows: the one at [asset] (to writing an extension,
/// `extensionGuideAsset`, or a plugin).
class ScriptGuide extends StatefulWidget {
  const ScriptGuide(this.asset, {super.key});
  final String asset;
  @override
  State<ScriptGuide> createState() => _ScriptGuideState();
}

class _ScriptGuideState extends State<ScriptGuide> {
  static final _texts = <String, String>{};
  late final Future<String> _loading =
      _texts[widget.asset] != null ? Future.value(_texts[widget.asset]) : rootBundle.loadString(widget.asset).then((t) => _texts[widget.asset] = t);

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

/// One more part of a reference, under a heading: what isn't a library's (a plugin's events,
/// the app's commands), each row as it is shown, what it says, and what a click puts in the code.
typedef ReferenceSection = ({String title, String? summary, List<({String signature, String summary, String insert})> rows});

/// An API to look things up in: every socket with its ports and properties, every library
/// with its functions, then [sections], searched as typed. A click on a function puts its call
/// in the code ([onInsert]); on a port, a function for it. The extensions' ([ExtensionApi])
/// unless another's [sockets] and [libraries] are given (the plugins').
class ExtensionReference extends StatefulWidget {
  const ExtensionReference({super.key, this.onInsert, this.sockets = ExtensionApi.sockets, this.libraries = ExtensionApi.libraries, this.sections = const []});
  final ValueChanged<String>? onInsert;
  final List<ApiSocket> sockets;
  final List<ApiLibrary> libraries;
  final List<ReferenceSection> sections;

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
    for (final socket in widget.sockets) {
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
    for (final library in widget.libraries) {
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
    for (final section in widget.sections) {
      final found = [for (final r in section.rows) if (matches([section.title, r.signature, r.summary])) r];
      if (found.isEmpty) continue;
      rows.add(heading(section.title, section.summary));
      for (final r in found) {
        rows.add(entry(r.signature, r.summary, onTap: insert == null ? null : () => insert(r.insert)));
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
