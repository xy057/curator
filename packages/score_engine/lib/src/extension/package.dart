import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../zip_entries.dart';

/// An extension as it travels: a `.cpe` file (Curator Project Extension), a zip archive holding
///
///     mimetype          application/x-curator-extension (stored first, uncompressed)
///     extension.json    what it is: id, name, version, summary, the API level it needs ([manifest])
///     connect.json      the connector: Curator's sockets it uses, wired to its functions ([graph])
///     src/*.lua         its code, a module a file ([sources], by path under src/)
///     locales/*.json    its texts in other languages, `{"English": "translation"}` ([locales])
///     assets/*          files of its own it can read ([assets])
///     README.md         what it does, shown in the editor ([readme])
///
/// Everything is read as it is and written back as it was: a key or a node this build doesn't
/// know stays in the file, so an extension made for a later Curator survives being opened and
/// saved by this one (see [ConnectorGraph]).
@immutable
class ExtensionPackage {
  ExtensionPackage({
    required Map<String, Object?> manifest,
    ConnectorGraph? graph,
    Map<String, String> sources = const {},
    Map<String, Map<String, String>> locales = const {},
    Map<String, Uint8List> assets = const {},
    this.readme,
  })  : manifest = Map.unmodifiable(manifest),
        graph = graph ?? ConnectorGraph(),
        sources = Map.unmodifiable(sources),
        locales = Map.unmodifiable(locales),
        assets = Map.unmodifiable(assets);

  static const mimeType = 'application/x-curator-extension';
  static const fileExtension = 'cpe';

  /// The most a package unpacks to, a file of it, and how many it holds.
  static const maxBytes = 64 << 20, maxTextBytes = 4 << 20, maxFiles = 2000;

  /// A new extension: one file with one function, wired to the project opening.
  factory ExtensionPackage.blank({required String id, required String name}) => ExtensionPackage(
        manifest: {'format': mimeType, 'id': id, 'name': name, 'version': '1.0.0', 'summary': '', 'api': 1},
        graph: ConnectorGraph(
          nodes: [GraphNode(id: 'project', type: 'project', x: 40, y: 40)],
          wires: [const GraphWire('project.opened', 'main.lua#opened')],
          files: const {'main.lua': (360, 40)},
        ),
        sources: const {'main.lua': '-- Runs when a project with this extension opens, and when it is turned on.\nfunction opened()\n  curator.log("Hello from " .. curator.name)\nend\n'},
        readme: '# $name\n',
      );

  /// `extension.json`, whole.
  final Map<String, Object?> manifest;
  final ConnectorGraph graph;

  /// Each Lua file by its path under `src/` ("main.lua", "util/text.lua").
  final Map<String, String> sources;

  /// Each language's texts by its locale ("zh-Hans"): the English → the translation.
  final Map<String, Map<String, String>> locales;

  /// Each file under `assets/` by its path there.
  final Map<String, Uint8List> assets;
  final String? readme;

  /// Stable for good: a project keeps its switch and its data under it. Curator's own are one
  /// word ("captions"); anyone else's has a dot, a domain backwards ("com.example.lyrics").
  String get id => _text('id') ?? '';
  String get name => _text('name') ?? id;
  String? get version => _text('version');
  String get summary => _text('summary') ?? '';
  String get keywords => _text('keywords') ?? '';
  String? get author => _text('author');
  String? get url => _text('url');

  /// The name of one of the app's icons; null or unknown: the extensions' own.
  String? get icon => _text('icon');

  /// The API level it was written for ([ExtensionApi.level] is this build's).
  int get api => switch (manifest['api']) { final num n => n.toInt(), _ => 1 };

  /// What it says of the data it saves: `version` (raised when the data's shape changes; its
  /// `project.load` is given the version a project was saved with), and for Curator's own the
  /// project `module` it is kept in.
  Map<String, Object?> get data => switch (manifest['data']) { final Map<String, Object?> m => m, _ => const {} };
  int get dataVersion => switch (data['version']) { final num n => n.toInt(), _ => 1 };

  String? _text(String key) => switch (manifest[key]) { final String s when s.trim().isNotEmpty => s.trim(), _ => null };

  /// Whether [id] is one an extension from elsewhere may have.
  static bool isThirdPartyId(String id) => RegExp(r'^[a-z0-9][a-z0-9-]*(\.[a-z0-9][a-z0-9-]*)+$').hasMatch(id) && id.length <= 80;

  /// Whether [id] is one of Curator's own may have.
  static bool isBuiltInId(String id) => RegExp(r'^[a-zA-Z][a-zA-Z0-9]{0,31}$').hasMatch(id);

  /// A module's name ("util.text") for a file's path ("util/text.lua").
  static String moduleOf(String path) => (path.endsWith('.lua') ? path.substring(0, path.length - 4) : path).replaceAll('/', '.');

  /// The file a `require` of [module] reads; null: there is none.
  String? fileOf(String module) {
    final path = '${module.replaceAll('.', '/')}.lua';
    return sources.containsKey(path) ? path : null;
  }

  ExtensionPackage copyWith({
    Map<String, Object?>? manifest,
    ConnectorGraph? graph,
    Map<String, String>? sources,
    Map<String, Map<String, String>>? locales,
    Map<String, Uint8List>? assets,
    String? readme,
  }) =>
      ExtensionPackage(
        manifest: manifest ?? this.manifest,
        graph: graph ?? this.graph,
        sources: sources ?? this.sources,
        locales: locales ?? this.locales,
        assets: assets ?? this.assets,
        readme: readme ?? this.readme,
      );

  // MARK: Files

  static const _encoder = JsonEncoder.withIndent('  ');

  /// Every file of it by its path in the archive, in the order written (the mimetype aside).
  late final Map<String, Uint8List> files = Map.unmodifiable({
    'extension.json': _bytes('${_encoder.convert(manifest)}\n'),
    'connect.json': _bytes('${graph.toText()}\n'),
    if (readme != null) 'README.md': _bytes(readme!),
    for (final path in sources.keys.toList()..sort()) 'src/$path': _bytes(sources[path]!),
    for (final locale in locales.keys.toList()..sort()) 'locales/$locale.json': _bytes('${_encoder.convert(locales[locale])}\n'),
    for (final path in assets.keys.toList()..sort()) 'assets/$path': assets[path]!,
  });

  static Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

  /// What it holds, as one number: two packages holding the same have the same.
  late final String digest = () {
    final all = BytesBuilder(copy: false);
    files.forEach((path, bytes) {
      all
        ..add(utf8.encode('$path\n${bytes.length}\n'))
        ..add(bytes);
    });
    return sha256.convert(all.takeBytes()).toString();
  }();

  @override
  bool operator ==(Object other) => other is ExtensionPackage && other.digest == digest;
  @override
  int get hashCode => digest.hashCode;

  /// A package from its files by path, as [files] lists them. What is wrong with it is a
  /// [FormatException] that says so.
  factory ExtensionPackage.fromFiles(Map<String, Uint8List> files) {
    String text(String path) {
      try {
        return utf8.decode(files[path]!);
      } on FormatException {
        throw FormatException('$path isn’t text.');
      }
    }

    Object? json(String path) {
      try {
        return jsonDecode(text(path));
      } on FormatException {
        throw FormatException('$path isn’t JSON.');
      }
    }

    if (!files.containsKey('extension.json')) throw const FormatException('This isn’t a Curator extension.');
    final manifest = json('extension.json');
    if (manifest is! Map<String, Object?> || (manifest['format'] ?? mimeType) != mimeType) throw const FormatException('This isn’t a Curator extension.');
    final id = manifest['id'];
    if (id is! String || !(isThirdPartyId(id) || isBuiltInId(id))) throw const FormatException('The extension has no id Curator can use.');
    final sources = <String, String>{}, locales = <String, Map<String, String>>{}, assets = <String, Uint8List>{};
    for (final path in files.keys) {
      if (path.contains('..') || path.startsWith('/')) throw FormatException('$path isn’t a path an extension may have.');
      if (path.startsWith('src/') && path.endsWith('.lua')) {
        sources[path.substring(4)] = text(path);
      } else if (path.startsWith('locales/') && path.endsWith('.json')) {
        final table = json(path);
        if (table is! Map<String, Object?>) throw FormatException('$path isn’t a table of texts.');
        locales[path.substring(8, path.length - 5)] = {
          for (final MapEntry(:key, :value) in table.entries)
            if (value is String) key: value,
        };
      } else if (path.startsWith('assets/')) {
        assets[path.substring(7)] = files[path]!;
      }
    }
    return ExtensionPackage(
      manifest: manifest,
      graph: files.containsKey('connect.json') ? ConnectorGraph.fromJson(json('connect.json')) : ConnectorGraph(),
      sources: sources,
      locales: locales,
      assets: assets,
      readme: files.containsKey('README.md') ? text('README.md') : null,
    );
  }

  /// The package a `.cpe` file's [bytes] hold. A [FormatException] says what is wrong with one.
  factory ExtensionPackage.read(Uint8List bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('This isn’t a Curator extension.');
    }
    if (archive.files.length > maxFiles) throw const FormatException('The extension holds too many files.');
    final files = <String, Uint8List>{};
    var total = 0;
    for (final file in archive.files) {
      if (!file.isFile || file.name == 'mimetype') continue;
      final text = !file.name.startsWith('assets/');
      final content = ZipEntries.read(file, limit: text ? maxTextBytes : maxBytes - total);
      total += content.length;
      if (total > maxBytes) throw const FormatException('The extension is too big.');
      files[file.name] = content;
    }
    return ExtensionPackage.fromFiles(files);
  }

  /// It as a `.cpe` file: the same bytes for the same package, whenever it is written.
  Uint8List write() => _written;

  late final Uint8List _written = () {
    final at = DateTime.utc(2000).millisecondsSinceEpoch ~/ 1000;
    final archive = Archive()
      ..add(ArchiveFile.noCompress('mimetype', mimeType.length, ascii.encode(mimeType))..lastModTime = at);
    files.forEach((path, bytes) => archive.add(ArchiveFile.bytes(path, bytes)..lastModTime = at));
    return ZipEncoder().encodeBytes(archive);
  }();
}

/// A socket of Curator's an extension uses: one node of its [ConnectorGraph]. What kind
/// ([type]: "lane", "command"…; see [ExtensionApi.sockets]), the name its wires call it by
/// ([id]), how it is set ([props]: a lane's title, a command's icon) and where it sits in the
/// connector's picture.
@immutable
class GraphNode {
  GraphNode({required this.id, required this.type, Map<String, Object?> props = const {}, this.x = 0, this.y = 0}) : props = Map.unmodifiable(props);
  final String id, type;
  final Map<String, Object?> props;
  final double x, y;

  GraphNode copyWith({String? id, Map<String, Object?>? props, double? x, double? y}) =>
      GraphNode(id: id ?? this.id, type: type, props: props ?? this.props, x: x ?? this.x, y: y ?? this.y);

  Map<String, Object?> toJson() => {'id': id, 'type': type, 'at': [_tidy(x), _tidy(y)], ...props};

  static num _tidy(double v) => v == v.roundToDouble() ? v.toInt() : v;
}

/// A wire: Curator calls [to] (a function of a file, "main.lua#draw") for [from] (a port of a
/// node, "lane.items").
@immutable
class GraphWire {
  const GraphWire(this.from, this.to);
  final String from, to;

  /// The node [from] is a port of, and the port.
  String get node => from.substring(0, from.lastIndexOf('.').clamp(0, from.length));
  String get port => from.substring(from.lastIndexOf('.') + 1);

  /// The file [to] names, and its function.
  String get file => to.contains('#') ? to.substring(0, to.indexOf('#')) : to;
  String get function => to.contains('#') ? to.substring(to.indexOf('#') + 1) : '';

  @override
  bool operator ==(Object other) => other is GraphWire && other.from == from && other.to == to;
  @override
  int get hashCode => Object.hash(from, to);
}

/// The connector (`connect.json`): the sockets an extension uses ([nodes]), each port of one
/// wired to a function of a file ([wires], a port to one function), and where each file's box
/// sits in the picture ([files]).
///
///     {"nodes": [{"id": "lane", "type": "lane", "at": [40, 60], "title": "Chapters"}],
///      "wires": [["lane.items", "main.lua#items"]],
///      "files": {"main.lua": [420, 60]}}
@immutable
class ConnectorGraph {
  ConnectorGraph({List<GraphNode> nodes = const [], List<GraphWire> wires = const [], Map<String, (double, double)> files = const {}, Map<String, Object?> other = const {}})
      : nodes = List.unmodifiable(nodes),
        wires = List.unmodifiable(wires),
        files = Map.unmodifiable(files),
        other = Map.unmodifiable(other);

  final List<GraphNode> nodes;
  final List<GraphWire> wires;
  final Map<String, (double, double)> files;

  /// What else the file says, kept for whoever understands it.
  final Map<String, Object?> other;

  GraphNode? node(String id) => nodes.where((n) => n.id == id).firstOrNull;

  /// The function wired to [port] of node [node]; null: none.
  GraphWire? wire(String node, String port) => wires.where((w) => w.from == '$node.$port').firstOrNull;

  ConnectorGraph copyWith({List<GraphNode>? nodes, List<GraphWire>? wires, Map<String, (double, double)>? files}) =>
      ConnectorGraph(nodes: nodes ?? this.nodes, wires: wires ?? this.wires, files: files ?? this.files, other: other);

  /// A name for a new node of [type] no node has yet ("lane", "lane2"…).
  String freeId(String type) {
    final base = type.replaceAll(RegExp(r'[^a-z0-9]'), '');
    for (var n = 1;; n++) {
      final id = n == 1 ? base : '$base$n';
      if (node(id) == null) return id;
    }
  }

  factory ConnectorGraph.fromJson(Object? json) {
    if (json is! Map<String, Object?>) throw const FormatException('connect.json isn’t a connector.');
    (double, double) at(Object? v) => switch (v) { [final num x, final num y] => (x.toDouble(), y.toDouble()), _ => (0, 0) };
    final nodes = <GraphNode>[], ids = <String>{};
    for (final n in switch (json['nodes']) { final List<Object?> l => l, _ => const <Object?>[] }) {
      if (n is! Map<String, Object?>) throw const FormatException('connect.json has a node that isn’t one.');
      final id = n['id'], type = n['type'];
      if (id is! String || type is! String || !RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(id)) throw const FormatException('connect.json has a node without a name or a type.');
      if (!ids.add(id)) throw FormatException('connect.json has two nodes named $id.');
      final (x, y) = at(n['at']);
      nodes.add(GraphNode(id: id, type: type, x: x, y: y, props: {
        for (final MapEntry(:key, :value) in n.entries)
          if (key != 'id' && key != 'type' && key != 'at') key: value,
      }));
    }
    final wires = <GraphWire>[], wired = <String>{};
    for (final w in switch (json['wires']) { final List<Object?> l => l, _ => const <Object?>[] }) {
      if (w case [final String from, final String to] when from.contains('.')) {
        if (!wired.add(from)) throw FormatException('connect.json wires $from twice.');
        wires.add(GraphWire(from, to));
      } else {
        throw const FormatException('connect.json has a wire that isn’t one.');
      }
    }
    return ConnectorGraph(
      nodes: nodes,
      wires: wires,
      files: {
        for (final MapEntry(:key, :value) in switch (json['files']) { final Map<String, Object?> m => m.entries, _ => const <MapEntry<String, Object?>>[] }) key: at(value),
      },
      other: {
        for (final MapEntry(:key, :value) in json.entries)
          if (key != 'nodes' && key != 'wires' && key != 'files') key: value,
      },
    );
  }

  Map<String, Object?> toJson() => {
        ...other,
        'nodes': [for (final n in nodes) n.toJson()],
        'wires': [
          for (final w in wires) [w.from, w.to],
        ],
        'files': {
          for (final MapEntry(:key, :value) in files.entries) key: [GraphNode._tidy(value.$1), GraphNode._tidy(value.$2)],
        },
      };

  /// As it is written: a node a line, a wire a line, so a change reads as one.
  String toText() {
    final json = toJson(), out = StringBuffer('{\n');
    for (final MapEntry(:key, :value) in other.entries) {
      out.writeln('  ${jsonEncode(key)}: ${jsonEncode(value)},');
    }
    void lines(String key, List<Object?> values, {required bool last}) {
      out.writeln('  "$key": [');
      for (final (i, v) in values.indexed) {
        out.writeln('    ${jsonEncode(v)}${i + 1 < values.length ? ',' : ''}');
      }
      out.writeln('  ]${last ? '' : ','}');
    }

    lines('nodes', json['nodes'] as List<Object?>, last: false);
    lines('wires', json['wires'] as List<Object?>, last: false);
    out.write('  "files": ${jsonEncode(json['files'])}\n}');
    return out.toString();
  }
}
