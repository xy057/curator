import '../lua.dart';
import '../script.dart';
import 'api.dart';
import 'lua_json.dart';
import 'package.dart';

/// Something wrong with an extension ([ScriptProblem]).
typedef ExtensionProblem = ScriptProblem;

/// What a running extension stands on: the project it is in and the app around it. The editor
/// gives one that edits; a video's export and a web page's player give one that only reads.
abstract class ExtensionHost extends ScriptHost {
  /// What the extension saved in the project, as JSON; null: nothing yet.
  Object? get data;

  /// Changes whenever [data] does (an edit, Undo, a project opened).
  int get revision;

  /// Keeps [json] as the extension's data: an edit, named [label] in Undo. Where nothing can
  /// be edited (an export, a page), a [StateError].
  void save(Object? json, {String? label});

  /// Adds what this host offers beyond the engine's (the editor's `ui`, `lanes`…), once the
  /// runtime's own libraries are in place.
  void install(ExtensionRuntime runtime) {}
}

/// An extension running: its Lua world, its files loaded, its wires found. One per project it
/// is on in (and one more per export or page, which read a copy).
class ExtensionRuntime extends ScriptRuntime {
  ExtensionRuntime(this.package, this.host) : super(package, host) {
    library('curator', {
      'data': (a) => [dataTable],
      'save': (a) {
        final label = a.stringOr(0, 'save');
        host.save(LuaJson.fromLua(dataTable, where: 'data'), label: label);
        // What was saved is this table: no need to read it back.
        _dataRevision = host.revision;
        return const [];
      },
    }, kept: const {'data'});
    host.install(this);
    _loadWired();
  }

  /// The steps a call may take (every port's is an event's: none draws a frame).
  static const eventSteps = ScriptRuntime.eventSteps;

  final ExtensionPackage package;
  final ExtensionHost host;

  /// What went wrong loading it: none when every wired file read and ran.
  final List<ExtensionProblem> problems = [];

  ConnectorGraph get graph => package.graph;

  @override
  int get apiLevel => ExtensionApi.level;
  @override
  bool knows(String name) => ExtensionApi.has(name);

  /// The nodes of [type] the connector has, in its order.
  Iterable<GraphNode> nodes(String type) => graph.nodes.where((n) => n.type == type);

  // MARK: Files

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
      if (!loaded(w.file)) continue;
      if (_function(w) == null) problems.add(ExtensionProblem(id, '${w.file} has no function ${w.function} (wired to ${w.from}).', file: w.file));
    }
    problems.forEach(host.report);
  }

  LuaFunction? _function(GraphWire w) {
    final m = moduleOf(w.file);
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
}
