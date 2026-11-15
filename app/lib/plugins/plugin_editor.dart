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
import '../extensions/extension_docs.dart';
import '../extensions/extension_editor.dart';
import '../lua_language.dart';
import '../menu_kit.dart';
import '../ui_kit.dart';
import '../l10n/l10n.dart';
import 'plugin_docs.dart';

/// Opens the plugin editor on [package], over the whole window. Returns the plugin as edited
/// (Done); null when it was left as it is. With [onRun], Run (⌘R) hands the plugin as it stands
/// to the app without closing: it starts again, and what it then prints and what goes wrong in
/// it ([log], [problems]) show under the code. [readOnly]: one of Curator's own, to read.
Future<PluginPackage?> showPluginEditor(
  BuildContext context,
  PluginPackage package, {
  bool readOnly = false,
  void Function(PluginPackage package)? onRun,
  ValueListenable<List<ScriptProblem>>? problems,
  ValueListenable<List<String>>? log,
}) =>
    Navigator.of(context, rootNavigator: true).push<PluginPackage>(PageRouteBuilder(
      fullscreenDialog: true,
      transitionDuration: motion(context, 200),
      reverseTransitionDuration: motion(context, 160),
      pageBuilder: (_, _, _) => PluginEditor(package: package, readOnly: readOnly, onRun: onRun, problems: problems, log: log),
      transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic), child: child),
    ));

/// What the editor shows at its right.
enum _Side { none, reference, help }

/// What the plugins' Reference lists after the libraries: the events, the app's commands and
/// its settings, each put in the code as it would be written.
final List<ReferenceSection> pluginReferenceSections = [
  (
    title: 'Events',
    summary: 'What app.on listens to.',
    rows: [
      for (final e in PluginApi.events) (signature: '"${e.name}"  ${e.signature}', summary: e.summary, insert: 'app.on("${e.name}", ${e.signature}\nend)\n'),
    ],
  ),
  (
    title: 'Commands',
    summary: 'The app’s own, as app.run, app.hide, app.rename, app.rebind and app.wrap take them.',
    rows: [
      for (final c in PluginApi.commands) (signature: '"${c.id}"', summary: c.menu == null ? c.title : '${c.menu} ▸ ${c.title}', insert: '"${c.id}"'),
    ],
  ),
  (
    title: 'Settings',
    summary: 'What app.setting reads and sets.',
    rows: [
      for (final s in PluginApi.settings) (signature: '"${s.name}"  ${s.values}', summary: s.summary, insert: 'app.setting("${s.name}")'),
    ],
  ),
];

/// A plugin's files edited together: its Lua ([CodeView], coloured and prompted by
/// `lua_language.dart`, main.lua first: the file that runs), what plugin.json says of it
/// (About), and its README; beside them the API's reference ([PluginApi], a click puts a
/// function in the code) and a guide; under them what is wrong with it as it is written
/// ([checkPlugin], as it is typed) and, once run, what it printed and what went wrong.
class PluginEditor extends StatefulWidget {
  const PluginEditor({super.key, required this.package, this.readOnly = false, this.onRun, this.problems, this.log});
  final PluginPackage package;
  final bool readOnly;
  final void Function(PluginPackage package)? onRun;
  final ValueListenable<List<ScriptProblem>>? problems;
  final ValueListenable<List<String>>? log;

  @override
  State<PluginEditor> createState() => _PluginEditorState();
}

const _about = '\u0000about', _readmeView = '\u0000readme';

class _PluginEditorState extends State<PluginEditor> {
  late Map<String, Object?> _manifest = {...widget.package.manifest};
  late final Map<String, CodeLineEditingController> _code = {
    for (final MapEntry(key: path, value: source) in widget.package.sources.entries) path: _file(source),
  };
  late final _readme = _watched(CodeLineEditingController.fromText(widget.package.readme ?? ''));
  final _finds = <String, CodeFindController>{};
  final _focus = FocusNode(debugLabel: 'plugin code');

  /// About's fields, by their key in plugin.json.
  late final Map<String, TextEditingController> _fields = {
    for (final key in const ['name', 'id', 'version', 'summary', 'author', 'url', 'keywords'])
      key: TextEditingController(text: switch (_manifest[key]) { final String s => s, _ => '' }),
  };

  late String _shown = _code.containsKey(PluginPackage.entry) ? PluginPackage.entry : _about;
  _Side _side = _Side.reference;

  /// What is wrong with it as written, found a moment after the last change.
  List<ScriptProblem> _problems = const [];
  Timer? _checking;

  CodeLineEditingController _watched(CodeLineEditingController c) => c..addListener(_changed);
  CodeLineEditingController _file(String source) => _watched(luaCode(source));

  @override
  void initState() {
    super.initState();
    _problems = checkPlugin(widget.package);
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
      if (mounted) setState(() => _problems = checkPlugin(_package));
    });
  }

  /// The plugin as it stands.
  PluginPackage get _package => PluginPackage(
        manifest: _manifest,
        sources: {for (final MapEntry(key: path, value: c) in _code.entries) path: c.text},
        locales: widget.package.locales,
        assets: widget.package.assets,
        readme: _readme.text.isEmpty && widget.package.readme == null ? null : _readme.text,
      );

  bool get _edited => _package != widget.package;

  // MARK: Leaving

  Future<void> _cancel() async {
    if (widget.readOnly || !_edited) return Navigator.of(context).pop();
    final discard = await confirmDiscard(context, content: 'The plugin stays as it was.'.tr);
    if (discard && mounted) Navigator.of(context).pop();
  }

  void _done() => Navigator.of(context).pop(_edited ? _package : null);

  void _run() {
    if (widget.readOnly) return;
    setState(() => _problems = checkPlugin(_package));
    widget.onRun?.call(_package);
  }

  // MARK: Files

  void _goTo(String? file, int? line) {
    final path = file == null ? null : (file.startsWith('src/') ? file.substring(4) : file);
    final c = _code[path];
    if (c == null) {
      if (file == 'plugin.json') setState(() => _shown = _about);
      return;
    }
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

  Future<void> _addFile() async {
    final path = await askLuaFileName(context, taken: _code.containsKey);
    if (path == null || !mounted) return;
    setState(() {
      _code[path] = _file('local M = {}\n\nreturn M\n');
      _shown = path;
    });
    _changed();
  }

  Future<void> _renameFile(String path) async {
    final to = await askLuaFileName(context, from: path, taken: _code.containsKey);
    if (to == null || !mounted) return;
    setState(() {
      _code[to] = _code.remove(path)!;
      _finds.remove(path)?.dispose();
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
      if (_shown == path) _shown = PluginPackage.entry;
    });
    _changed();
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
                    ...scriptOutput(context,
                        written: _problems,
                        ran: [...?widget.problems?.value.where((p) => p.extension == _package.id)],
                        log: widget.log?.value ?? const [],
                        goTo: _goTo),
                  ]),
                ),
                if (_side != _Side.none) ...[
                  VerticalDivider(width: 1, color: colors.line),
                  SizedBox(
                    width: 340,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      ExtensionDocsBar(
                          title: (_side == _Side.reference ? 'Reference' : 'Help').tr, docs: pluginDocs, pack: pluginPack, packName: 'Curator Plugin Docs.zip'),
                      Expanded(
                        child: _side == _Side.reference
                            ? ExtensionReference(
                                onInsert: _code.containsKey(_shown) && !widget.readOnly ? _insert : null,
                                sockets: const [],
                                libraries: PluginApi.libraries,
                                sections: pluginReferenceSections,
                              )
                            : const ScriptGuide(pluginGuideAsset),
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
    final c = _code[_shown] ?? (_shown == _readmeView ? _readme : null);
    return Container(
      height: style.toolbar + 8,
      color: colors.chrome,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        Text(widget.readOnly ? 'Plugin'.tr : 'Edit Plugin'.tr, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: colors.text)),
        const SizedBox(width: 10),
        Expanded(child: Text(_package.name, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: colors.textMuted))),
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

  /// What the plugin is made of, to choose what shows: what it says of itself, its files (the
  /// one that runs first, and kept), its README.
  Widget _files(BuildContext context) {
    final colors = context.colors;
    final paths = _code.keys.toList()..sort((a, b) => a == PluginPackage.entry ? -1 : b == PluginPackage.entry ? 1 : a.compareTo(b));
    return Container(
      width: 210,
      color: colors.chrome,
      child: ListView(padding: const EdgeInsets.all(8), children: [
        SidebarTile(icon: AppIcon.about.of(context), label: 'About'.tr, selected: _shown == _about, onTap: () => setState(() => _shown = _about)),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 14, 4, 4),
          child: Row(children: [
            Expanded(child: Text('Files'.trIn('heading'), style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: colors.textMuted))),
            if (!widget.readOnly)
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
        for (final path in paths)
          SidebarTile(
            key: ValueKey(path),
            icon: AppIcon.code.of(context),
            label: path,
            selected: _shown == path,
            onTap: () => setState(() => _shown = path),
            // main.lua is the plugin: it keeps its name, and stays.
            trailing: widget.readOnly || path == PluginPackage.entry
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
    if (_shown == _about) return _aboutPage(context);
    final code = _code[_shown] ?? _readme;
    return KeyedSubtree(
      key: ValueKey(_shown),
      child: CodeView(
        controller: code,
        findController: _finds[_shown] ??= CodeFindController(code),
        focusNode: _focus,
        readOnly: widget.readOnly,
        prompts: _shown == _readmeView ? const NoPrompts() : LuaPrompts(() => code.text, libraries: PluginApi.libraries),
        kindOf: luaPromptKind,
      ),
    );
  }

  /// What plugin.json says: its name, id, version, summary, who made it.
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

    Widget field(String key, String label, {String? hint, bool locked = false}) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: IgnorePointer(
            ignoring: widget.readOnly || locked,
            child: AppTextField(controller: _fields[key]!, label: label, hint: hint, onChanged: (v) => set(key, v)),
          ),
        );
    return ListView(padding: const EdgeInsets.fromLTRB(28, 22, 28, 28), children: [
      Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            field('name', 'Name'.tr),
            // Its id is what the app keeps its switch and its settings under: set once.
            field('id', 'ID'.tr, locked: true),
            field('version', 'Version'.tr, hint: '1.0.0'),
            field('summary', 'Summary'.tr),
            field('author', 'Author'.tr),
            field('url', 'Website'.tr, hint: 'https://'),
            field('keywords', 'Search Words'.tr),
            Text('${'API level'.tr}: ${_package.api}', style: TextStyle(fontSize: 12, color: colors.textMuted)),
          ]),
        ),
      ),
    ]);
  }
}
