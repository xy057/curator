import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'beat_grid.dart';
import 'curated_scene.dart';
import 'extension/lua_json.dart';
import 'extension/markers.dart';
import 'lua.dart';
import 'score_caption.dart';
import 'score_text.dart';
import 'scroll_map.dart';
import 'zip_entries.dart';

/// Lua code as it travels, in a package: an extension (a `.cpe`, which a project carries) or a
/// plugin (a `.cgp`, which the app keeps). What both are made of: files of Lua, each a module,
/// their texts in other languages, and files of their own to read.
abstract interface class ScriptPackage {
  /// Stable for good: what is kept for it is kept under it.
  String get id;
  String get name;
  String? get version;

  /// Each Lua file by its path under `src/` ("main.lua", "util/text.lua").
  Map<String, String> get sources;

  /// Each language's texts by its locale ("zh-Hans"): the English → the translation.
  Map<String, Map<String, String>> get locales;

  /// Each file under `assets/` by its path there.
  Map<String, Uint8List> get assets;

  /// The file a `require` of [module] reads; null: there is none.
  String? fileOf(String module);
}

/// What an extension's and a plugin's manifest (`extension.json`, `plugin.json`) say alike.
mixin PackageManifest implements ScriptPackage {
  /// The manifest, whole.
  Map<String, Object?> get manifest;

  /// Every file of it by its path in the archive, the mimetype aside.
  Map<String, Uint8List> get files;

  /// Stable for good: what is kept for it (its switch, its data or settings) is kept under it.
  /// Curator's own are one word ("captions"); anyone else's has a dot, a domain backwards
  /// ("com.example.lyrics").
  @override
  String get id => _text('id') ?? '';
  @override
  String get name => _text('name') ?? id;
  @override
  String? get version => _text('version');
  String get summary => _text('summary') ?? '';
  String get keywords => _text('keywords') ?? '';
  String? get author => _text('author');
  String? get url => _text('url');

  /// The name of one of the app's icons; null or unknown: the kind's own.
  String? get icon => _text('icon');

  /// The API level it was written for (its API's `level` is this build's).
  int get api => switch (manifest['api']) { final num n => n.toInt(), _ => 1 };

  String? _text(String key) => switch (manifest[key]) { final String s when s.trim().isNotEmpty => s.trim(), _ => null };

  @override
  String? fileOf(String module) {
    final path = PackageFiles.pathOf(module);
    return sources.containsKey(path) ? path : null;
  }
}

/// A package's files, zipped and read: what an extension's and a plugin's file have in common.
abstract final class PackageFiles {
  /// The most a package unpacks to, a file of it, and how many it holds.
  static const maxBytes = 64 << 20, maxTextBytes = 4 << 20, maxFiles = 2000;

  /// A module's name ("util.text") for a file's path ("util/text.lua").
  static String moduleOf(String path) => (path.endsWith('.lua') ? path.substring(0, path.length - 4) : path).replaceAll('/', '.');

  /// The path of the file a `require` of [module] reads.
  static String pathOf(String module) => '${module.replaceAll('.', '/')}.lua';

  static Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

  /// A name as an id's word: "Count Bars…" is "count-bars".
  static String slug(String name) => name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');

  /// An id for a package the user makes, named [name], that isn't [taken] yet: "user.my-notes",
  /// then "user.my-notes-2"; [kind] ("plugin") when the name has no letters or digits.
  static String userId(String name, String kind, bool Function(String id) taken) {
    final slug = PackageFiles.slug(name);
    final base = 'user.${slug.isEmpty ? kind : slug}';
    for (var n = 1;; n++) {
      final id = n == 1 ? base : '$base-$n';
      if (!taken(id)) return id;
    }
  }

  /// What [files] (each by its path, in order) hold, as one number: the same for the same.
  static String digest(Map<String, Uint8List> files) {
    final all = BytesBuilder(copy: false);
    files.forEach((path, bytes) {
      all
        ..add(utf8.encode('$path\n${bytes.length}\n'))
        ..add(bytes);
    });
    return sha256.convert(all.takeBytes()).toString();
  }

  /// The files of the archive [bytes] are, by path, its mimetype aside. [what] names what it
  /// should be ("extension"), for the [FormatException] that says what is wrong with it.
  static Map<String, Uint8List> unzip(Uint8List bytes, {required String what}) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw FormatException('This isn’t a Curator $what.');
    }
    if (archive.files.length > maxFiles) throw FormatException('The $what holds too many files.');
    final files = <String, Uint8List>{};
    var total = 0;
    for (final file in archive.files) {
      if (!file.isFile || file.name == 'mimetype') continue;
      final text = !file.name.startsWith('assets/');
      final content = ZipEntries.read(file, limit: text ? maxTextBytes : maxBytes - total);
      total += content.length;
      if (total > maxBytes) throw FormatException('The $what is too big.');
      files[file.name] = content;
    }
    return files;
  }

  /// [files] as an archive that starts with its [mimeType], stored: the same bytes for the same
  /// files, whenever it is written.
  static Uint8List zip(String mimeType, Map<String, Uint8List> files) {
    final at = DateTime.utc(2000).millisecondsSinceEpoch ~/ 1000;
    final archive = Archive()..add(ArchiveFile.noCompress('mimetype', mimeType.length, ascii.encode(mimeType))..lastModTime = at);
    files.forEach((path, bytes) => archive.add(ArchiveFile.bytes(path, bytes)..lastModTime = at));
    return ZipEncoder().encodeBytes(archive);
  }

  /// [files]' text at [path]; a [FormatException] when it isn't text.
  static String text(Map<String, Uint8List> files, String path) {
    try {
      return utf8.decode(files[path]!);
    } on FormatException {
      throw FormatException('$path isn’t text.');
    }
  }

  /// [files]' JSON at [path]; a [FormatException] when it isn't JSON.
  static Object? json(Map<String, Uint8List> files, String path) {
    try {
      return jsonDecode(text(files, path));
    } on FormatException {
      throw FormatException('$path isn’t JSON.');
    }
  }

  /// What [files] hold beyond what says what the package is: its Lua by path under `src/`, its
  /// texts by locale, its assets by path. [what] names the package, for a path it may not have.
  static ({Map<String, String> sources, Map<String, Map<String, String>> locales, Map<String, Uint8List> assets}) sorted(Map<String, Uint8List> files,
      {required String what}) {
    final sources = <String, String>{}, locales = <String, Map<String, String>>{}, assets = <String, Uint8List>{};
    for (final path in files.keys) {
      if (path.contains('..') || path.startsWith('/')) throw FormatException('$path isn’t a path a${what.startsWith('e') ? 'n' : ''} $what may have.');
      if (path.startsWith('src/') && path.endsWith('.lua')) {
        sources[path.substring(4)] = text(files, path);
      } else if (path.startsWith('locales/') && path.endsWith('.json')) {
        final table = json(files, path);
        if (table is! Map<String, Object?>) throw FormatException('$path isn’t a table of texts.');
        locales[path.substring(8, path.length - 5)] = {
          for (final MapEntry(:key, :value) in table.entries)
            if (value is String) key: value,
        };
      } else if (path.startsWith('assets/')) {
        assets[path.substring(7)] = files[path]!;
      }
    }
    return (sources: sources, locales: locales, assets: assets);
  }
}

/// Something wrong with an extension or a plugin: its code doesn't read, a function raised an
/// error, a wire leads nowhere. [file] and [line] say where when it is known; [where] what was
/// calling ("lane.items", a command's name).
class ScriptProblem {
  const ScriptProblem(this.extension, this.message, {this.file, this.line, this.trace = const [], this.where, this.warning = false});

  /// The id of the extension or the plugin it is in.
  final String extension;
  final String message;

  /// Whether it stops nothing: something a later Curator may know, kept and unused here.
  final bool warning;
  final String? file, where;
  final int? line;
  final List<String> trace;

  factory ScriptProblem.of(String extension, LuaError e, {String? where}) =>
      ScriptProblem(extension, e.message, file: e.chunk, line: e.line, trace: List.unmodifiable(e.trace), where: where);

  @override
  String toString() => message;
}

/// What running Lua stands on, whoever's it is: the score showing, the interface's language,
/// what it keeps for every project, and where what it says and gets wrong goes.
abstract class ScriptHost {
  /// The app-wide settings it keeps (the same in every project), as JSON.
  Object? get settings => null;
  void saveSettings(Object? json) => throw StateError('Settings can’t be changed here.');

  /// The score, and the performance it is synced to; null while none is open.
  LoadedScore? get score;
  ScoreTimeline? get timeline;
  BeatGrid? get beats;

  /// The interface's language, as a locale ("en", "zh-Hans").
  String get language;

  /// The app's own translation of [text], for Curator's own; null: none.
  String? translate(String text) => null;

  void report(ScriptProblem problem);

  /// A line it printed.
  void print(String extension, String line) {}
}

/// A package's Lua running: its world, its files as modules, and the libraries every package
/// gets (`curator` for itself, `text`, `score`). An extension's and a plugin's runtime add what
/// is theirs to it.
abstract class ScriptRuntime {
  ScriptRuntime(ScriptPackage package, ScriptHost host)
      : _package = package,
        _host = host {
    lua = Lua(print: (line) => host.print(package.id, line));
    _installCore();
    _installText();
    _installScore();
  }

  /// The steps a call that draws a frame may take, and any other.
  static const frameSteps = 400000, eventSteps = 20000000;

  final ScriptPackage _package;
  final ScriptHost _host;
  late final Lua lua;

  String get id => _package.id;

  /// This build's level of the API the package is written for (`curator.api`).
  int get apiLevel;

  /// Whether that API has [name] (`curator.has`): a function, a library, a value.
  bool knows(String name);

  // MARK: Files

  final _modules = <String, Object?>{};
  final _loading = <String>{};

  /// Whether file [path] has been run.
  bool loaded(String path) => _modules.containsKey(path);

  /// What file [path] gave when it was run ([module]); null before, or when it gave nothing.
  Object? moduleOf(String path) => _modules[path];

  /// What file [path] gives those that require it: what it returns, or else the table of the
  /// globals it set (its functions). Runs it the first time.
  Object? module(String path) {
    if (_modules.containsKey(path)) return _modules[path];
    final code = _package.sources[path];
    if (code == null) throw LuaError("there is no file '$path'");
    if (!_loading.add(path)) throw LuaError("'$path' requires itself");
    try {
      final env = LuaTable()..shape = LuaShape.map;
      final r = lua.load(code, chunk: path, env: env).call([PackageFiles.moduleOf(path)]);
      return _modules[path] = (r.isEmpty ? null : r[0]) ?? env;
    } finally {
      _loading.remove(path);
    }
  }

  // MARK: Calls

  /// Calls [fn] (one the code handed over: a form's `done`, a command's `run`) with [args]:
  /// what it returns, or null when it raised an error (reported to the host).
  List<Object?>? call(LuaFunction fn, {List<Object?> args = const [], String? where, int steps = eventSteps}) {
    try {
      return lua.call(fn, args, steps);
    } on LuaError catch (e) {
      _host.report(ScriptProblem.of(id, e, where: where));
      return null;
    }
  }

  /// Runs [code] in its world (its libraries, `require` for its files) and gives what it
  /// returns; what goes wrong is thrown (a [LuaError]). For a console, and tests.
  List<Object?> run(String code, {String chunk = 'console'}) =>
      lua.call(lua.load(code, chunk: chunk, env: LuaTable()..shape = LuaShape.map), const [], eventSteps);

  // MARK: Text

  /// [text] in the interface's language: the package's own translation, else the app's, else
  /// as written; each `{name}` in it replaced by [values]' entry. With a [context] (a text that
  /// means two things: a "Key" of the music, a "Key" of the keyboard), the translation for it
  /// when there is one: "context|text" in the package's locales.
  String translate(String text, [LuaTable? values, String? context]) {
    final own = _package.locales[_host.language];
    var out = (context == null ? null : own?['$context|$text'] ?? _host.translate('$context\u0004$text')) ?? own?[text] ?? _host.translate(text) ?? text;
    if (values != null) {
      out = out.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) {
        final v = values[m[1]];
        return v == null ? m[0]! : lua.tostring(v);
      });
    }
    return out;
  }

  // MARK: Libraries

  /// Adds [functions] as the global table [name] (or to it, when it is there). What one gives
  /// the script pays for as it does for what it makes itself ([Lua.made]): a text read, a list
  /// of the score's bars. Not those of [kept], which hand over a table there already is.
  LuaTable library(String name, Map<String, LuaCall> functions, {Set<String> kept = const {}}) {
    final existing = lua.globals[name];
    final t = existing is LuaTable ? existing : (LuaTable()..shape = LuaShape.map);
    functions.forEach((key, fn) {
      t[key] = LuaBuiltin('$name.$key', kept.contains(key) ? fn : (a) => fn(a)..forEach(lua.made));
    });
    lua.globals[name] = t;
    return t;
  }

  void _installCore() {
    final host = _host, package = _package;
    lua.globals['require'] = LuaBuiltin('require', (a) {
      final name = a.string(0, 'require'), path = package.fileOf(name);
      if (path == null) throw LuaError("module '$name' not found (there is no src/${name.replaceAll('.', '/')}.lua)");
      return [module(path)];
    });
    final curator = library('curator', {
      'has': (a) {
        final name = a.string(0, 'has');
        if (!knows(name)) return const [false];
        if (name.contains(':')) return const [true];
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
    }, kept: const {'list', 'map'});
    curator['api'] = apiLevel;
    curator['id'] = package.id;
    curator['name'] = package.name;
    curator['version'] = package.version;
    curator['null'] = LuaJson.nil;
    // The language as it is when it is read: it can change while the code runs, as what
    // curator.tr gives does.
    curator.metatable = LuaTable()..['__index'] = LuaBuiltin('curator.__index', (a) => [a.at(1) == 'language' ? host.language : null]);
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
    final host = _host;
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
