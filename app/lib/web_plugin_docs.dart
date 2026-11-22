import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

import 'web_plugins.dart';

/// The guide to writing a web plugin, and the API as TypeScript reads it.
const webPluginGuideAsset = 'assets/help/web-plugins.md', webPluginTypesAsset = 'assets/web_plugins/${WebPluginApi.typesName}';

/// What the pack's README says: what is in it, and how a web plugin is written, for a person or
/// a model handed the folder to write one from. In English, as the docs are.
const _packReadme = '''
# Curator web plugin docs

Everything needed to write a web plugin (a `.cwp` package) for Curator, for a person or an AI
assistant. A web plugin changes the pages File ▸ Export to Web… writes: it adds buttons, options,
keys and elements of its own to the web player, and follows and moves what plays. (What changes
the app itself is a plugin, a `.cgp`, written in Lua, with docs of its own.)

- `web-plugin-api.md`: the guide to writing a web plugin, then the API. Read this first.
- `curator-web.d.ts`: the API as TypeScript: every member, with what it does. Copy it beside
  your code and import its types.
- `examples/`: Curator's own web plugins, each a folder laid out as a package is (`plugin.json`,
  `src/main.ts`, the `main.js` built from it, `README.md`). They are working code.
  (`examples/curator-web.d.ts` is the same file again, where their imports look for it.)

## For an AI assistant

- A web plugin is a folder (zipped as `.cwp`) of `plugin.json`, `main.js` and, to be read,
  `src/main.ts`. Write TypeScript, and say how it is built into `main.js`, one ES module
  (`bun build src/main.ts --outfile main.js --format esm`, or esbuild, or tsc). Give every file
  in full.
- `main.js` exports one function as its default. The player calls it once, as the page starts,
  with the page's `Curator`. Everything a plugin does starts there: `curator.ui.button({...})`
  adds a button, `curator.on(event, fn)` listens, `curator.playback` moves what plays.
- Use only what `curator-web.d.ts` declares, at or below the API level you write in plugin.json
  (`"api"`). Do not invent members; `curator.has("ui.dock")` says whether one is there.
- Times are seconds from the start of what is heard; places in a score are quarter notes from
  its start; lists start at 0.
- The player draws its own interface in a canvas: a button, an option and a key are described
  to it, and it draws them. Elements of the plugin's own go in `curator.ui.overlay()` (over the
  score) or `curator.ui.dock(edge, size)` (beside the player), never into the page elsewhere.
- Write every text shown to the viewer in English, and translate in `locales/<language>.json`.
- An id of your own has a dot: `com.example.hello`.
- Start from the example nearest what is asked: `mediaKeys` (the browser's own APIs fed from
  events), `linkToTime` (a button, a setting, places and times), `embedControl` (the page played
  from the site around it), `barCounter` (an element over the score, an option, storage),
  `transcript` (a panel beside the player, a ticked button, a key).
''';

/// The web plugin docs as a zip to hand to a person or a model: a README saying what is in it,
/// the guide and reference as one Markdown file, the API's types, and each of [examples]
/// (Curator's own web plugins) as a folder. The same bytes for the same docs.
Uint8List webPluginDocsPack(String guide, String types, {required List<WebPluginPackage> examples}) {
  const folder = 'curator-web-plugin-docs';
  final at = DateTime.utc(2000).millisecondsSinceEpoch ~/ 1000;
  final archive = Archive();
  void add(String path, List<int> bytes) => archive.add(ArchiveFile.bytes('$folder/$path', bytes)..lastModTime = at);
  add('README.md', utf8.encode(_packReadme.trimLeft()));
  add('web-plugin-api.md', utf8.encode(WebPluginApi.docs(guide, types)));
  add(WebPluginApi.typesName, utf8.encode(types));
  add('examples/${WebPluginApi.typesName}', utf8.encode(types));
  for (final p in examples) {
    p.files.forEach((path, bytes) => add('examples/${p.id}/$path', bytes));
  }
  return ZipEncoder().encodeBytes(archive);
}

/// The pack, as Export to Web's Plugins hands it out.
Future<Uint8List> webPluginPack() async =>
    webPluginDocsPack(await rootBundle.loadString(webPluginGuideAsset), await rootBundle.loadString(webPluginTypesAsset), examples: BundledWebPlugins.packages);
