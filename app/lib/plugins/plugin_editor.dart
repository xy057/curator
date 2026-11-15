import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart';

import '../extensions/extension_docs.dart';
import '../script_editor.dart';
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

/// A plugin's files edited together ([ScriptEditorState]), main.lua first: the file that runs,
/// which keeps its name and stays.
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

class _PluginEditorState extends ScriptEditorState<PluginEditor, PluginPackage> {
  @override
  PluginPackage get original => widget.package;
  @override
  bool get readOnly => widget.readOnly;
  @override
  void Function(PluginPackage package)? get onRun => widget.onRun;
  @override
  ValueListenable<List<ScriptProblem>>? get ranProblems => widget.problems;
  @override
  ValueListenable<List<String>>? get log => widget.log;

  @override
  List<ScriptProblem> check(PluginPackage package) => checkPlugin(package);

  @override
  PluginPackage packageOf({required Map<String, Object?> manifest, required Map<String, String> sources, required String? readme}) =>
      PluginPackage(manifest: manifest, sources: sources, locales: widget.package.locales, assets: widget.package.assets, readme: readme);

  @override
  String get title => widget.readOnly ? 'Plugin'.tr : 'Edit Plugin'.tr;
  @override
  String get discardText => 'The plugin stays as it was.'.tr;
  @override
  String get firstShown => code.containsKey(PluginPackage.entry) ? PluginPackage.entry : scriptAbout;
  @override
  String get manifestFile => 'plugin.json';

  @override
  List<String> get sortedPaths => code.keys.toList()..sort((a, b) => a == PluginPackage.entry ? -1 : b == PluginPackage.entry ? 1 : a.compareTo(b));
  @override
  bool canChangeFile(String path) => path != PluginPackage.entry;

  @override
  String get guideAsset => pluginGuideAsset;
  @override
  Widget docsBar(String title) => ExtensionDocsBar(title: title, docs: pluginDocs, pack: pluginPack, packName: 'Curator Plugin Docs.zip');
  @override
  Widget reference(ValueChanged<String>? onInsert) =>
      ExtensionReference(onInsert: onInsert, sockets: const [], libraries: PluginApi.libraries, sections: pluginReferenceSections);
  @override
  List<ApiLibrary> get libraries => PluginApi.libraries;

  @override
  String get aboutLine => '${'API level'.tr}: ${package.api}';
}
