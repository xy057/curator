/// The extension API as a list: every socket an extension can use and every function its Lua
/// can call. The one place it is written down: the runtime answers `curator.has` from it, the
/// extension editor's reference and what it offers as code is typed are made from it, and so
/// is docs/extension-api.md (app/tool/extension_docs.dart).
///
/// It only grows. A function, a socket, a port or a property is never taken away or made to
/// mean something else: an extension written for level 1 runs on every later Curator. What is
/// added says the level it came with ([since]); an extension says the level it needs
/// (`"api"` in extension.json) and may ask for more at run time with `curator.has`.
library;

/// A function Lua can call: `score.bars`.
class ApiFunction {
  const ApiFunction(this.name, this.signature, this.summary, {this.since = 1, this.example});

  /// As called: "score.bars".
  final String name;

  /// As written with its arguments and what it gives: "score.bars() → list".
  final String signature;
  final String summary;
  final int since;
  final String? example;
}

/// A table of functions: `score`.
class ApiLibrary {
  const ApiLibrary(this.name, this.summary, this.functions, {this.values = const []});
  final String name, summary;
  final List<ApiFunction> functions;

  /// Its fields that aren't functions: (`curator.api`, what it is).
  final List<(String, String)> values;
}

/// A port of a socket: something Curator calls the wired function for.
class ApiPort {
  const ApiPort(this.name, this.signature, this.summary, {this.since = 1});
  final String name;

  /// The function it takes, as it would be written: "items() → list".
  final String signature;
  final String summary;
  final int since;
}

enum ApiPropType { text, number, toggle, choice, icon, node }

/// A property of a socket, set in the connector: a lane's title.
class ApiProp {
  const ApiProp(this.name, this.type, this.summary, {this.choices = const [], this.fallback, this.since = 1});
  final String name;
  final ApiPropType type;
  final String summary;

  /// What a [ApiPropType.choice] may be; for a [ApiPropType.node], the socket type it names.
  final List<String> choices;
  final Object? fallback;
  final int since;
}

/// A socket: a place where an extension plugs into Curator ("lane", "command").
class ApiSocket {
  const ApiSocket(this.type, this.title, this.summary, {this.ports = const [], this.props = const [], this.single = false, this.since = 1});
  final String type, title, summary;
  final List<ApiPort> ports;
  final List<ApiProp> props;

  /// Whether an extension has at most one.
  final bool single;
  final int since;

  ApiPort? port(String name) => ports.where((p) => p.name == name).firstOrNull;
  ApiProp? prop(String name) => props.where((p) => p.name == name).firstOrNull;
}

abstract final class ExtensionApi {
  /// This build's API level.
  static const level = 1;

  static ApiSocket? socket(String type) => sockets.where((s) => s.type == type).firstOrNull;

  /// Whether this Curator has [name]: a function ("score.bars"), a library ("ui"), a socket
  /// ("socket:lane") or a port of one ("socket:lane.items").
  static bool has(String name) {
    if (name.startsWith('socket:')) {
      final rest = name.substring(7), dot = rest.indexOf('.');
      final s = socket(dot < 0 ? rest : rest.substring(0, dot));
      return s != null && (dot < 0 || s.port(rest.substring(dot + 1)) != null);
    }
    return libraries.any((l) => l.name == name || l.functions.any((f) => f.name == name) || l.values.any((v) => '${l.name}.${v.$1}' == name));
  }

  /// The icons a socket's `icon` may name.
  static const icons = [
    'add', 'delete', 'edit', 'score', 'image', 'captions', 'chapters', 'tonality', 'find', 'settings', 'export', 'import', 'play', 'pin', //
    'show', 'hide', 'code', 'fetch', 'test', 'done', 'extension',
  ];

  static const sockets = <ApiSocket>[
    ApiSocket('project', 'Project', 'The project the extension is on in. Every extension has one.', single: true, ports: [
      ApiPort('opened', 'opened()', 'A project with the extension on has opened, or it was just turned on.'),
      ApiPort('changed', 'changed()', 'The extension’s saved data changed: an edit of its own, Undo or Redo.'),
      ApiPort('used', 'used() → boolean',
          'Whether the project uses the extension, so opening it offers to turn it on. Unwired: whether it has saved anything.'),
      ApiPort('load', 'load(data, version) → data',
          'A project is being opened: check its saved data (written by the extension’s version of the data, "data.version" in extension.json) and return it as this version wants it. An error here says the project is damaged.'),
      ApiPort('replaced', 'replaced(carry) → lost',
          'The score was replaced. carry(quarter) gives where a place of the old score is in the new one, or nil when it is gone. Move the saved data and return how many things were lost.'),
    ]),
    ApiSocket('command', 'Command', 'Something the user can do: a button on a lane’s name, or an item of the preview’s menu.', ports: [
      ApiPort('run', 'run()', 'The user chose it.'),
      ApiPort('enabled', 'enabled() → boolean', 'Whether it can be chosen now. Unwired: always.'),
    ], props: [
      ApiProp('title', ApiPropType.text, 'Its name: a menu item’s text, a button’s hover text.'),
      ApiProp('icon', ApiPropType.icon, 'Its icon, on a button.'),
      ApiProp('where', ApiPropType.choice, 'Where it is offered.', choices: ['lane', 'preview'], fallback: 'lane'),
      ApiProp('lane', ApiPropType.node, 'The lane whose name carries the button (where: lane).', choices: ['lane']),
    ]),
    ApiSocket('lane', 'Lane', 'A lane pinned under the bar ruler, drawn and edited as the app’s own are.', ports: [
      ApiPort('items', 'items() → list',
          'What the lane shows, in score order. Markers: {at = quarter, label = text}, each running to the next. Spans: {from = quarter, to = quarter, label = text, color = "#RRGGBB"}.'),
      ApiPort('add', 'add(at, to)', 'The Draw tool was used: a click at a place (markers), or a stretch dragged out (spans).'),
      ApiPort('move', 'move(index, at, to)', 'Item index is being dragged to start at a place (and, a span, end at one). Called as it moves; the whole drag is one Undo step.'),
      ApiPort('erase', 'erase(index, from, to)', 'The Erase tool was used on item index (a span: over the stretch from–to).'),
      ApiPort('open', 'open(index)', 'Item index was double-clicked.'),
      ApiPort('remove', 'remove(index)', 'Delete was pressed with item index selected.'),
    ], props: [
      ApiProp('title', ApiPropType.text, 'The lane’s name.'),
      ApiProp('kind', ApiPropType.choice, 'Markers are places that each run to the next; spans are stretches with a start and an end.',
          choices: ['markers', 'spans'], fallback: 'markers'),
      ApiProp('gap', ApiPropType.number, 'The least two markers are apart, in quarters.', fallback: 0.25),
    ]),
  ];

  static const libraries = <ApiLibrary>[
    ApiLibrary('curator', 'The extension itself: its saved data, its texts.', [
      ApiFunction('curator.data', 'curator.data() → table',
          'The table the extension keeps in the project. It is the same table until the project changes under it (Undo, another project): change it, then call curator.save.',
          example: 'local data = curator.data()\ndata.notes = data.notes or {}\ntable.insert(data.notes, {at = 4, text = "Here"})\ncurator.save("Add Note")'),
      ApiFunction('curator.save', 'curator.save(label)', 'Keeps curator.data() as it is now: one Undo step, named label in the Edit menu. Saving what is already saved does nothing.'),
      ApiFunction('curator.settings', 'curator.settings() → table', 'What the extension keeps for every project (a copy).'),
      ApiFunction('curator.save_settings', 'curator.save_settings(table)', 'Keeps table as the extension’s settings for every project.'),
      ApiFunction('curator.tr', 'curator.tr(text, values) → text',
          'text in the interface’s language, from locales/<language>.json; each {name} in it is replaced by values.name.',
          example: 'curator.tr("{n} chapters", {n = 3})'),
      ApiFunction('curator.has', 'curator.has(name) → boolean',
          'Whether this Curator has a function ("score.notes"), a library ("ui"), a socket ("socket:lane") or a port ("socket:lane.items"): for using something newer than the level the extension asks for.'),
      ApiFunction('curator.log', 'curator.log(...)', 'Writes a line to the extension editor’s log. print does the same.'),
      ApiFunction('curator.list', 'curator.list(table) → table', 'Marks a table as a list, so that it is saved as [] while it is empty. A new table already is.'),
      ApiFunction('curator.map', 'curator.map(table) → table', 'Marks a table as a map, so that it is saved as {} while it is empty.'),
      ApiFunction('curator.asset', 'curator.asset(path) → text', 'A file of the extension’s assets folder as text; nil when there is none.'),
    ], values: [
      ('api', 'This Curator’s API level (a number).'),
      ('id', 'The extension’s id.'),
      ('name', 'The extension’s name.'),
      ('version', 'The extension’s version, as extension.json says it.'),
      ('language', 'The interface’s language ("en", "zh-Hans").'),
      ('null', 'JSON’s null where nil can’t stand: a value in a saved list.'),
    ]),
    ApiLibrary('score', 'The score and the performance it is synced to. Places are in quarter notes from the start of the score; times in seconds.', [
      ApiFunction('score.open', 'score.open() → boolean', 'Whether a score is open. The rest raise an error without one.'),
      ApiFunction('score.quarters', 'score.quarters() → number', 'The score’s length.'),
      ApiFunction('score.bars', 'score.bars() → list', 'Every bar: {number, start, length}.'),
      ApiFunction('score.bar_at', 'score.bar_at(quarter) → number, start', 'The bar a place is in (1 is the first) and where that bar starts.'),
      ApiFunction('score.beat_at', 'score.beat_at(quarter) → start, end', 'The beat a place is in.'),
      ApiFunction('score.format', 'score.format(quarter, compact) → text', 'A place as bar.beat ("12.3"); compact drops a first beat ("12").'),
      ApiFunction('score.parse', 'score.parse(text) → quarter', 'The place "12" or "12.3" names; nil when it names none.'),
      ApiFunction('score.seconds', 'score.seconds(quarter, pass) → seconds', 'When a place sounds, in the pass-th time through it (1 by default).'),
      ApiFunction('score.quarter', 'score.quarter(seconds) → quarter', 'The place sounding at a time.'),
      ApiFunction('score.pass_at', 'score.pass_at(seconds) → number', 'Which pass through the score sounds at a time: a repeat is a pass more.'),
      ApiFunction('score.passes', 'score.passes() → list', 'Every pass: {start, end} in quarters, {from, to} in seconds.'),
      ApiFunction('score.end_seconds', 'score.end_seconds() → seconds', 'When the music ends.'),
      ApiFunction('score.rehearsal_marks', 'score.rehearsal_marks() → list', 'The score’s rehearsal marks, in the order written: {at, bar, text}.'),
      ApiFunction('score.parts', 'score.parts() → list', 'The instruments: {id, name, staves}.'),
    ]),
  ];
}
