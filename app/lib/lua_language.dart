import 'package:material_ui/material_ui.dart';
import 'package:re_editor/re_editor.dart';
import 'package:score_engine/score_engine.dart' show ApiFunction, ExtensionApi;

import 'lilypond_language.dart' show lilyPondTheme;

/// Lua as the extension editor reads it: its text in a controller that colours each line as it
/// is drawn ([luaCode]: [luaTokens], in the code editors' colours) and what is offered as it is
/// typed ([LuaPrompts]: Lua's words, and every function of the extension API).
///
/// A line is coloured alone, from where the line above left off: in a long string or a long
/// comment (`[[ ]]`, `--[==[ ]==]`), the only things that run over lines ([LuaStates] keeps
/// where each line starts, read again from the first line that changed).

/// The extension editor's text of a Lua file, [text] to begin with.
CodeLineEditingController luaCode(String text) {
  late final CodeLineEditingController code;
  final states = LuaStates(() => code.codeLines);
  return code = CodeLineEditingController(
    codeLines: CodeLines.fromText(text),
    options: const CodeLineOptions(indentSize: 2),
    spanBuilder: ({required context, required index, required codeLine, required textSpan, required style}) {
      final brightness = Theme.of(context).brightness;
      final theme = _themes[brightness] ??= lilyPondTheme(brightness);
      final tokens = luaTokens(codeLine.text, state: states.at(index));
      return TextSpan(style: style, children: [
        for (final (scope, text) in tokens.runs) TextSpan(text: text, style: scope == null ? null : theme[scope]),
      ]);
    },
  );
}

final _themes = <Brightness, Map<String, TextStyle>>{};

const _keywords = {
  'and', 'break', 'do', 'else', 'elseif', 'end', 'for', 'function', 'goto', 'if', 'in', 'local', 'not', 'or', 'repeat', 'return', 'then', //
  'until', 'while',
};
const _literals = {'nil', 'true', 'false'};

/// Lua's own libraries and functions that Curator's Lua has.
const luaGlobals = [
  'assert', 'error', 'getmetatable', 'ipairs', 'next', 'pairs', 'pcall', 'print', 'rawequal', 'rawget', 'rawlen', 'rawset', 'require', //
  'select', 'setmetatable', 'tonumber', 'tostring', 'type',
];
const luaLibraries = {
  'string': ['byte', 'char', 'find', 'format', 'gmatch', 'gsub', 'len', 'lower', 'match', 'rep', 'reverse', 'sub', 'upper'],
  'table': ['concat', 'insert', 'remove', 'sort', 'unpack'],
  'math': ['abs', 'ceil', 'floor', 'fmod', 'huge', 'max', 'min', 'pi', 'random', 'round', 'sqrt', 'tointeger'],
  'utf8': ['char', 'codepoint', 'len'],
  'os': ['clock', 'date', 'time'],
};

final _builtIns = {...luaGlobals, ...luaLibraries.keys, for (final l in ExtensionApi.libraries) l.name};

bool _isWordStart(int c) => (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F;
bool _isWord(int c) => _isWordStart(c) || (c >= 0x30 && c <= 0x39);

/// [line] of Lua in runs, each with what it is (null: nothing to colour), read from [state]
/// (where the line above left off: 0 in code, else inside a long string or a long comment), and
/// where it leaves off. A run is a `comment`, a `string`, a `keyword`, a `literal` (nil, true,
/// false), a `number`, a `built_in` (a library or a function Lua always has: `score`, `ipairs`),
/// or a `title` (the name of a function being defined).
({List<(String?, String)> runs, int state}) luaTokens(String line, {int state = 0}) {
  final runs = <(String?, String)>[];
  var i = 0, plain = 0;
  final n = line.length;
  void add(String? scope, int from, int to) {
    if (to <= from) return;
    if (runs.isNotEmpty && runs.last.$1 == scope) {
      runs[runs.length - 1] = (scope, runs.last.$2 + line.substring(from, to));
    } else {
      runs.add((scope, line.substring(from, to)));
    }
  }

  void flush(int to) {
    add(null, plain, to);
    plain = to;
  }

  /// Reads on to the long bracket's end (`]==]` of [level]); the state past it.
  int long(int from, int level, bool comment) {
    final close = ']${'=' * level}]';
    final end = line.indexOf(close, i);
    final to = end < 0 ? n : end + close.length;
    add(comment ? 'comment' : 'string', from, to);
    i = plain = to;
    return end < 0 ? (comment ? 2 : 1) + 2 * level : 0;
  }

  /// A long bracket opening at [at] (`[[`, `[=[`): how many `=` it has; -1: none opens there.
  int opens(int at) {
    if (at >= n || line.codeUnitAt(at) != 0x5B) return -1;
    var k = at + 1;
    while (k < n && line.codeUnitAt(k) == 0x3D) {
      k++;
    }
    return k < n && line.codeUnitAt(k) == 0x5B ? k - at - 1 : -1;
  }

  if (state != 0) state = long(0, (state - 1) ~/ 2, state.isEven);
  var afterFunction = false;
  while (i < n && state == 0) {
    final c = line.codeUnitAt(i);
    if (c == 0x2D && i + 1 < n && line.codeUnitAt(i + 1) == 0x2D) {
      flush(i);
      final level = opens(i + 2);
      if (level < 0) {
        add('comment', i, n);
        i = plain = n;
      } else {
        final from = i;
        i += 4 + level;
        state = long(from, level, true);
      }
    } else if (c == 0x22 || c == 0x27) {
      flush(i);
      var k = i + 1;
      while (k < n && line.codeUnitAt(k) != c) {
        k += line.codeUnitAt(k) == 0x5C ? 2 : 1;
      }
      k = k < n ? k + 1 : n;
      add('string', i, k);
      i = plain = k;
    } else if (c == 0x5B && opens(i) >= 0) {
      flush(i);
      final level = opens(i), from = i;
      i += 2 + level;
      state = long(from, level, false);
    } else if (_isWordStart(c)) {
      var k = i + 1;
      while (k < n && _isWord(line.codeUnitAt(k))) {
        k++;
      }
      final word = line.substring(i, k);
      final field = i > 0 && line.codeUnitAt(i - 1) == 0x2E;
      final scope = field
          ? (afterFunction ? 'title' : null)
          : _keywords.contains(word)
              ? 'keyword'
              : _literals.contains(word)
                  ? 'literal'
                  : afterFunction
                      ? (k < n && (line.codeUnitAt(k) == 0x2E || line.codeUnitAt(k) == 0x3A) ? null : 'title')
                      : _builtIns.contains(word)
                          ? 'built_in'
                          : null;
      if (scope != null) {
        flush(i);
        add(scope, i, k);
        plain = k;
      }
      if (word == 'function') {
        afterFunction = true;
      } else if (!(afterFunction && k < n && (line.codeUnitAt(k) == 0x2E || line.codeUnitAt(k) == 0x3A))) {
        afterFunction = false;
      }
      i = k;
    } else if ((c >= 0x30 && c <= 0x39) || (c == 0x2E && i + 1 < n && line.codeUnitAt(i + 1) >= 0x30 && line.codeUnitAt(i + 1) <= 0x39)) {
      flush(i);
      var k = i + 1;
      while (k < n) {
        final d = line.codeUnitAt(k);
        final sign = (d == 0x2B || d == 0x2D) && const [0x65, 0x45, 0x70, 0x50].contains(line.codeUnitAt(k - 1));
        if (!(_isWord(d) || d == 0x2E || sign)) break;
        k++;
      }
      add('number', i, k);
      i = plain = k;
    } else {
      if (c != 0x20 && c != 0x09 && c != 0x2E && c != 0x3A) afterFunction = false;
      i++;
    }
  }
  flush(n);
  return (runs: runs, state: state);
}

/// Where each line of a Lua text starts (the state [luaTokens] reads it from), [lines] the text
/// as it is now: read down as far as a line is asked for and kept, and read again from the first
/// line that changed since. A folded line is read with what is folded under it.
class LuaStates {
  LuaStates(this.lines);
  final CodeLines Function() lines;

  CodeLines? _text;
  final _read = <CodeLine>[];
  final _starts = [0];

  /// Where line [index] starts (where the last one ends, past the end).
  int at(int index) {
    final text = lines();
    if (!identical(text, _text)) {
      _text = text;
      final changed = _firstChanged(text);
      _read.length = changed;
      _starts.length = changed + 1;
    }
    if (index < _starts.length) return _starts[index];
    var i = 0;
    for (final segment in text.segments) {
      if (i + segment.length > _read.length) {
        for (var k = _read.length - i; k < segment.length && _starts.length <= index; k++) {
          _starts.add(_past(segment[k], _starts.last));
          _read.add(segment[k]);
        }
        if (_starts.length > index) break;
      }
      i += segment.length;
    }
    return _starts[index < _starts.length ? index : _starts.length - 1];
  }

  int _firstChanged(CodeLines text) {
    var i = 0;
    for (final segment in text.segments) {
      for (final line in segment.codeLines) {
        if (i == _read.length) return i;
        if (!identical(line, _read[i]) && line != _read[i]) return i;
        i++;
      }
    }
    return i;
  }

  static int _past(CodeLine line, int state) {
    state = luaTokens(line.text, state: state).state;
    for (final chunk in line.chunks) {
      state = _past(chunk, state);
    }
    return state;
  }
}

/// What a word offered is (shown beside it).
enum LuaKind { keyword, function, library, value, local }

/// A word offered as Lua is typed, with what it is; [function]: the API's function it names.
class LuaPrompt extends CodePrompt {
  const LuaPrompt(String word, this.kind, {this.function}) : super(word: word);
  final LuaKind kind;
  final ApiFunction? function;

  @override
  CodeAutocompleteResult get autocomplete => CodeAutocompleteResult.fromWord(word);

  @override
  bool match(String input) => word != input && word.startsWith(input);

  @override
  bool operator ==(Object other) => other is LuaPrompt && other.word == word && other.kind == kind;

  @override
  int get hashCode => Object.hash(word, kind);
}

/// What to offer where the caret is in Lua: after a library's dot (`score.`) its functions and
/// values; else, once two letters are typed, Lua's words, the libraries, and the names the file
/// uses ([text], the file as it is). Nothing in a comment or a string.
class LuaPrompts implements CodeAutocompletePromptsBuilder {
  LuaPrompts(this.text);
  final String Function() text;

  static const limit = 40;

  @override
  CodeAutocompleteEditingValue? build(BuildContext context, CodeLine codeLine, CodeLineSelection selection) =>
      promptsFor(codeLine.text.substring(0, selection.extentOffset.clamp(0, codeLine.text.length)));

  /// The members of library [name]: the API's, or Lua's own.
  static List<LuaPrompt> membersOf(String name) => [
        for (final l in ExtensionApi.libraries)
          if (l.name == name) ...[
            for (final f in l.functions) LuaPrompt(f.name.substring(name.length + 1), LuaKind.function, function: f),
            for (final (value, _) in l.values) LuaPrompt(value, LuaKind.value),
          ],
        for (final member in luaLibraries[name] ?? const <String>[])
          if (!ExtensionApi.has('$name.$member')) LuaPrompt(member, member == 'huge' || member == 'pi' ? LuaKind.value : LuaKind.function),
      ];

  static final _names = RegExp(r'[A-Za-z_][A-Za-z0-9_]*');

  CodeAutocompleteEditingValue? promptsFor(String before) {
    final tokens = luaTokens(before);
    if (tokens.state != 0 || (tokens.runs.lastOrNull?.$1 == 'comment') || _inString(tokens.runs, before)) return null;
    CodeAutocompleteEditingValue? offer(String input, Iterable<LuaPrompt> all) {
      final seen = <String>{};
      final prompts = [
        for (final p in all)
          if ((input.isEmpty || p.match(input)) && p.word != input && seen.add(p.word)) p,
      ].take(limit).toList();
      return prompts.isEmpty ? null : CodeAutocompleteEditingValue(input: input, prompts: prompts, index: 0);
    }

    if (RegExp(r'([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_0-9]*)$').firstMatch(before) case final m?) {
      final members = membersOf(m[1]!);
      return members.isEmpty ? null : offer(m[2]!, members);
    }
    if (RegExp(r'(?:^|[^A-Za-z0-9_.:])([A-Za-z_][A-Za-z0-9_]+)$').firstMatch(before) case final m?) {
      final typed = m[1]!;
      final known = {..._keywords, ..._literals, ..._builtIns};
      return offer(typed, [
        for (final l in ExtensionApi.libraries) LuaPrompt(l.name, LuaKind.library),
        for (final name in luaLibraries.keys) LuaPrompt(name, LuaKind.library),
        for (final name in luaGlobals) LuaPrompt(name, LuaKind.function),
        for (final word in [..._keywords, ..._literals]) LuaPrompt(word, LuaKind.keyword),
        for (final m in _names.allMatches(text()))
          if (!known.contains(m[0]) && m[0] != typed) LuaPrompt(m[0]!, LuaKind.local),
      ]);
    }
    return null;
  }

  /// Whether [before] ends inside a quoted string: its last run is one that never closed.
  static bool _inString(List<(String?, String)> runs, String before) {
    final last = runs.lastOrNull;
    if (last == null || last.$1 != 'string') return false;
    final s = last.$2;
    if (s.length < 2 || s.codeUnitAt(s.length - 1) != s.codeUnitAt(0)) return true;
    // Closed, unless its last quote is escaped.
    var slashes = 0;
    for (var i = s.length - 2; i > 0 && s.codeUnitAt(i) == 0x5C; i--) {
      slashes++;
    }
    return slashes.isOdd;
  }
}
