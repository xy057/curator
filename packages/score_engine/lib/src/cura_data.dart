/// CuraScript's data: what a file of Curator's is, written down a field a line. Its statements
/// (`LaneScript`) say what to do to the lanes; its data says what a project holds, and a
/// project (`project.cura` in a `.ccs`) and a settings file (`settings.cura` in a `.ccf`) are
/// kept in it:
///
/// ```
/// # A Curator file in CuraScript.
/// format "application/x-curated-score"
/// layout 3
/// score
///   name "Symphony.musicxml"
///   entry "score/Symphony.musicxml"
///
/// module sync version 1
///   leadIn 0.5
///   anchors
///     - [0, 0.5]
///     - [4, 2.12, 8]
///
/// module script version 1 optional
///   text
///     | clear
///     | show "Flute 1" 1-8
/// ```
///
/// A field is its name and its value. A value is a number, text in quotes, `true`, `false`,
/// `none`, a list in brackets (`[1, "two"]`) or `{}` (nothing in it); or, with nothing after
/// the name, what is under it, indented: fields, `-` items (a list), or `|` lines (text of
/// several lines, each as it is after the `|` and one space). `#` starts a comment. In quotes,
/// `\"`, `\\`, `\n`, `\r`, `\t` and `\u{263a}` are what they say. A name is a word (`A`–`Z`,
/// `a`–`z`, digits, `_`, `.` and `-`, not starting with a digit, `.` or `-`: the same on every
/// platform, whatever its Unicode tables), or in quotes.
/// `module <id> version <n>` heads a module of the file, its fields under it; `optional` after
/// it: a Curator that can't read it may open the file without it.
///
/// It holds what JSON does, exactly ([CuraData.holds]): a value read back is the one written, a
/// whole number (`2`) an int and one with a point (`2.0`) a double, as `jsonDecode` gives them;
/// and what it can't hold, it neither writes nor reads. Its grammar in full, and the one way
/// Curator writes each file: docs/project-format.md. A change to either is a new layout there.
library;

import 'dart:convert' show JsonUnsupportedObjectError;

/// A module of a file in CuraScript: `module <id> version <version>`, [optional] or not, and
/// its [data] under it.
typedef CuraModule = ({String id, int version, bool optional, Map<String, Object?> data});

/// A file in CuraScript, read: its own [fields] (what it is, what wrote it…) and its [modules],
/// in the order written.
typedef CuraDocument = ({Map<String, Object?> fields, List<CuraModule> modules});

abstract final class CuraData {
  /// How many fields and lists may be one in another, a file's own fields or a module's the
  /// first: a damaged or hostile file can't run the reader out of stack.
  static const maxDepth = 256;

  static const _indent = '  ';

  /// A name written as it is; any other in quotes.
  static final _bare = RegExp(r'[A-Za-z_][A-Za-z0-9_.\-]*');
  static final _number = RegExp(r'-?\d+(\.\d+)?([eE][+-]?\d+)?');

  /// Whether [value] can be written and read back the same: what JSON holds (fields named by
  /// text, lists, text, numbers that are finite, `true`, `false`, null), no more than [maxDepth]
  /// fields and lists deep.
  static bool holds(Object? value) => _fits(value, maxDepth);

  static bool _fits(Object? value, int room) => switch (value) {
        null || bool() || int() || String() => true,
        final double n => n.isFinite,
        final List<Object?> list => room > 0 && list.every((v) => _fits(v, room - 1)),
        final Map<Object?, Object?> map => room > 0 && map.entries.every((e) => e.key is String && _fits(e.value, room - 1)),
        _ => false,
      };

  /// Whether [version] can be a module's: a whole number of nine digits at most.
  static bool isVersion(int version) => version >= 0 && version <= 999999999;

  // MARK: Writing

  /// [fields], then [modules] each under its heading, as CuraScript; [heading] first, each line
  /// a comment. Throws a [JsonUnsupportedObjectError] for a value it can't hold ([holds]), and an
  /// [ArgumentError] for a module's version that isn't one ([isVersion]): nothing is written
  /// that wouldn't read back.
  static String write(Map<String, Object?> fields, {List<CuraModule> modules = const [], List<String> heading = const []}) {
    if (!holds(fields)) throw JsonUnsupportedObjectError(fields, cause: 'The file’s fields are not what CuraScript holds.');
    for (final m in modules) {
      if (!isVersion(m.version)) throw ArgumentError.value(m.version, 'version', 'The module ${m.id}’s version is not a whole number of nine digits at most');
      if (!holds(m.data)) throw JsonUnsupportedObjectError(m.data, cause: 'The module ${m.id} holds what CuraScript doesn’t.');
    }
    final out = StringBuffer();
    for (final line in heading) {
      out.writeln('# $line'.trimRight());
    }
    _fields(out, fields, 0);
    for (final m in modules) {
      out
        ..writeln()
        ..writeln('module ${_name(m.id)} version ${m.version}${m.optional ? ' optional' : ''}');
      _fields(out, m.data, 1);
    }
    return out.toString();
  }

  static void _fields(StringBuffer out, Map<String, Object?> fields, int depth) {
    for (final MapEntry(:key, :value) in fields.entries) {
      // (At the top, a field called `module` would read as a module's heading.)
      out.write('${_indent * depth}${depth == 0 && key == 'module' ? _quote(key) : _name(key)}');
      _after(out, value, depth);
    }
  }

  /// [value], after its name or its `-` at [depth]: on that line, or under it.
  static void _after(StringBuffer out, Object? value, int depth) {
    if (_inline(value)) {
      out.writeln(' ${_value(value)}');
      return;
    }
    out.writeln();
    final under = _indent * (depth + 1);
    switch (value) {
      case final String text:
        for (final line in text.split('\n')) {
          out.writeln(line.isEmpty ? '$under|' : '$under| $line');
        }
      case final Map<Object?, Object?> map:
        _fields(out, {for (final MapEntry(:key, :value) in map.entries) _key(key): value}, depth + 1);
      case final List<Object?> list:
        for (final item in list) {
          out.write('$under-');
          _after(out, item, depth + 1);
        }
      default:
        throw JsonUnsupportedObjectError(value); // (not met: what is written is checked first)
    }
  }

  static String _key(Object? key) => key is String ? key : throw JsonUnsupportedObjectError(key, cause: 'A name is not text.');

  /// Whether [value] is written on its name's line: anything but fields, a list holding more
  /// than numbers, text and the like, and text of several lines.
  static bool _inline(Object? value) => switch (value) {
        final String text => !_lines(text),
        final List<Object?> list => list.every((v) => _scalar(v) && !(v is String && _lines(v))),
        _ => _scalar(value),
      };

  static bool _scalar(Object? value) => switch (value) {
        null || bool() || num() || String() => true,
        final Map<Object?, Object?> map => map.isEmpty,
        final List<Object?> list => list.isEmpty,
        _ => false,
      };

  /// Whether [text] is written as `|` lines: it has several, and nothing in it that a line
  /// can't hold as it is.
  static bool _lines(String text) => text.contains('\n') && !text.runes.any((c) => c != 0x0A && c != 0x09 && _escaped(c));

  /// Whether [rune] is written as an escape in quotes.
  static bool _escaped(int rune) => rune < 0x20 || rune == 0x7F || rune == 0x2028 || rune == 0x2029 || (rune >= 0xD800 && rune <= 0xDFFF);

  static String _value(Object? value) => switch (value) {
        null => 'none',
        true => 'true',
        false => 'false',
        final int n => '$n',
        final double n when n.isFinite => '$n',
        final String text => _quote(text),
        final Map<Object?, Object?> map when map.isEmpty => '{}',
        final List<Object?> list => '[${list.map(_value).join(', ')}]',
        _ => throw JsonUnsupportedObjectError(value),
      };

  static String _name(String name) => _bare.matchAsPrefix(name)?.end == name.length ? name : _quote(name);

  static String _quote(String text) {
    final out = StringBuffer('"');
    for (final rune in text.runes) {
      switch (rune) {
        case 0x22:
          out.write(r'\"');
        case 0x5C:
          out.write(r'\\');
        case 0x0A:
          out.write(r'\n');
        case 0x0D:
          out.write(r'\r');
        case 0x09:
          out.write(r'\t');
        case _ when _escaped(rune):
          out.write('\\u{${rune.toRadixString(16)}}');
        default:
          out.writeCharCode(rune);
      }
    }
    return (out..write('"')).toString();
  }

  // MARK: Reading

  /// [text] read back. Throws a [FormatException] that says the line of what doesn't read. A
  /// byte order mark before it (an editor's, saving it by hand) is no part of it.
  static CuraDocument read(String text) => _Reader(text.startsWith('﻿') ? text.substring(1) : text).document();
}

/// A line that says something (not blank, not only a comment): its [number] (1 the first), how
/// far it is [indent]ed, and its [text] from there.
typedef _Line = ({int number, int indent, String text});

class _Reader {
  _Reader(String source)
      : _lines = [
          for (final (i, line) in source.split(RegExp(r'\r\n|\r|\n')).indexed)
            if (_indentOf(line) case final indent when indent < line.length && line[indent] != '#')
              (number: i + 1, indent: indent, text: line.substring(indent)),
        ];

  final List<_Line> _lines;
  var _at = 0;

  static int _indentOf(String line) {
    var i = 0;
    while (i < line.length && (line[i] == ' ' || line[i] == '\t')) {
      i++;
    }
    return i;
  }

  static Never _fail(_Line line, String what) => throw FormatException('line ${line.number}: $what');

  _Line? get _next => _at < _lines.length ? _lines[_at] : null;

  CuraDocument document() {
    final fields = <String, Object?>{}, modules = <CuraModule>[], ids = <String>{};
    while (_at < _lines.length) {
      final line = _lines[_at];
      if (line.indent != 0) _fail(line, 'its indent doesn’t line up with the lines above it.');
      final cursor = _Cursor(line);
      if (cursor.heading()) {
        final id = cursor.name(), version = cursor.version(), optional = cursor.word('optional');
        cursor.end();
        if (!ids.add(id)) _fail(line, 'the module “$id” is in the file twice.');
        _at++;
        final data = switch (_next) {
          final under? when under.indent > 0 => _block(under.indent, 1),
          _ => <String, Object?>{},
        };
        if (data is! Map<String, Object?>) _fail(line, 'a module holds fields.');
        modules.add((id: id, version: version, optional: optional, data: data));
      } else {
        _field(fields, line, cursor, 0, 1);
      }
    }
    return (fields: fields, modules: modules);
  }

  /// The value of the lines from here indented [indent] (the first's): fields or `-` items,
  /// [level] deep among fields and lists (a file's own fields or a module's the first), or `|`
  /// lines, as the first is.
  Object? _block(int indent, int level) {
    final first = _lines[_at];
    if (first.text.startsWith('|')) return _text(indent);
    if (level > CuraData.maxDepth) _fail(first, 'it is too deep in what it is in.');
    if (_isItem(first.text)) return _list(indent, level);
    return _fields(indent, level);
  }

  static bool _isItem(String text) => text == '-' || text.startsWith('- ') || text.startsWith('-\t') || text.startsWith('-#');

  /// The lines from here that are indented [indent], each checked to be so.
  Iterable<_Line> _run(int indent) sync* {
    while (_at < _lines.length && _lines[_at].indent >= indent) {
      final line = _lines[_at];
      if (line.indent > indent) _fail(line, 'its indent doesn’t line up with the lines above it.');
      yield line;
    }
  }

  Map<String, Object?> _fields(int indent, int level) {
    final out = <String, Object?>{};
    for (final line in _run(indent)) {
      if (_isItem(line.text) || line.text.startsWith('|')) _fail(line, 'it is among fields: a field’s name goes first.');
      _field(out, line, _Cursor(line), indent, level);
    }
    return out;
  }

  /// A field of the fields [level] deep, into [into].
  void _field(Map<String, Object?> into, _Line line, _Cursor cursor, int indent, int level) {
    final name = cursor.name();
    if (into.containsKey(name)) _fail(line, '“$name” is here twice.');
    _at++;
    into[name] = _after(line, cursor, indent, level);
  }

  List<Object?> _list(int indent, int level) => [
        for (final line in _run(indent))
          if (!_isItem(line.text))
            _fail(line, 'it is among a list’s items: each starts with “-”.')
          else
            () {
              _at++;
              return _after(line, _Cursor(line, 1), indent, level);
            }(),
      ];

  String _text(int indent) => [
        for (final line in _run(indent))
          if (!line.text.startsWith('|'))
            _fail(line, 'it is among lines of text: each starts with “|”.')
          else
            () {
              _at++;
              final rest = line.text.substring(1);
              return rest.startsWith(' ') ? rest.substring(1) : rest;
            }(),
      ].join('\n');

  /// The value after a name or a `-` on [line] (where [cursor] is), of fields or a list [level]
  /// deep: on the line, else what is under it.
  Object? _after(_Line line, _Cursor cursor, int indent, int level) {
    if (!cursor.atEnd) {
      final value = cursor.value(level);
      cursor.end();
      return value;
    }
    if (_next case final under? when under.indent > indent) return _block(under.indent, level + 1);
    _fail(line, 'it has no value: write it after the name, or under it, indented.');
  }
}

/// Reading along one line.
class _Cursor {
  _Cursor(this.line, [this.at = 0]);
  final _Line line;
  int at;

  String get _text => line.text;

  Never _fail(String what) => _Reader._fail(line, what);

  void _spaces() {
    while (at < _text.length && (_text[at] == ' ' || _text[at] == '\t')) {
      at++;
    }
  }

  /// Whether nothing but a comment is left.
  bool get atEnd {
    _spaces();
    return at >= _text.length || _text[at] == '#';
  }

  void end() {
    if (!atEnd) _fail('“${_text.substring(at)}” isn’t part of it.');
  }

  /// Whether the line is a module's heading: it starts with the word `module`.
  bool heading() => word('module');

  /// Takes [word] when it is next.
  bool word(String word) {
    _spaces();
    final m = CuraData._bare.matchAsPrefix(_text, at);
    if (m == null || m[0] != word) return false;
    at = m.end;
    return true;
  }

  String name() {
    _spaces();
    if (at < _text.length && _text[at] == '"') return _quoted();
    final m = CuraData._bare.matchAsPrefix(_text, at) ?? _fail('a name is wanted, a word or in quotes.');
    at = m.end;
    return m[0]!;
  }

  /// `version <n>`, a module's.
  int version() {
    if (!word('version')) _fail('“version” and a number are wanted after the module’s name.');
    _spaces();
    final m = RegExp(r'\d+').matchAsPrefix(_text, at) ?? _fail('the module’s version is wanted, a whole number.');
    if (m[0]!.length > 9) _fail('the module’s version is a whole number of nine digits at most.');
    at = m.end;
    return int.parse(m[0]!);
  }

  /// A value written on the line, of fields or a list [level] deep: one in brackets is a level
  /// deeper.
  Object? value(int level) {
    _spaces();
    if (at >= _text.length) _fail('a value is wanted.');
    if ((_text[at] == '[' || _text[at] == '{') && level + 1 > CuraData.maxDepth) _fail('it is too deep in what it is in.');
    switch (_text[at]) {
      case '"':
        return _quoted();
      case '{':
        at++;
        _spaces();
        if (at >= _text.length || _text[at] != '}') _fail('“{” is only ever “{}”: fields go under their name.');
        at++;
        return <String, Object?>{};
      case '[':
        at++;
        final out = <Object?>[];
        _spaces();
        if (at < _text.length && _text[at] == ']') {
          at++;
          return out;
        }
        while (true) {
          out.add(value(level + 1));
          _spaces();
          if (at < _text.length && _text[at] == ',') {
            at++;
          } else if (at < _text.length && _text[at] == ']') {
            at++;
            return out;
          } else {
            _fail('“,” or “]” is wanted in the list.');
          }
        }
    }
    if (CuraData._number.matchAsPrefix(_text, at) case final m?) {
      final text = m[0]!;
      final number = m[1] == null && m[2] == null ? int.tryParse(text) ?? double.parse(text) : double.parse(text);
      if (!number.isFinite) _fail('“$text” is too big a number.');
      at = m.end;
      return number;
    }
    if (CuraData._bare.matchAsPrefix(_text, at) case final m?) {
      final value = switch (m[0]!.toLowerCase()) {
        'true' => true,
        'false' => false,
        'none' => null,
        _ => _fail('“${m[0]}” isn’t a value: text goes in quotes.'),
      };
      at = m.end;
      return value;
    }
    _fail('“${_text.substring(at)}” isn’t a value.');
  }

  String _quoted() {
    at++; // the opening quote
    final out = StringBuffer();
    while (at < _text.length) {
      final c = _text[at++];
      if (c == '"') return out.toString();
      if (c != r'\') {
        out.write(c);
        continue;
      }
      if (at >= _text.length) break;
      switch (_text[at++]) {
        case '"':
          out.write('"');
        case r'\':
          out.write(r'\');
        case 'n':
          out.write('\n');
        case 'r':
          out.write('\r');
        case 't':
          out.write('\t');
        case 'u':
          final m = RegExp(r'\{([0-9a-fA-F]{1,6})\}').matchAsPrefix(_text, at);
          final rune = m == null ? null : int.parse(m[1]!, radix: 16);
          if (m == null || rune! > 0x10FFFF) _fail('“\\u” is followed by a character’s number in braces: \\u{263a}.');
          at = m.end;
          out.writeCharCode(rune);
        case final other:
          _fail('“\\$other” isn’t an escape: “\\\\” is a backslash.');
      }
    }
    _fail('the closing quote is missing.');
  }
}
