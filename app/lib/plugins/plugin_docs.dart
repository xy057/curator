import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

import 'bundled.dart';

/// The guide the plugin editor's Help shows.
const pluginGuideAsset = 'assets/help/plugins.md';

/// What the pack's README says: what is in it, and how a plugin is written, for a model handed
/// the folder to write one from. In English, as the docs are.
const _packReadme = '''
# Curator plugin docs

Everything needed to write a plugin (a `.cgp` package) for Curator, for a person or an AI
assistant. A plugin changes the app itself, in every project: it adds commands to the menus,
the keys, the toolbar and Home, changes the app's own commands, and listens to what happens.
(What belongs to one project, saved with it, is an extension: a `.cpe`, with docs of its own.)

- `plugin-api.md`: the guide to writing a plugin, then the reference: every Lua function, every
  event, every command and setting of the app's. Read this first.
- `api.json`: the same reference as data.
- `examples/`: Curator's own plugins, each a folder laid out as a package is (`plugin.json`,
  `src/main.lua`, `README.md`). They are working code.

## For an AI assistant

- A plugin is a folder (zipped as `.cgp`) of `plugin.json` and Lua files under `src/`. Give
  every file in full.
- Curator runs `src/main.lua` once, as the app starts or the plugin is turned on. Everything a
  plugin does starts there: `app.command{...}` adds a command, `app.on(event, fn)` listens,
  `app.wrap`, `app.hide`, `app.rename` and `app.rebind` change the app's own commands.
- Use only the functions, events, commands and settings in `plugin-api.md` at or below the API
  level you write in `plugin.json` (`"api"`). Do not invent others; `curator.has("name")` says
  whether one is there.
- Lua builds no interface of its own: it describes (a command, a form's rows, a sheet), and
  Curator draws it as its own. Places in a score are in quarter notes from its start, lists
  start at 1.
- Keep what the plugin remembers in `curator.settings()` and `curator.save_settings(table)`.
- An id of your own has a dot: `com.example.hello`.
- Start from the example nearest what is asked: `reopenLast` (something done as the app
  starts), `appearanceMenu` (a menu of ticked commands that change a setting),
  `saveBeforeExport` (two of the app's commands wrapped), each a few lines; `navigator` for
  everything at once (a menu of its own with menus inside, keys, a toolbar button, lists in a
  menu, events, a timer, a form, a table to edit, files, settings kept for each project,
  several modules). In `navigator`, every comment that starts with `Edge:` marks something a
  plugin can't do, and what it does in its place: read them before promising a feature.
''';

/// The plugin docs as a zip to hand to a person or a model: a README saying what is in it, the
/// guide and reference as one Markdown file, the API as JSON, and each of [examples] (Curator's
/// own plugins) as a folder. The same bytes for the same docs.
Uint8List pluginDocsPack(String guide, {required List<PluginPackage> examples}) {
  final at = DateTime.utc(2000).millisecondsSinceEpoch ~/ 1000;
  final archive = Archive();
  void add(String path, List<int> bytes) => archive.add(ArchiveFile.bytes('curator-plugin-docs/$path', bytes)..lastModTime = at);
  add('README.md', utf8.encode(_packReadme.trimLeft()));
  add('plugin-api.md', utf8.encode(PluginApi.docs(guide)));
  add('api.json', utf8.encode(const JsonEncoder.withIndent('  ').convert(PluginApi.toJson())));
  for (final p in examples) {
    p.files.forEach((path, bytes) => add('examples/${p.id}/$path', bytes));
  }
  return ZipEncoder().encodeBytes(archive);
}

/// The plugin docs whole, as Markdown, and their pack, as the plugin editor hands them out.
Future<String> pluginDocs() async => PluginApi.docs(await rootBundle.loadString(pluginGuideAsset));
Future<Uint8List> pluginPack() async => pluginDocsPack(await rootBundle.loadString(pluginGuideAsset), examples: BundledPlugins.packages);
