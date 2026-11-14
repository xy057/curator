import '../lua.dart';
import 'api.dart';
import 'package.dart';
import 'runtime.dart';

/// What is wrong with [package] as it is written, found without running it: a file that doesn't
/// read as Lua (with its line), a wire to a file or a function that isn't there, a node of a
/// kind this Curator doesn't have or with a port it doesn't have, a second node of a kind an
/// extension has one of, an API level this Curator hasn't reached. What a later Curator may
/// know (a socket, a port) is a warning: it is kept, and does nothing here.
List<ExtensionProblem> checkExtension(ExtensionPackage package) {
  final id = package.id, problems = <ExtensionProblem>[];
  void error(String message, {String? file, int? line}) => problems.add(ExtensionProblem(id, message, file: file, line: line));
  void warning(String message, {String? file}) => problems.add(ExtensionProblem(id, message, file: file, warning: true));

  if (package.api > ExtensionApi.level) warning('It needs API level ${package.api}; this Curator has ${ExtensionApi.level}.', file: 'extension.json');

  // Each file: whether it reads, and the functions it offers.
  final functions = <String, Set<String>>{};
  for (final MapEntry(key: path, value: source) in package.sources.entries) {
    try {
      functions[path] = {for (final f in Lua.functionsIn(source, chunk: path)) f.name};
    } on LuaError catch (e) {
      error(e.message, file: path, line: e.line);
    }
  }

  final seen = <String>{};
  for (final node in package.graph.nodes) {
    final socket = ExtensionApi.socket(node.type);
    if (socket == null) {
      warning('This Curator has no “${node.type}” socket (${node.id}).', file: 'connect.json');
    } else if (socket.single && !seen.add(node.type)) {
      error('An extension has one “${node.type}” socket (${node.id} is a second).', file: 'connect.json');
    }
  }
  for (final wire in package.graph.wires) {
    final node = package.graph.node(wire.node);
    if (node == null) {
      error('${wire.from} is wired, but there is no node ${wire.node}.', file: 'connect.json');
      continue;
    }
    final socket = ExtensionApi.socket(node.type);
    if (socket != null && socket.port(wire.port) == null) warning('A “${node.type}” socket has no port ${wire.port} here (${wire.from}).', file: 'connect.json');
    final source = package.sources[wire.file];
    if (source == null) {
      error('${wire.from} is wired to ${wire.file}, which isn’t in the extension.', file: 'connect.json');
    } else if (functions[wire.file] case final found?) {
      // One made another way (a table returned whole) isn't seen here: said only when its
      // name is nowhere in the file.
      if (!found.contains(wire.function) && !RegExp('\\b${RegExp.escape(wire.function)}\\b').hasMatch(source)) {
        error('${wire.file} has no function ${wire.function} (wired to ${wire.from}).', file: wire.file);
      }
    }
  }
  return problems;
}
