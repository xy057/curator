import 'package:material_ui/material_ui.dart';
import 'package:re_editor/re_editor.dart';

/// LilyPond as the LilyPond editor reads it: its text in a controller that colours each line as it
/// is drawn ([lilyPondCode]: [lilyPondTokens], in [lilyPondTheme]'s colours) and what is offered as
/// it is typed ([LilyPondPrompts]).
///
/// Not re_highlight, as it was: that colours the whole text again on every change and copies what
/// is left of it at every word it colours, so its time grows as the square of the text (a .ly of a
/// few hundred KB: seconds behind each keystroke). A line is coloured alone, from where the line
/// above left off: in a block comment, a string, or Scheme some parentheses deep, the only things
/// that run over lines ([LilyPondStates] keeps where each line starts, read again from the first
/// line that changed).

/// The LilyPond editor's text of a file, [text] to begin with: a controller whose lines are
/// coloured as they are drawn ([lilyPondTokens], each from where [LilyPondStates] says it starts,
/// in [lilyPondTheme]'s colours for the page's brightness).
CodeLineEditingController lilyPondCode(String text) {
  late final CodeLineEditingController code;
  final states = LilyPondStates(() => code.codeLines);
  return code = CodeLineEditingController(
    codeLines: CodeLines.fromText(text),
    spanBuilder: ({required context, required index, required codeLine, required textSpan, required style}) {
      final brightness = Theme.of(context).brightness;
      final theme = _themes[brightness] ??= lilyPondTheme(brightness);
      final tokens = lilyPondTokens(codeLine.text, state: states.at(index), after: _after(code.codeLines, index));
      return TextSpan(style: style, children: [
        for (final (scope, text) in tokens.runs) TextSpan(text: text, style: scope == null ? null : theme[scope]),
      ]);
    },
  );
}

final _themes = <Brightness, Map<String, TextStyle>>{};

/// [line] of LilyPond in runs, each with what it is (null: nothing to colour), read from [state]
/// (where the line above left off; 0, LilyPond's own text, at a file's top), and where it leaves
/// off: where the line after it is read from. A run is a `comment`, a `string`, a `keyword` (a
/// command that makes the score's shape: `\new`, `\relative`), a `built_in` (another command), a
/// `variable` being defined, a `title` (a context or grob: `Staff`), a `number` (a duration: `4.`,
/// `3/4`), a `meta` (`|`, `~`), or after `#` or `$` Scheme: a `literal` (`##t`, `#red`, `#'Staff`,
/// `#t` in a list), a `symbol` (`'Staff`), a `keyword` or `built_in` ([_schemeWords]), a `number`,
/// a `string`, a `comment`. [after]: the lines after it, read only to see whether a name alone at
/// its start is defined on the next (`melody` then `= { … }`).
({List<(String?, String)> runs, int state}) lilyPondTokens(String line, {int state = 0, Iterable<String> after = const []}) {
  final scan = _LilyPondLine(line, state, runs: true, after: after)..read();
  return (runs: scan.runs, state: scan.state);
}

/// Where each line of a LilyPond text starts (the state [lilyPondTokens] reads it from), [lines]
/// the text as it is now: read down as far as a line is asked for and kept, and read again from
/// the first line that changed since (one edited, put in, taken out, folded or unfolded). A folded
/// line is read with what is folded under it (re_editor keeps those as its chunks), so folding
/// changes no colour.
class LilyPondStates {
  LilyPondStates(this.lines);
  final CodeLines Function() lines;

  /// The text the lines read were in; each line read, as it was; where each starts, and the
  /// line after the last.
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
    // Read on, from the first line not read to the one asked for.
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

  /// The first line of [text] that isn't the one read there (all of them: how many were read).
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

  /// Where the line after [line] starts, [line] starting at [state]: past it and what is folded
  /// under it.
  static int _past(CodeLine line, int state) {
    state = (_LilyPondLine(line.text, state)..read()).state;
    for (final chunk in line.chunks) {
      state = _past(chunk, state);
    }
    return state;
  }
}

/// The lines after line [index] of [lines], what is folded under it first.
Iterable<String> _after(CodeLines lines, int index) sync* {
  Iterable<String> all(CodeLine line) sync* {
    yield line.text;
    for (final chunk in line.chunks) {
      yield* all(chunk);
    }
  }

  final length = lines.length;
  if (index >= length) return;
  for (final chunk in lines[index].chunks) {
    yield* all(chunk);
  }
  for (var i = index + 1; i < length; i++) {
    yield* all(lines[i]);
  }
}

/// A line of LilyPond read, from where the line above left off: what is in it, each run with
/// what it is when [runs] are asked for, and where it leaves off ([state]). Each place is read as
/// what comes first there, in this order: in LilyPond's own text a block comment (`%{ %}`), a
/// comment, a string, Scheme (`#(`, `$(`), a Scheme string (`#"`), a Scheme value (`##t`, `#'x`,
/// `#:x`, `#-1.5`, `#red`), a command that makes the score's shape, another command, a variable
/// being defined (at the line's start), a context or grob (a capital's word), a duration, a `|`
/// or `~`; in Scheme a list, a string, a comment (`;`), a block comment (`#! !#`), a value (`#t`,
/// `#\x`), a symbol (`'x`), a number, the list's end. Between them, Scheme's words that are
/// [_schemeWords] are coloured as those say.
class _LilyPondLine {
  _LilyPondLine(this.line, int state, {bool runs = false, this.after = const []})
      : depth = state ~/ 3,
        inner = state % 3,
        _starts = runs ? [] : null,
        _scopes = runs ? [] : null;

  final String line;
  final Iterable<String> after;

  /// How many of Scheme's parentheses are open (0: LilyPond's own text), and whether the reading
  /// is in a string or a block comment there ([_string], [_comment]; else [_code]).
  int depth, inner;
  static const _code = 0, _string = 1, _comment = 2;

  /// Where the line leaves off: what [depth] and [inner] are, as one number.
  int get state => depth * 3 + inner;

  /// Each run's start and what it is (null when no runs are asked for); the text from [_pending]
  /// is not in one yet.
  final List<int>? _starts;
  final List<String?>? _scopes;
  var _pending = 0;

  /// The line in runs, each with what it is.
  List<(String?, String)> get runs {
    final starts = _starts!;
    return [
      for (var k = 0; k < starts.length; k++) (_scopes![k], line.substring(starts[k], k + 1 < starts.length ? starts[k + 1] : line.length)),
    ];
  }

  void read() {
    final n = line.length;
    var i = 0;
    while (i < n) {
      if (inner == _string) {
        // To the closing quote, a backslash taking what follows it (a line break too).
        var k = i;
        while (k < n) {
          final c = line.codeUnitAt(k++);
          if (c == _backslash) {
            k++;
          } else if (c == _quote) {
            inner = _code;
            break;
          }
        }
        i = _take(i, k < n ? k : n, 'string');
      } else if (inner == _comment) {
        final end = line.indexOf(depth == 0 ? '%}' : '!#', i);
        if (end >= 0) inner = _code;
        i = _take(i, end < 0 ? n : end + 2, 'comment');
      } else {
        i = depth == 0 ? _lilyPond(i) : _scheme(i);
      }
    }
    if (inner == _code) _flush(n);
  }

  /// What LilyPond's own text has at [i], taken; where the reading goes on.
  int _lilyPond(int i) {
    final n = line.length, c = line.codeUnitAt(i), next = i + 1 < n ? line.codeUnitAt(i + 1) : -1;
    switch (c) {
      case _percent:
        if (next == _braceOpen) return _begin(i, i + 2, 'comment', _comment);
        return _take(i, n, 'comment');
      case _quote:
        return _begin(i, i + 1, 'string', _string);
      case _hash || _dollar when next == _parenOpen:
        // Its words read as Scheme's, `#(` with them.
        _flush(i);
        depth = 1;
        return i + 2;
      case _hash || _dollar when next == _quote:
        return _begin(i, i + 2, 'string', _string);
      case _hash || _dollar:
        final end = _value(i + 1);
        return end < 0 ? i + 1 : _take(i, end, 'literal');
      case _backslash:
        final name = _while(i + 1, _letter);
        if (name > i + 1 && _structuralNames.contains(line.substring(i + 1, name))) return _take(i, name, 'keyword');
        final end = _command(i + 1);
        return end < 0 ? i + 1 : _take(i, end, 'built_in');
      case _bar || _tilde:
        return _take(i, i + 1, 'meta');
    }
    if (i == 0 && _letter(c)) {
      final end = _variable();
      if (end > 0) return _take(0, end, 'variable');
    }
    if (_upper(c) && (i == 0 || !_word(line.codeUnitAt(i - 1)))) {
      final end = _title(i);
      if (end > 0) return _take(i, end, 'title');
    }
    if (_digit(c)) {
      // Digits, a fraction's (3/4), dots.
      var end = _while(i, _digit);
      if (end + 1 < n && line.codeUnitAt(end) == _slash && _digit(line.codeUnitAt(end + 1))) end = _while(end + 1, _digit);
      return _take(i, _while(end, (c) => c == _dot), 'number');
    }
    return i + 1;
  }

  /// What Scheme has at [i], taken; where the reading goes on.
  int _scheme(int i) {
    final c = line.codeUnitAt(i), next = i + 1 < line.length ? line.codeUnitAt(i + 1) : -1;
    switch (c) {
      case _parenOpen:
        _flush(i);
        depth++;
        return i + 1;
      case _quote:
        return _begin(i, i + 1, 'string', _string);
      case _semicolon:
        return _take(i, line.length, 'comment');
      case _hash when next == _bang:
        return _begin(i, i + 2, 'comment', _comment);
      case _hash:
        final end = _schemeValue(i + 1);
        return end < 0 ? i + 1 : _take(i, end, 'literal');
      case _apostrophe:
        final end = _while(i + 1, (c) => !_delimiter(c));
        return end == i + 1 ? i + 1 : _take(i, end, 'symbol');
      case _minus || _plus || (>= _zero && <= _nine):
        final end = _number(i);
        return end < 0 ? i + 1 : _take(i, end, 'number');
      case _parenClose:
        _flush(i + 1);
        depth--;
        return i + 1;
    }
    return i + 1;
  }

  /// After `#` or `$` at [i] - 1, in LilyPond's own text, a value: `##t` or `##f`, `##\x` (a
  /// character), `#'x`, `#:x`, a number, or a name (`#red`); its end, or -1.
  int _value(int i) {
    final n = line.length;
    if (i >= n) return -1;
    final c = line.codeUnitAt(i), next = i + 1 < n ? line.codeUnitAt(i + 1) : -1;
    if (c == _hash) {
      if ((next == _t || next == _f) && (i + 2 >= n || !_word(line.codeUnitAt(i + 2)))) return i + 2;
      if (next == _backslash && i + 2 < n && !_space(line.codeUnitAt(i + 2))) return i + 3;
      return -1;
    }
    if (c == _apostrophe) {
      final end = _while(i + 1, (c) => !_delimiter(c));
      return end > i + 1 ? end : -1;
    }
    if (c == _colon) {
      final end = _while(i + 1, (c) => _word(c) || c == _minus);
      return end > i + 1 ? end : -1;
    }
    if (c == _minus || c == _plus || _digit(c)) {
      final digits = _digit(c) ? i : i + 1, end = _while(digits, _digit);
      if (end == digits) return -1;
      return end + 1 < n && line.codeUnitAt(end) == _dot && _digit(line.codeUnitAt(end + 1)) ? _while(end + 1, _digit) : end;
    }
    return _letter(c) ? _while(i + 1, _nameCharacter) : -1;
  }

  /// After `#` at [i] - 1, in Scheme, a value: `#t`, `#f`, `#true`, `#false` (a word alone), or
  /// a character (`#\x`, `#\space`); its end, or -1.
  int _schemeValue(int i) {
    final n = line.length;
    if (i >= n) return -1;
    bool alone(int end) => end >= n || !_word(line.codeUnitAt(end));
    final c = line.codeUnitAt(i);
    if (c == _t || c == _f) {
      if (alone(i + 1)) return i + 1;
      final word = c == _t ? 'true' : 'false';
      return line.startsWith(word, i) && alone(i + word.length) ? i + word.length : -1;
    }
    if (c != _backslash) return -1;
    final end = _while(i + 1, (c) => !_space(c) && c != _parenOpen && c != _parenClose);
    return end > i + 1 ? end : -1;
  }

  /// A number in Scheme from [i] (a sign, digits, a fraction's or decimals) that no word or `-`
  /// goes on from (a shorter one where one does, if any: `1.5x` is `1`): its end, or -1.
  int _number(int i) {
    final n = line.length;
    final digits = _digit(line.codeUnitAt(i)) ? i : i + 1, whole = _while(digits, _digit);
    if (whole == digits) return -1;
    bool ends(int end) => end >= n || !(_word(line.codeUnitAt(end)) || line.codeUnitAt(end) == _minus);
    int? part(int from, int mark) =>
        from + 1 < n && line.codeUnitAt(from) == mark && _digit(line.codeUnitAt(from + 1)) ? _while(from + 1, _digit) : null;
    final decimals = part(whole, _dot), fraction = part(decimals ?? whole, _slash);
    if (fraction != null) return ends(fraction) ? fraction : decimals ?? whole;
    if (decimals != null) return ends(decimals) ? decimals : whole;
    return ends(whole) ? whole : -1;
  }

  /// A command's name after `\` at [i] - 1 (words joined by `-` or `_`), or one of `!<>()[]~=\`:
  /// its end, or -1.
  int _command(int i) {
    final n = line.length;
    if (i >= n) return -1;
    final c = line.codeUnitAt(i);
    if (!_letter(c)) return _commandMark(c) ? i + 1 : -1;
    var end = _while(i, _letter);
    while (end + 1 < n && (line.codeUnitAt(end) == _minus || line.codeUnitAt(end) == _underscore) && _letter(line.codeUnitAt(end + 1))) {
      end = _while(end + 1, _letter);
    }
    return end;
  }

  /// A name at the line's start being defined: one `=` follows (after spaces, on a line after it
  /// too). Its end, or -1.
  int _variable() {
    final end = _while(1, (c) => _letter(c) || c == _underscore || c == _minus), next = _while(end, _space);
    if (next < line.length) return line.codeUnitAt(next) == _equals ? end : -1;
    for (final text in after) {
      for (final c in text.codeUnits) {
        if (!_space(c)) return c == _equals ? end : -1;
      }
    }
    return -1;
  }

  /// A context's or grob's name from the capital at [i] (letters, then `_` and small letters
  /// any times), a word alone: its end, or -1.
  int _title(int i) {
    final n = line.length;
    var end = _while(i + 1, _letter);
    while (end + 1 < n && line.codeUnitAt(end) == _underscore && _lower(line.codeUnitAt(end + 1))) {
      end = _while(end + 1, _lower);
    }
    return end < n && _word(line.codeUnitAt(end)) ? -1 : end;
  }

  /// Where the characters from [i] that are [what] end.
  int _while(int i, bool Function(int c) what) {
    while (i < line.length && what(line.codeUnitAt(i))) {
      i++;
    }
    return i;
  }

  /// The text from [from] to [to] taken as a run of [scope], what is before it not taken yet
  /// first: where the reading goes on.
  int _take(int from, int to, String scope) {
    _flush(from);
    _add(scope, from, to);
    return _pending = to;
  }

  /// [_take], and the reading [inner] after it.
  int _begin(int from, int to, String scope, int inner) {
    this.inner = inner;
    return _take(from, to, scope);
  }

  /// The text not taken yet, up to [to], taken: in Scheme, its words that are [_schemeWords]
  /// coloured as those say, and the rest not.
  void _flush(int to) {
    final from = _pending;
    _pending = to;
    if (_starts == null || to <= from) return;
    if (depth == 0) return _add(null, from, to);
    var plain = from, i = from;
    while (i < to) {
      if (_delimiter(line.codeUnitAt(i))) {
        i++;
        continue;
      }
      final word = i;
      while (i < to && !_delimiter(line.codeUnitAt(i))) {
        i++;
      }
      if (_schemeWords[line.substring(word, i)] case final scope?) {
        _add(null, plain, word);
        _add(scope, word, i);
        plain = i;
      }
    }
    _add(null, plain, to);
  }

  /// A run of [scope] from [from] to [to], the one before it going on if it is [scope]'s too.
  void _add(String? scope, int from, int to) {
    final starts = _starts, scopes = _scopes;
    if (starts == null || scopes == null || to <= from || (scopes.isNotEmpty && scopes.last == scope)) return;
    starts.add(from);
    scopes.add(scope);
  }
}

/// The colours [lilyPondTokens]' runs are drawn in: on a light page, or a dark one.
Map<String, TextStyle> lilyPondTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  Color c(int light, int night) => Color(dark ? night : light);
  return {
    'comment': TextStyle(color: c(0xFF8A8F98, 0xFF7F848E), fontStyle: FontStyle.italic),
    'string': TextStyle(color: c(0xFF2F7D32, 0xFF98C379)),
    'keyword': TextStyle(color: c(0xFFA626A4, 0xFFC678DD), fontWeight: FontWeight.w600),
    'built_in': TextStyle(color: c(0xFF0B61A4, 0xFF61AFEF)),
    'title': TextStyle(color: c(0xFF0E7C86, 0xFF56B6C2)),
    'number': TextStyle(color: c(0xFFB45309, 0xFFD19A66)),
    'variable': TextStyle(color: c(0xFF7C3AED, 0xFFE5C07B), fontWeight: FontWeight.w600),
    'literal': TextStyle(color: c(0xFFC2410C, 0xFFE06C75)),
    'symbol': TextStyle(color: c(0xFFC2410C, 0xFFE06C75)),
    'meta': TextStyle(color: c(0xFF6B7280, 0xFF8B929C)),
  };
}

/// What is offered as LilyPond is typed: a word to put in, and what it is (a command, a
/// context…), as the list shows it.
/// What a word offered is (shown beside it).
enum LilyPondKind { context, clef, repeat, barline, language, property, grob, variable, command }

class LilyPondPrompt extends CodePrompt {
  const LilyPondPrompt(String word, this.kind) : super(word: word);
  final LilyPondKind kind;

  @override
  CodeAutocompleteResult get autocomplete => CodeAutocompleteResult.fromWord(word);

  @override
  bool match(String input) => word != input && word.startsWith(input);

  @override
  bool operator ==(Object other) => other is LilyPondPrompt && other.word == word && other.kind == kind;

  @override
  int get hashCode => Object.hash(word, kind);
}

/// What to offer where the caret is in LilyPond: after `\new` or `\context` a context, after
/// `\clef` a clef, after `\repeat` a kind of repeat, in `\bar "` a barline, in `\language "` a
/// language, after `\override`, `\revert` or `\tweak` a grob (or a context, then its grob) and
/// after its dot a property, after `\set` or `\unset` a context property; after `\` a command or a
/// variable the score defines ([text], the whole source). Nothing in a comment.
class LilyPondPrompts implements CodeAutocompletePromptsBuilder {
  LilyPondPrompts(this.text);

  /// The source as it is now (its variables are offered after `\`).
  final String Function() text;

  /// How many are shown at most.
  static const limit = 40;

  @override
  CodeAutocompleteEditingValue? build(BuildContext context, CodeLine codeLine, CodeLineSelection selection) =>
      promptsFor(codeLine.text.substring(0, selection.extentOffset.clamp(0, codeLine.text.length)));

  /// What to offer with [before] (the line up to the caret) typed: what is being typed and the
  /// words it may become; null for nothing.
  CodeAutocompleteEditingValue? promptsFor(String before) {
    if (_inComment(before)) return null;
    CodeAutocompleteEditingValue? offer(String input, Iterable<LilyPondPrompt> all) {
      final seen = <String>{};
      final prompts = [
        for (final p in all)
          if ((input.isEmpty || p.match(input)) && p.word != input && seen.add(p.word)) p,
      ].take(limit).toList();
      return prompts.isEmpty ? null : CodeAutocompleteEditingValue(input: input, prompts: prompts, index: 0);
    }

    Iterable<LilyPondPrompt> of(List<String> words, LilyPondKind kind) => words.map((w) => LilyPondPrompt(w, kind));
    if (RegExp(r'\\(?:new|context)\s+([A-Za-z]*)$').firstMatch(before) case final m?) {
      return offer(m[1]!, of(contexts, LilyPondKind.context));
    }
    if (RegExp(r'\\clef\s+"?([A-Za-z0-9_^]*)$').firstMatch(before) case final m?) return offer(m[1]!, of(clefs, LilyPondKind.clef));
    if (RegExp(r'\\repeat\s+([a-z]*)$').firstMatch(before) case final m?) return offer(m[1]!, of(repeats, LilyPondKind.repeat));
    if (RegExp(r'\\bar\s+"([^"\s]*)$').firstMatch(before) case final m?) return offer(m[1]!, of(barlines, LilyPondKind.barline));
    if (RegExp(r'\\language\s+"([a-zçñ]*)$').firstMatch(before) case final m?) return offer(m[1]!, of(languages, LilyPondKind.language));
    // \override Staff.NoteHead.color: after a context a grob, after a grob a property.
    if (RegExp(r'\\(?:override|revert|tweak)\s+((?:[A-Z][A-Za-z]*\.)*)([A-Za-z-]*)$').firstMatch(before) case final m?) {
      final last = m[1]!.split('.').where((s) => s.isNotEmpty).lastOrNull;
      if (last != null && !contexts.contains(last)) return offer(m[2]!, of(grobProperties, LilyPondKind.property));
      return offer(m[2]!, [...of(grobs, LilyPondKind.grob), if (last == null) ...of(contexts, LilyPondKind.context)]);
    }
    if (RegExp(r'\\(?:set|unset)\s+(?:([A-Z][A-Za-z]*)\.)?([A-Za-z]*)$').firstMatch(before) case final m?) {
      return offer(m[2]!, [...of(contextProperties, LilyPondKind.property), if (m[1] == null) ...of(contexts, LilyPondKind.context)]);
    }
    if (RegExp(r'\\([A-Za-z][A-Za-z-]*)$').firstMatch(before) case final m?) {
      return offer(m[1]!, [...of(variables(text()), LilyPondKind.variable), ...of(commands, LilyPondKind.command)]);
    }
    return null;
  }

  /// Whether the caret is in a `%` comment: one outside a string.
  static bool _inComment(String before) {
    var quoted = false;
    for (var i = 0; i < before.length; i++) {
      final c = before[i];
      if (c == '\\' && quoted) {
        i++;
      } else if (c == '"') {
        quoted = !quoted;
      } else if (c == '%' && !quoted) {
        return true;
      }
    }
    return false;
  }

  /// The variables [source] defines (`melody = …` at a line's start), as written.
  static List<String> variables(String source) => [
        for (final m in RegExp(r'^([A-Za-z][A-Za-z_-]*)\s*=', multiLine: true).allMatches(source)) m[1]!,
      ];

  /// LilyPond's commands, the most used first.
  static const commands = [
    ..._structural, 'partial', 'time', 'key', 'clef', 'bar', 'mark', 'textMark', 'sectionLabel', 'tempo', 'major', 'minor', //
    'voiceOne', 'voiceTwo', 'voiceThree', 'voiceFour', 'oneVoice', 'break', 'noBreak', 'pageBreak', 'noPageBreak', 'fine',
    'segnoMark', 'codaMark', 'ottava', 'autoBeamOff', 'autoBeamOn', 'cadenzaOn', 'cadenzaOff', 'fermata', 'staccato', 'accent',
    'tenuto', 'marcato', 'portato', 'staccatissimo', 'espressivo', 'trill', 'turn', 'mordent', 'prall', 'upbow', 'downbow',
    'flageolet', 'open', 'stopped', 'harmonic', 'arpeggio', 'glissando', 'breathe', 'caesura', 'segno', 'coda', 'varcoda',
    'ppppp', 'pppp', 'ppp', 'pp', 'p', 'mp', 'mf', 'f', 'ff', 'fff', 'ffff', 'fffff', 'fp', 'sf', 'sff', 'sfz', 'sfp', 'rfz', 'sp',
    'spp', 'cresc', 'decresc', 'dim', 'endcresc', 'enddecresc', 'enddim', 'crescTextCresc', 'dimTextDim', 'crescHairpin',
    'dimHairpin', 'stemUp', 'stemDown', 'stemNeutral', 'slurUp', 'slurDown', 'slurNeutral', 'slurDashed', 'slurDotted', 'slurSolid',
    'tieUp', 'tieDown', 'tieNeutral', 'dynamicUp', 'dynamicDown', 'dynamicNeutral', 'tupletUp', 'tupletDown', 'tupletNeutral',
    'hideNotes', 'unHideNotes', 'omit', 'hide', 'ionian', 'dorian', 'phrygian', 'lydian', 'mixolydian', 'aeolian', 'locrian',
    'startTrillSpan', 'stopTrillSpan', 'sustainOn', 'sustainOff', 'unaCorda', 'treCorde', 'sostenutoOn', 'sostenutoOff',
    'xNote', 'xNotesOn', 'xNotesOff', 'improvisationOn', 'improvisationOff', 'easyHeadsOn', 'easyHeadsOff', 'numericTimeSignature',
    'defaultTimeSignature', 'compressMMRests', 'compressEmptyMeasures', 'expandEmptyMeasures', 'parallelMusic', 'skip', 'rest',
    'unfoldRepeats', 'articulate', 'shape', 'magnifyMusic', 'scaleDurations', 'harmonicsOn', 'harmonicsOff', 'italianChords',
    'germanChords', 'frenchChords', 'semiGermanChords', 'powerChords', 'chordRepeats', 'textLengthOn', 'textLengthOff',
    'markLengthOn', 'markLengthOff', 'mergeDifferentlyDottedOn', 'mergeDifferentlyHeadedOn', 'shiftOn', 'shiftOff', 'shiftOnn',
    'shiftOnnn', 'balloonText', 'footnote', 'startStaff', 'stopStaff', 'startGroup', 'stopGroup', 'startTextSpan', 'stopTextSpan',
    'repeatTie', 'laissezVibrer', 'bold', 'italic', 'upright', 'medium', 'caps', 'smallCaps', 'normal-text', 'fontsize', 'huge',
    'large', 'normalsize', 'small', 'tiny', 'teeny', 'column', 'line', 'center-column', 'center-align', 'left-align',
    'right-align', 'fill-line', 'wordwrap', 'justify', 'vspace', 'hspace', 'concat', 'char', 'musicglyph', 'note', 'rest',
    'fraction', 'circle', 'box', 'rounded-box', 'with-color', 'with-url', 'underline', 'sharp', 'flat', 'natural',
    'doublesharp', 'doubleflat', 'dynamic', 'finger', 'abs-fontsize', 'magnify', 'raise', 'lower', 'translate', 'rotate',
    'general-align', 'halign', 'path', 'draw-line', 'draw-circle', 'filled-box', 'null', 'epsfile', 'score',
  ];

  /// The contexts a score is made of, the most used first.
  static const contexts = [
    'Staff', 'Voice', 'PianoStaff', 'GrandStaff', 'StaffGroup', 'ChoirStaff', 'Lyrics', 'Score', 'DrumStaff', 'DrumVoice',
    'RhythmicStaff', 'TabStaff', 'TabVoice', 'ChordNames', 'FiguredBass', 'FretBoards', 'Dynamics', 'NoteNames', 'CueVoice',
    'NullVoice', 'OneStaff', 'Timing', 'Devnull', 'MensuralStaff', 'MensuralVoice', 'PetrucciStaff', 'PetrucciVoice',
    'VaticanaStaff', 'VaticanaVoice', 'GregorianTranscriptionStaff', 'GregorianTranscriptionVoice', 'KievanStaff', 'KievanVoice',
  ];

  /// The clefs `\clef` takes.
  static const clefs = [
    'treble', 'bass', 'alto', 'tenor', 'percussion', 'treble_8', 'bass_8', 'treble^8', 'bass^8', 'violin', 'G', 'G2', 'GG',
    'tenorG', 'french', 'soprano', 'mezzosoprano', 'C', 'baritone', 'varbaritone', 'F', 'subbass', 'varC', 'altovarC',
    'tenorvarC', 'baritonevarC', 'varpercussion', 'tab', 'moderntab',
  ];

  /// The kinds of repeat `\repeat` makes.
  static const repeats = ['volta', 'unfold', 'percent', 'tremolo', 'segno'];

  /// The barlines `\bar` draws.
  static const barlines = [
    '|', '||', '|.', '.|', '.|:', ':|.', ':..:', ':|.|:', ':|.:', '[|:', ':|]', ':|][|:', '!', ';', '.', "'", '..', '|.|',
    'k', 'S', 'S-||', 'S-|.', '|.S', 'x-.', '-span|',
  ];

  /// The languages note names are written in (`\language`).
  static const languages = [
    'english', 'nederlands', 'deutsch', 'italiano', 'français', 'francais', 'español', 'espanol', 'português', 'portugues',
    'català', 'catalan', 'suomi', 'svenska', 'norsk', 'vlaams', 'arabic', 'bagpipe', 'persian',
  ];

  /// The grobs (what is drawn) `\override` sets, the most used first.
  static const grobs = [
    'NoteHead', 'Stem', 'Beam', 'Slur', 'Tie', 'Accidental', 'Rest', 'Clef', 'KeySignature', 'TimeSignature', 'BarLine',
    'BarNumber', 'DynamicText', 'Hairpin', 'TextScript', 'Script', 'Fingering', 'StaffSymbol', 'MetronomeMark', 'RehearsalMark',
    'TextMark', 'SectionLabel', 'VerticalAxisGroup', 'SpacingSpanner', 'Glissando', 'TupletBracket', 'TupletNumber', 'LyricText',
    'LyricHyphen', 'LyricExtender', 'ChordName', 'Arpeggio', 'Dots', 'Flag', 'MultiMeasureRest', 'MultiMeasureRestNumber',
    'OttavaBracket', 'TrillSpanner', 'VoltaBracket', 'InstrumentName', 'SystemStartBrace', 'SystemStartBracket', 'SystemStartBar',
    'NoteColumn', 'PaperColumn', 'NonMusicalPaperColumn', 'StemTremolo', 'DynamicLineSpanner', 'DynamicTextSpanner',
    'TextSpanner', 'LedgerLineSpanner', 'Ambitus', 'BreathingSign', 'Footnote', 'Fermata', 'PhrasingSlur', 'SustainPedal',
    'PianoPedalBracket', 'SpanBar', 'StringNumber', 'StrokeFinger', 'TabNoteHead', 'Parentheses', 'VerticalAlignment',
    'StaffGrouper', 'ClefModifier', 'KeyCancellation', 'GraceSpacing', 'NoteSpacing', 'StaffSpacing', 'CombineTextScript',
  ];

  /// The properties a grob has that are set most.
  static const grobProperties = [
    'color', 'font-size', 'stencil', 'transparent', 'X-offset', 'Y-offset', 'extra-offset', 'direction', 'thickness', 'padding',
    'staff-padding', 'length', 'height', 'minimum-length', 'positions', 'details', 'font-shape', 'font-series', 'font-name',
    'style', 'avoid-slur', 'outside-staff-priority', 'outside-staff-padding', 'self-alignment-X', 'self-alignment-Y',
    'break-visibility', 'whiteout', 'layer', 'shorten-pair', 'staff-position', 'text', 'glyph-name', 'bound-details',
    'line-count', 'line-positions', 'staff-space', 'beam-thickness', 'gap', 'dash-period', 'dash-fraction', 'springs-and-rods',
    'base-shortest-duration', 'shortest-duration-space', 'common-shortest-duration', 'minimum-distance', 'X-extent',
    'Y-extent', 'staff-staff-spacing', 'nonstaff-relatedstaff-spacing', 'nonstaff-nonstaff-spacing', 'duration-log',
    'bracket-visibility', 'number-type', 'edge-height', 'neutral-direction', 'rotation', 'parenthesized', 'no-ledgers',
  ];

  /// The context properties `\set` sets most.
  static const contextProperties = [
    'instrumentName', 'shortInstrumentName', 'midiInstrument', 'currentBarNumber', 'tempoHideNote', 'autoBeaming', 'fontSize',
    'explicitKeySignatureVisibility', 'printKeyCancellation', 'keyAlterationOrder', 'barNumberVisibility', 'ottavation',
    'proportionalNotationDuration', 'midiMinimumVolume', 'midiMaximumVolume', 'rehearsalMarkFormatter', 'extraNatural',
    'middleCPosition', 'skipBars', 'timeSignatureFraction', 'measureLength', 'measurePosition', 'baseMoment', 'beatStructure',
    'beamExceptions', 'tupletFullLength', 'tupletSpannerDuration', 'stanza', 'vocalName', 'shortVocalName', 'associatedVoice',
    'includeGraceNotes', 'melismaBusyProperties', 'ignoreMelismata', 'chordChanges', 'majorSevenSymbol', 'chordNameExceptions',
    'pedalSustainStyle', 'stringTunings', 'tablatureFormat', 'drumStyleTable', 'whichBar', 'defaultBarType', 'doubleRepeatBarType',
    'startRepeatBarType', 'endRepeatBarType', 'sectionBarType', 'fineBarType', 'systemStartDelimiter', 'alignAboveContext',
    'alignBelowContext', 'figuredBassAlterationDirection', 'suggestAccidentals', 'aDueText', 'soloText', 'soloIIText',
    'printPartCombineTexts', 'timing', 'connectArpeggios', 'crescendoSpanner', 'decrescendoSpanner', 'harmonicDots',
    'restNumberThreshold', 'countPercentRepeats', 'repeatCountVisibility', 'subdivideBeams', 'clefGlyph', 'clefPosition',
    'clefTransposition', 'markFormatter', 'printTrivialVoltaRepeats', 'voltaSpannerDuration',
  ];
}

/// Commands that make the score's shape (blocks, contexts, modes, music functions on whole
/// passages): highlighted apart from the rest.
const _structural = [
  'score', 'new', 'context', 'with', 'layout', 'midi', 'paper', 'header', 'book', 'bookpart', 'version', 'include', 'language',
  'relative', 'fixed', 'transpose', 'transposition', 'repeat', 'alternative', 'volta', 'tuplet', 'times', 'grace',
  'acciaccatura', 'appoggiatura', 'afterGrace', 'slashedGrace', 'set', 'unset', 'override', 'revert', 'once', 'tweak',
  'temporary', 'undo', 'markup', 'markuplist', 'lyricmode', 'lyricsto', 'addlyrics', 'chordmode', 'chords', 'drummode',
  'drums', 'figuremode', 'figures', 'notemode', 'lyrics', 'default', 'change', 'consists', 'remove', 'accepts', 'denies',
  'alias', 'defaultchild', 'name', 'type', 'description', 'partCombine', 'quoteDuring', 'addQuote', 'cueDuring', 'keepWithTag',
  'removeWithTag', 'tag', 'pushToTag', 'appendToTag', 'void', 'displayMusic', 'displayLilyMusic',
];

/// [_structural], to look a command up in (each a word of letters: `\newStaff` is none of them).
final _structuralNames = _structural.toSet();

/// Scheme's words coloured as what they are: its syntax (`keyword`), and the procedures most
/// used in LilyPond's Scheme (`built_in`).
final _schemeWords = <String, String>{
  for (final word in ('define define* define-public define-music-function define-scheme-function define-void-function '
          'define-event-function define-markup-command lambda lambda* let let* letrec letrec* if cond case and or when unless begin '
          'set! quote quasiquote unquote else do')
      .split(' '))
    word: 'keyword',
  for (final word in ('display newline list cons car cdr cadr null? pair? list? not eq? equal? map for-each append reverse length '
          'string-append number->string string->symbol symbol->string make-music ly:make-moment ly:music-property '
          'ly:grob-property ly:grob-set-property! ly:context-property ly:make-pitch ly:pitch-transpose make-sequential-music '
          'make-simultaneous-music markup? number? string? symbol? procedure? assoc assq ref apply')
      .split(' '))
    word: 'built_in',
};

// The characters LilyPond is read by, as code units.
const _bang = 0x21, _quote = 0x22, _hash = 0x23, _dollar = 0x24, _percent = 0x25, _apostrophe = 0x27, _parenOpen = 0x28,
    _parenClose = 0x29, _star = 0x2A, _plus = 0x2B, _comma = 0x2C, _minus = 0x2D, _dot = 0x2E, _slash = 0x2F, _zero = 0x30,
    _nine = 0x39, _colon = 0x3A, _semicolon = 0x3B, _less = 0x3C, _equals = 0x3D, _greater = 0x3E, _question = 0x3F,
    _bracketOpen = 0x5B, _backslash = 0x5C, _bracketClose = 0x5D, _underscore = 0x5F, _backtick = 0x60, _f = 0x66, _t = 0x74,
    _braceOpen = 0x7B, _bar = 0x7C, _braceClose = 0x7D, _tilde = 0x7E;

bool _digit(int c) => c >= _zero && c <= _nine;
bool _upper(int c) => c >= 0x41 && c <= 0x5A;
bool _lower(int c) => c >= 0x61 && c <= 0x7A;
bool _letter(int c) => _upper(c) || _lower(c);
bool _word(int c) => _letter(c) || _digit(c) || c == _underscore;

/// What a regular expression's `\s` is: a space, a tab, a line break, and Unicode's other spaces.
bool _space(int c) =>
    c == 0x20 || (c >= 0x09 && c <= 0x0D) || c == 0xA0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200A) || c == 0x2028 ||
    c == 0x2029 || c == 0x202F || c == 0x205F || c == 0x3000 || c == 0xFEFF;

/// What ends a word or symbol in Scheme: a space, a bracket, a quote, `;`, `` ` `` or `,`.
bool _delimiter(int c) => switch (c) {
      _parenOpen || _parenClose || _bracketOpen || _bracketClose || _braceOpen || _braceClose || _quote || _apostrophe || //
      _semicolon || _backtick || _comma =>
        true,
      _ => _space(c),
    };

/// What a name after `#` or `$` is made of (`#red`, `#ly:make-moment`, `#markup?`).
bool _nameCharacter(int c) =>
    _word(c) ||
    switch (c) {
      _minus || _colon || _bang || _question || _star || _less || _greater || _equals || _slash || _plus || _dot => true,
      _ => false,
    };

/// What a command can be after `\` but a name: `\!`, `\<`, `\>`, `\(`, `\)`, `\[`, `\]`, `\~`, `\=`, `\\`.
bool _commandMark(int c) => switch (c) {
      _bang || _less || _greater || _parenOpen || _parenClose || _bracketOpen || _bracketClose || _tilde || _equals || _backslash => true,
      _ => false,
    };
