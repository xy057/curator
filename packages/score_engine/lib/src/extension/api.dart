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
  const ApiFunction(this.name, this.signature, this.summary, {this.since = 1, this.example, this.editor = false});

  /// As called: "score.bars".
  final String name;

  /// As written with its arguments and what it gives: "score.bars() → list".
  final String signature;
  final String summary;
  final int since;
  final String? example;

  /// Whether only the editor gives it, though its library is everywhere (`score.music`).
  final bool editor;
}

/// A table of functions: `score`.
class ApiLibrary {
  const ApiLibrary(this.name, this.summary, this.functions, {this.values = const [], this.addsTo = false});
  final String name, summary;
  final List<ApiFunction> functions;

  /// Whether it is one of Lua's own libraries, [functions] being what Curator adds to it.
  final bool addsTo;

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

  /// The icons a socket's `icon` may name (the app's own, by name).
  static const icons = [
    'add', 'close', 'delete', 'reset', 'copy', 'check', 'search', 'more', 'open', 'project', 'score', 'export', 'assets', 'play', 'pause', //
    'music', 'draw', 'erase', 'tidy', 'audio', 'repeat', 'snap', 'frame', 'lanes', 'image', 'pin', 'link', 'captions', 'settings', 'fonts', //
    'extensions', 'done', 'failed', 'warning', 'previous', 'next', 'align', 'moveUp', 'moveDown', 'chapters', 'ai', 'show', 'hide', 'test', //
    'fetch', 'code', 'tonality', 'website', 'keyboard',
  ];

  static const sockets = <ApiSocket>[
    ApiSocket('project', 'Project', 'The project the extension is on in. Every extension has one.', single: true, ports: [
      ApiPort('opened', 'opened()', 'A project with the extension on has opened, or it was just turned on.'),
      ApiPort('changed', 'changed()', 'The extension’s saved data changed: an edit of its own, Undo or Redo.'),
      ApiPort('used', 'used() → boolean',
          'Whether the project uses the extension, so opening it offers to turn it on. Unwired: whether it has saved anything.'),
      ApiPort('load', 'load(data, version) → data',
          'A project is being opened: check its saved data (written by the extension’s version of the data, "data.version" in extension.json) and return it as this version wants it. An error here says the project is damaged.'),
      ApiPort('replaced', 'replaced(data, carry) → data, lost',
          'The score is being replaced by another. carry(quarter) gives where a place of the old score is in the new one, or nil when it is gone; a third argument is the new score’s length in quarters. Return the saved data moved there, and what was lost as a text ("2 chapters"), or nil.'),
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
    ApiSocket('export', 'Export', 'What the extension gives a video and a web page made of the project.', single: true, ports: [
      ApiPort('chapters', 'chapters(from, to) → list',
          'The chapters of a video or page showing from–to seconds of the performance: {from, to, name}, in seconds from its start, in order and without gaps. A movie carries them for its player, with a list of their times beside it; a page lists them to jump to.'),
    ]),
    ApiSocket('lane', 'Lane', 'A lane pinned under the bar ruler, drawn and edited as the app’s own are. Its kind says what it holds: markers (places, each running to the next) or spans (stretches that never overlap).', ports: [
      ApiPort('items', 'items() → list',
          'What the lane shows, in score order. Markers: {at = quarter, label = text}. Spans: {from = quarter, to = quarter, label = text, color = colour}; without a colour a stretch is drawn as a region is. Asked again when the extension’s data changes.'),
      ApiPort('open', 'open(index)', 'Item index was double-clicked.'),
      ApiPort('remove', 'remove(index)', 'Delete was pressed with item index selected.'),
      ApiPort('nudge', 'nudge(index, direction, fine)', '← (direction -1) or → (1) was pressed with item index selected; fine asks for the smaller step (a beat, not a bar). Unwired: the keys do what they do without it.'),
      ApiPort('trim', 'trim(index, edge)', '[ (edge "start") or ] ("end") was pressed with item index selected: the edge goes to the playhead.'),
      ApiPort('add', 'add(at)', 'Markers: the Draw tool was clicked at a place (snapped to the beat it is in).'),
      ApiPort('move', 'move(index, at)', 'Markers: item index is being dragged to start at a place. Called as it moves; the whole drag is one Undo step.'),
      ApiPort('erase', 'erase(index)', 'Markers: the Erase tool was clicked on item index.'),
      ApiPort('draw', 'draw(from, to)', 'Spans: the Draw tool was dragged across from–to (a click: the beat there).'),
      ApiPort('begin', 'begin()', 'Spans: a drag that may change the stretches begins. Until the next, change and cut are of the stretches as they are now: keep them.'),
      ApiPort('change', 'change(index, from, to)',
          'Spans: stretch index (as begin found them) was moved or trimmed to from–to. Called as the drag goes, the whole drag one Undo step; with live off, once as it ends.'),
      ApiPort('cut', 'cut(pieces)',
          'Spans: the Erase tool went over stretches. pieces is every stretch as it is left, {of, from, to}: a piece of stretch of (as begin found them). One erased whole has none.'),
    ], props: [
      ApiProp('title', ApiPropType.text, 'The lane’s name.'),
      ApiProp('kind', ApiPropType.choice, 'What it holds: markers are places that each run to the next, spans are stretches with a start and an end.', choices: ['markers', 'spans'], fallback: 'markers'),
      ApiProp('gap', ApiPropType.number, 'Markers: the least two are apart, in quarters: a drag stops there.', fallback: 0.25),
      ApiProp('paint', ApiPropType.toggle, 'Spans: a stretch drawn, moved or trimmed goes over the others, as an instrument’s region does (cut them back in change and draw), instead of stopping at them.', fallback: false),
      ApiProp('live', ApiPropType.toggle, 'Spans: a drag changes the stretch as it goes. Off: once, when it ends.', fallback: true),
      ApiProp('order', ApiPropType.number, 'Where it sits among the pinned lanes: a lower number is higher up.', fallback: 100),
    ]),
    ApiSocket('band', 'Band', 'A band of colours along the top of the score, in the preview, a video and a web page: the staves leave it room while it has anything.', single: true, ports: [
      ApiPort('areas', 'areas() → list',
          'The band’s stretches, in score order: {from = quarter, to = quarter, color = colour, label = text}, each named at its start. Asked again when the extension’s data or the language changes.'),
    ]),
  ];

  /// The whole API as Markdown: every socket with its ports and properties, every library with
  /// its functions. docs/extension-api.md is the guide followed by this.
  static String reference() {
    final out = StringBuffer('## Sockets\n');
    String since(int level) => level > 1 ? ' *(API $level)*' : '';
    for (final s in sockets) {
      out.writeln('\n### ${s.title} (`${s.type}`)${since(s.since)}\n\n${s.summary}${s.single ? ' An extension has one.' : ''}');
      if (s.ports.isNotEmpty) out.writeln('\nPorts:\n');
      for (final p in s.ports) {
        out.writeln('- `${p.signature}`${since(p.since)}: ${p.summary}');
      }
      if (s.props.isNotEmpty) out.writeln('\nProperties (set on the node in connect.json):\n');
      for (final p in s.props) {
        final kind = switch (p.type) {
          ApiPropType.choice => p.choices.map((c) => '`"$c"`').join(' or '),
          ApiPropType.node => 'the id of a ${p.choices.join(' or ')} node',
          ApiPropType.icon => 'an icon’s name',
          final t => t.name,
        };
        out.writeln('- `${p.name}` ($kind${p.fallback == null ? '' : ', default `${p.fallback}`'})${since(p.since)}: ${p.summary}');
      }
    }
    out.writeln('\nIcons: ${icons.map((i) => '`$i`').join(', ')}.');
    out.writeln('\nA colour is `"#rrggbb"`, or a table of its red, green and blue from 0 to 1: `{r = 1, g = 0.5, b = 0}`.');
    out.writeln('\n## Libraries');
    for (final l in libraries) {
      out.writeln('\n### `${l.name}`\n\n${l.summary}\n');
      for (final f in l.functions) {
        out.writeln('- `${f.signature}`${since(f.since)}: ${f.summary}');
        if (f.example case final example?) out.writeln('\n  ```lua\n${example.split('\n').map((line) => '  $line').join('\n')}\n  ```\n');
      }
      for (final (name, summary) in l.values) {
        out.writeln('- `${l.name}.$name`: $summary');
      }
    }
    return out.toString();
  }

  /// What Curator's Lua has beyond Lua 5.4's own libraries (string, table, math, utf8, os.time,
  /// os.clock and os.date).
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
      ApiFunction('curator.tr_in', 'curator.tr_in(context, text, values) → text',
          'curator.tr for a text that means two things: its translation in a context ("context|text" in locales/<language>.json), else as curator.tr gives it.',
          example: 'curator.tr_in("music", "Key")'),
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
      ApiFunction('score.passes', 'score.passes() → list', 'Every pass through the score, a repeat being one more: {from, to} in quarters, {starts, ends} in seconds.'),
      ApiFunction('score.end_seconds', 'score.end_seconds() → seconds', 'When the music ends.'),
      ApiFunction('score.spans', 'score.spans(places, end) → list',
          'Markers (places in quarters, each running to the next) as they sound, in order: {index, from, to} in seconds, index 0 for the music before the first. A repeat back into an earlier one is that one again. They cover the performance from 0 to end seconds (the end of the music by default).',
          example: 'for _, span in ipairs(score.spans({0, 16, 48})) do\n  print(span.index, span.from, span.to)\nend'),
      ApiFunction('score.rehearsal_marks', 'score.rehearsal_marks() → list', 'The score’s rehearsal marks, in the order written: {at, bar, text}.'),
      ApiFunction('score.parts', 'score.parts() → list', 'The instruments: {id, name, staves}.'),
      ApiFunction('score.music', 'score.music(done)',
          'Reads the music off to the side, so a long score doesn’t stop the editor, then calls done(music): music.notes is every pitched note as it sounds, part by part ({from, to} in quarters, pitch as a MIDI number at concert pitch, tied when a tie carries it on from the note before, chord for a chord’s notes after its first, part, staff, voice); music.keys the key signatures at concert pitch ({bar, fifths, minor}, each from its bar on; minor only when the score says which); music.bars where each bar starts, then the score’s end. done(nil) when the score changed meanwhile. In the editor only.',
          example: 'score.music(function(music)\n  if not music then return end\n  print(#music.notes, "notes")\nend)', editor: true),
    ]),
    ApiLibrary('text', 'Text as people write it: every kind of space counts, in any script.', [
      ApiFunction('text.trim', 'text.trim(text) → text', 'text without the spaces at its ends.'),
      ApiFunction('text.squeeze', 'text.squeeze(text) → text', 'text with every run of spaces and line breaks made one space, and none at its ends: a name as it is kept.'),
      ApiFunction('text.lower', 'text.lower(text) → text', 'text in lower case, in any script.'),
      ApiFunction('text.upper', 'text.upper(text) → text', 'text in upper case, in any script.'),
      ApiFunction('text.lines', 'text.lines(text) → list', 'The lines of text.'),
    ]),
    ApiLibrary('math', 'Lua’s math library, and:', [
      ApiFunction('math.round', 'math.round(x) → number', 'x to the nearest whole number, a half away from zero.'),
      ApiFunction('math.clamp', 'math.clamp(x, low, high) → number', 'x, no lower than low and no higher than high.'),
    ], addsTo: true),
    ApiLibrary('lanes', 'What is selected in the extension’s lanes. In the editor only.', [
      ApiFunction('lanes.selected', 'lanes.selected(lane) → index', 'The item selected in a lane (the lane’s id in the connector); nil when none is.'),
      ApiFunction('lanes.select', 'lanes.select(lane, index)', 'Selects item index of a lane; nil selects nothing.'),
    ]),
    ApiLibrary('editor', 'The editor’s playhead and grid. In the editor only.', [
      ApiFunction('editor.playhead', 'editor.playhead() → seconds', 'Where the playhead is.'),
      ApiFunction('editor.seek', 'editor.seek(seconds)', 'Moves the playhead.'),
      ApiFunction('editor.beat', 'editor.beat(quarter, pass) → start, end', 'The beat of the lanes’ grid a place is in (bars when zoomed far out).'),
      ApiFunction('editor.snap', 'editor.snap(quarter, pass) → quarter', 'The nearest line of the lanes’ grid, as a drag snaps to it.'),
      ApiFunction('editor.next', 'editor.next(quarter, unit) → quarter', 'The first barline after a place (unit "bar", the default) or the first beat ("beat"); the score’s end when there is none.'),
      ApiFunction('editor.previous', 'editor.previous(quarter, unit) → quarter', 'The last barline (or beat) before a place; the score’s start when there is none.'),
      ApiFunction('editor.nearest', 'editor.nearest(quarter, unit) → quarter', 'The barline (or beat) nearest a place.'),
    ]),
    ApiLibrary('ui', 'Dialogs, laid out as the app’s own. In the editor only.', [
      ApiFunction('ui.form', 'ui.form(spec)',
          'Opens a dialog. spec: title, confirm (its button’s title), width, spacing (between rows), rows (each a list of fields: {id, label, value, type = "text", "switch" or "choice", max, flex, focus, hint (a text, or a function of the values), lines, options (a choice’s: {value, label, color})}), leading (buttons at the left: {id, title}), check(values) → nil when it can be confirmed, a text saying why not, or "" to say nothing, and done(values, button), called with the fields’ values by id and "confirm" or a leading button’s id. Cancel calls nothing.',
          example:
              'ui.form{\n  title = "Add Note", confirm = "Add",\n  rows = { { {id = "text", label = "Note", focus = true} } },\n  check = function(values) return values.text == "" and "" or nil end,\n  done = function(values) add(values.text) end,\n}'),
      ApiFunction('ui.message', 'ui.message(text)', 'Shows a line at the window’s foot for a moment.'),
    ]),
  ];
}
