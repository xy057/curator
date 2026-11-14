import '../beat_grid.dart';
import '../curated_scene.dart';
import '../lua.dart';
import '../score_caption.dart';
import '../score_text.dart';
import '../scroll_map.dart';
import 'api.dart';
import 'lua_json.dart';
import 'markers.dart';
import 'package.dart';

/// Something wrong with an extension: its code doesn't read, a function raised an error, a wire
/// leads nowhere. [file] and [line] say where when it is known; [where] which socket was
/// calling ("lane.items").
class ExtensionProblem {
  const ExtensionProblem(this.extension, this.message, {this.file, this.line, this.trace = const [], this.where, this.warning = false});
  final String extension, message;

  /// Whether it stops nothing: something a later Curator may know, kept and unused here.
  final bool warning;
  final String? file, where;
  final int? line;
  final List<String> trace;

  factory ExtensionProblem.of(String extension, LuaError e, {String? where}) =>
      ExtensionProblem(extension, e.message, file: e.chunk, line: e.line, trace: List.unmodifiable(e.trace), where: where);

  @override
  String toString() => message;
}

/// What a running extension stands on: the project it is in and the app around it. The editor
/// gives one that edits; a video's export and a web page's player give one that only reads.
abstract class ExtensionHost {
  /// What the extension saved in the project, as JSON; null: nothing yet.
  Object? get data;

  /// Changes whenever [data] does (an edit, Undo, a project opened).
  int get revision;

  /// Keeps [json] as the extension's data: an edit, named [label] in Undo. Where nothing can
  /// be edited (an export, a page), a [StateError].
  void save(Object? json, {String? label});

  /// The app-wide settings the extension keeps (the same in every project), as JSON.
  Object? get settings => null;
  void saveSettings(Object? json) => throw StateError('Settings can’t be changed here.');

  /// The score, and the performance it is synced to; null while none is open.
  LoadedScore? get score;
  ScoreTimeline? get timeline;
  BeatGrid? get beats;

  /// The interface's language, as a locale ("en", "zh-Hans").
  String get language;

  /// The app's own translation of [text], for Curator's own extensions; null: none.
  String? translate(String text) => null;

  void report(ExtensionProblem problem);

  /// A line the extension printed.
  void print(String extension, String line) {}

  /// Adds what this host offers beyond the engine's (the editor's `ui`, `lanes`…), once the
  /// runtime's own libraries are in place.
  void install(ExtensionRuntime runtime) {}
}

/// An extension running: its Lua world, its files loaded, its wires found. One per project it
/// is on in (and one more per export or page, which read a copy).
class ExtensionRuntime {
  ExtensionRuntime(this.package, this.host) {
    lua = Lua(print: (line) => host.print(package.id, line));
    _installCore();
    _installText();
    _installScore();
    host.install(this);
    _loadWired();
  }

  /// The steps a call that draws a frame may take, and any other.
  static const frameSteps = 400000, eventSteps = 20000000;

  final ExtensionPackage package;
  final ExtensionHost host;
  late final Lua lua;

  /// What went wrong loading it: none when every wired file read and ran.
  final List<ExtensionProblem> problems = [];

  String get id => package.id;
  ConnectorGraph get graph => package.graph;

  /// The nodes of [type] the connector has, in its order.
  Iterable<GraphNode> nodes(String type) => graph.nodes.where((n) => n.type == type);

  // MARK: Files

  final _modules = <String, Object?>{};
  final _loading = <String>{};

  /// What file [path] gives those that require it: what it returns, or else the table of the
  /// globals it set (its functions). Runs it the first time.
  Object? module(String path) {
    if (_modules.containsKey(path)) return _modules[path];
    final code = package.sources[path];
    if (code == null) throw LuaError("there is no file '$path'");
    if (!_loading.add(path)) throw LuaError("'$path' requires itself");
    try {
      final env = LuaTable()..shape = LuaShape.map;
      final r = lua.load(code, chunk: path, env: env).call([ExtensionPackage.moduleOf(path)]);
      return _modules[path] = (r.isEmpty ? null : r[0]) ?? env;
    } finally {
      _loading.remove(path);
    }
  }

  void _loadWired() {
    final files = <String>{for (final w in graph.wires) w.file};
    for (final path in files) {
      if (!package.sources.containsKey(path)) {
        problems.add(ExtensionProblem(id, 'The connector names $path, which isn’t in the extension.', file: 'connect.json'));
        continue;
      }
      try {
        lua.call(LuaBuiltin('load', (_) => [module(path)]), const [], eventSteps);
      } on LuaError catch (e) {
        problems.add(ExtensionProblem.of(id, e, where: path));
      }
    }
    for (final w in graph.wires) {
      if (!_modules.containsKey(w.file)) continue;
      if (_function(w) == null) problems.add(ExtensionProblem(id, '${w.file} has no function ${w.function} (wired to ${w.from}).', file: w.file));
    }
    problems.forEach(host.report);
  }

  LuaFunction? _function(GraphWire w) {
    final m = _modules[w.file];
    final f = m is LuaTable ? m[w.function] : null;
    return f is LuaFunction ? f : null;
  }

  // MARK: Sockets

  final _wired = <String, LuaFunction?>{};
  final _muted = <String>{};

  LuaFunction? _target(String node, String port) {
    final key = '$node.$port';
    if (_wired.containsKey(key)) return _wired[key];
    final w = graph.wire(node, port);
    return _wired[key] = w == null ? null : _function(w);
  }

  /// Whether [port] of [node] leads to a function.
  bool wired(String node, String port) => _target(node, port) != null;

  /// Calls the function wired to [port] of [node] with [args] (Lua values): what it returns,
  /// or null when nothing is wired or it raised an error (reported to the host). With [quiet],
  /// a port that failed isn't called again until [revive]: one that draws every frame says
  /// what is wrong once.
  List<Object?>? fire(String node, String port, {List<Object?> args = const [], int steps = eventSteps, bool quiet = false}) {
    final fn = _target(node, port);
    if (fn == null) return null;
    final key = '$node.$port';
    if (quiet && _muted.contains(key)) return null;
    calls[key] = (calls[key] ?? 0) + 1;
    try {
      return lua.call(fn, args, steps);
    } on LuaError catch (e) {
      if (quiet) _muted.add(key);
      host.report(ExtensionProblem.of(id, e, where: key));
      return null;
    }
  }

  /// Calls the function wired to [port] of [node] as [fire] does, but what it raises is thrown
  /// (a [LuaError]): for a caller that must stop on it. Nothing wired gives nothing.
  List<Object?> invoke(String node, String port, [List<Object?> args = const []]) {
    final fn = _target(node, port);
    if (fn == null) return const [];
    calls['$node.$port'] = (calls['$node.$port'] ?? 0) + 1;
    return lua.call(fn, args, eventSteps);
  }

  /// How many times each port ("lane.items") has been called since it started: what the
  /// connector's picture shows beside a port while the extension runs.
  final calls = <String, int>{};

  /// The first value [fire] gives; null too when there is none.
  Object? ask(String node, String port, {List<Object?> args = const [], int steps = eventSteps, bool quiet = false}) =>
      fire(node, port, args: args, steps: steps, quiet: quiet)?.firstOrNull;

  /// Calls [fn] (one the extension handed over: a form's `done`) as [fire] calls a wired one.
  List<Object?>? call(LuaFunction fn, {List<Object?> args = const [], String? where}) {
    try {
      return lua.call(fn, args, eventSteps);
    } on LuaError catch (e) {
      host.report(ExtensionProblem.of(id, e, where: where));
      return null;
    }
  }

  /// Runs [code] in the extension's world (its libraries, `require` for its files) and gives
  /// what it returns; what goes wrong is thrown (a [LuaError]). For a console, and tests.
  List<Object?> run(String code, {String chunk = 'console'}) =>
      lua.call(lua.load(code, chunk: chunk, env: LuaTable()..shape = LuaShape.map), const [], eventSteps);

  /// Lets the ports [fire] stopped calling be called again: after the data changed.
  void revive() => _muted.clear();

  // MARK: The core library

  LuaTable? _data;
  int? _dataRevision;

  /// The extension's saved data as its Lua table: the one table until the data changes under
  /// it (Undo, a project opened), so what the code changes in it is there until then, and
  /// `curator.save()` keeps it.
  LuaTable get dataTable {
    if (_data == null || _dataRevision != host.revision) {
      final value = LuaJson.toLua(host.data);
      _data = value is LuaTable ? value : LuaTable();
      _dataRevision = host.revision;
      revive();
    }
    return _data!;
  }

  /// [text] in the interface's language: the extension's own translation, else the app's, else
  /// as written; each `{name}` in it replaced by [values]' entry. With a [context] (a text that
  /// means two things: a "Key" of the music, a "Key" of the keyboard), the translation for it
  /// when there is one: "context|text" in the extension's locales.
  String translate(String text, [LuaTable? values, String? context]) {
    final own = package.locales[host.language];
    var out = (context == null ? null : own?['$context|$text'] ?? host.translate('$context\u0004$text')) ?? own?[text] ?? host.translate(text) ?? text;
    if (values != null) {
      out = out.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) {
        final v = values[m[1]];
        return v == null ? m[0]! : lua.tostring(v);
      });
    }
    return out;
  }

  /// Adds [functions] as the global table [name] (or to it, when it is there).
  LuaTable library(String name, Map<String, LuaCall> functions) {
    final existing = lua.globals[name];
    final t = existing is LuaTable ? existing : (LuaTable()..shape = LuaShape.map);
    functions.forEach((key, fn) => t[key] = LuaBuiltin('$name.$key', fn));
    lua.globals[name] = t;
    return t;
  }

  void _installCore() {
    lua.globals['require'] = LuaBuiltin('require', (a) {
      final name = a.string(0, 'require'), path = package.fileOf(name);
      if (path == null) throw LuaError("module '$name' not found (there is no src/${name.replaceAll('.', '/')}.lua)");
      return [module(path)];
    });
    final curator = library('curator', {
      'has': (a) {
        final name = a.string(0, 'has');
        if (!ExtensionApi.has(name)) return const [false];
        if (name.startsWith('socket:')) return const [true];
        // A library the list has but this host doesn't give (a page has no `ui`) isn't here.
        Object? at = lua.globals;
        for (final part in name.split('.')) {
          at = at is LuaTable ? at[part] : null;
        }
        return [at != null];
      },
      'log': (a) {
        host.print(id, a.map(lua.tostring).join('\t'));
        return const [];
      },
      'tr': (a) => [translate(a.string(0, 'tr'), a.tableOr(1, 'tr'))],
      'tr_in': (a) => [translate(a.string(1, 'tr_in'), a.tableOr(2, 'tr_in'), a.string(0, 'tr_in'))],
      'data': (a) => [dataTable],
      'save': (a) {
        final label = a.stringOr(0, 'save');
        host.save(LuaJson.fromLua(dataTable, where: 'data'), label: label);
        // What was saved is this table: no need to read it back.
        _dataRevision = host.revision;
        return const [];
      },
      'settings': (a) {
        final value = LuaJson.toLua(host.settings);
        return [value is LuaTable ? value : LuaTable()];
      },
      'save_settings': (a) {
        host.saveSettings(LuaJson.fromLua(a.table(0, 'save_settings'), where: 'settings'));
        return const [];
      },
      'list': (a) => [(a.tableOr(0, 'list') ?? LuaTable())..shape = LuaShape.list],
      'map': (a) => [(a.tableOr(0, 'map') ?? LuaTable())..shape = LuaShape.map],
      'asset': (a) {
        final path = a.string(0, 'asset'), bytes = package.assets[path];
        if (bytes == null) return const [null];
        return [String.fromCharCodes(bytes)];
      },
    });
    curator['api'] = ExtensionApi.level;
    curator['id'] = package.id;
    curator['name'] = package.name;
    curator['version'] = package.version;
    curator['language'] = host.language;
    curator['null'] = LuaJson.nil;
  }

  // MARK: The text library

  static final _spaces = RegExp(r'\s+');

  void _installText() {
    library('text', {
      'trim': (a) => [a.string(0, 'text.trim').trim()],
      'trim_start': (a) => [a.string(0, 'text.trim_start').trimLeft()],
      'trim_end': (a) => [a.string(0, 'text.trim_end').trimRight()],
      'flatten': (a) => [a.string(0, 'text.flatten').replaceAll(_spaces, ' ')],
      'runs': (a) => [
            LuaTable.list([for (final run in captionRuns(a.string(0, 'text.runs'))) LuaTable.map({'text': run.text, 'italic': run.italic, 'bold': run.bold})]),
          ],
      'squeeze': (a) => [a.string(0, 'text.squeeze').replaceAll(_spaces, ' ').trim()],
      'lower': (a) => [a.string(0, 'text.lower').toLowerCase()],
      'upper': (a) => [a.string(0, 'text.upper').toUpperCase()],
      'lines': (a) => [LuaTable.list(a.string(0, 'text.lines').split(RegExp(r'\r\n|\r|\n')))],
    });
  }

  // MARK: The score library

  Never _noScore(String fn) => throw LuaError("'$fn' needs a score, and none is open");

  void _installScore() {
    BeatGrid beats(String fn) => host.beats ?? _noScore(fn);
    ScoreTimeline timeline(String fn) => host.timeline ?? _noScore(fn);
    LoadedScore score(String fn) => host.score ?? _noScore(fn);

    library('score', {
      'open': (a) => [host.score != null],
      'quarters': (a) => [beats('score.quarters').totalQuarters],
      'bars': (a) {
        final starts = beats('score.bars').measureStarts;
        return [
          LuaTable.list([
            for (var i = 0; i + 1 < starts.length; i++) LuaTable.map({'number': i + 1, 'start': starts[i], 'length': starts[i + 1] - starts[i]}),
          ]),
        ];
      },
      'bar_at': (a) {
        final b = beats('score.bar_at'), q = a.number(0, 'score.bar_at').toDouble();
        final m = b.measureAt(q).clamp(0, b.measureStarts.length - 2);
        return [m + 1, b.measureStarts[m]];
      },
      'beat_at': (a) {
        final beat = beats('score.beat_at').beatAt(a.number(0, 'score.beat_at').toDouble());
        return [beat.start, beat.end];
      },
      'format': (a) => [beats('score.format').format(a.number(0, 'score.format').toDouble(), compact: a.truthy(1))],
      'parse': (a) => [beats('score.parse').parse(a.string(0, 'score.parse'))],
      'seconds': (a) => [timeline('score.seconds').secondsAtQuarter(a.number(0, 'score.seconds').toDouble(), pass: (a.integerOr(1, 'score.seconds') ?? 1) - 1)],
      'quarter': (a) => [timeline('score.quarter').quarterAtSeconds(a.number(0, 'score.quarter').toDouble())],
      'pass_at': (a) => [timeline('score.pass_at').passAt(a.number(0, 'score.pass_at').toDouble()) + 1],
      'passes': (a) {
        final t = timeline('score.passes');
        return [
          LuaTable.list([
            for (final (k, p) in t.passes.indexed)
              LuaTable.map({'from': p.start, 'to': p.end, 'starts': t.secondsAtQuarter(p.start, pass: k), 'ends': t.secondsAtQuarter(p.end, pass: k)}),
          ]),
        ];
      },
      'end_seconds': (a) => [timeline('score.end_seconds').endSeconds],
      'spans': (a) {
        final t = timeline('score.spans'), places = a.table(0, 'score.spans');
        final spans = markerSpans(
          [for (final (i, v) in places.array.indexed) v is num ? v.toDouble() : throw LuaError("bad argument #1 to 'score.spans' (place ${i + 1} is not a number)")],
          t,
          end: a.numberOr(1, 'score.spans')?.toDouble(),
        );
        return [
          LuaTable.list([for (final s in spans) LuaTable.map({'index': s.marker + 1, 'from': s.start, 'to': s.end})]),
        ];
      },
      'rehearsal_marks': (a) {
        final s = score('score.rehearsal_marks'), starts = s.timeline.measureStarts;
        return [
          LuaTable.list([
            for (final text in s.texts)
              if (text.kind == ScoreTextKind.rehearsal && text.measure >= 0 && text.measure < starts.length - 1)
                LuaTable.map({'at': starts[text.measure], 'bar': text.measure + 1, 'text': s.currentText(text)}),
          ]),
        ];
      },
      'title': (a) => [score('score.title').metadata.title],
      'parts': (a) => [
            LuaTable.list([
              for (final p in score('score.parts').metadata.parts) LuaTable.map({'id': p.id, 'name': p.name, 'staves': p.staffNumbers.length}),
            ]),
          ],
    });
  }
}
