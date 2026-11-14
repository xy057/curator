/// Gettext catalogs (`.pot` / `.po`), the files Crowdin syncs: read into a table keyed by the
/// English ([Translated.tr]'s key, `context\u0004text` for an entry with a `msgctxt`), and written
/// back (tool/l10n.dart). Plain Dart, so the tool and the tests use it too.
library;

import 'dart:convert';

/// One entry: its English ([id]), the context it is used in, its translation ('' untranslated),
/// and where the code uses it (`#:` lines).
class PoEntry {
  PoEntry(this.id, {this.context, this.text = '', this.references = const [], this.fuzzy = false});

  final String id;
  final String? context;
  String text;
  List<String> references;
  bool fuzzy;

  /// The key [Strings] looks it up by.
  String get key => context == null ? id : '$context\u0004$id';
}

/// A catalog: its header's translator comments and fields, and its entries in order.
class PoFile {
  PoFile({this.comments = const [], Map<String, String>? header, List<PoEntry>? entries})
      : header = header ?? {},
        entries = entries ?? [];

  final List<String> comments;
  final Map<String, String> header;
  final List<PoEntry> entries;

  /// Every translated entry by its key; fuzzy ones (a guess, not yet reviewed) are left out.
  Map<String, String> get table => {
        for (final e in entries)
          if (e.text.isNotEmpty && !e.fuzzy) e.key: e.text,
      };

  static PoFile parse(String source) {
    final comments = <String>[];
    final header = <String, String>{};
    final entries = <PoEntry>[];
    String? context, id, text, field;
    var references = <String>[];
    var fuzzy = false;
    var sawEntry = false;
    void flush() {
      if (id != null) {
        if (id!.isEmpty && context == null) {
          for (final line in (text ?? '').split('\n')) {
            final colon = line.indexOf(':');
            if (colon > 0) header[line.substring(0, colon).trim()] = line.substring(colon + 1).trim();
          }
        } else {
          entries.add(PoEntry(id!, context: context, text: text ?? '', references: references, fuzzy: fuzzy));
        }
      }
      context = id = text = field = null;
      references = [];
      fuzzy = false;
    }

    void append(String value) {
      switch (field) {
        case 'msgctxt':
          context = context! + value;
        case 'msgid':
          id = id! + value;
        case 'msgstr':
          text = text! + value;
      }
    }

    for (final raw in source.split('\n')) {
      final line = raw.trimRight();
      if (line.isEmpty) {
        flush();
      } else if (line.startsWith('#')) {
        if (field == 'msgstr') flush();
        if (line.startsWith('#:')) {
          references.addAll(line.substring(2).trim().split(RegExp(r'\s+')));
        } else if (line.startsWith('#,')) {
          fuzzy = line.contains('fuzzy');
        } else if (!sawEntry && (line == '#' || line.startsWith('# '))) {
          comments.add(line == '#' ? '' : line.substring(2));
        }
      } else if (line.startsWith('"')) {
        append(_unquote(line));
      } else {
        final space = line.indexOf(' ');
        if (space < 0) throw FormatException('Unreadable line', line);
        final keyword = line.substring(0, space);
        if (keyword == 'msgctxt' || (keyword == 'msgid' && field == 'msgstr')) flush();
        sawEntry = true;
        final value = _unquote(line.substring(space + 1).trim());
        switch (keyword) {
          case 'msgctxt':
            context = value;
          case 'msgid':
            id = value;
          case 'msgstr':
            text = value;
          default:
            throw FormatException('Unsupported keyword', line); // (plurals are separate entries here)
        }
        field = keyword;
      }
    }
    flush();
    return PoFile(comments: comments, header: header, entries: entries);
  }

  /// As a file: the header, then each entry (long or multi-line text split as gettext does).
  @override
  String toString() {
    final out = StringBuffer();
    for (final c in comments) {
      out.writeln(c.isEmpty ? '#' : '# $c');
    }
    out
      ..writeln('msgid ""')
      ..writeln('msgstr ""');
    header.forEach((k, v) => out.writeln(_quote('$k: $v\n')));
    for (final e in entries) {
      out.writeln();
      if (e.references.isNotEmpty) out.writeln('#: ${e.references.join(' ')}');
      if (e.fuzzy) out.writeln('#, fuzzy');
      if (e.context != null) out.writeln('msgctxt ${_quote(e.context!)}');
      _field(out, 'msgid', e.id);
      _field(out, 'msgstr', e.text);
    }
    return out.toString();
  }
}

/// The texts a Dart [source] translates as literals — `'…'.tr`, `'…'.fill(…)` and
/// `'…'.trIn('context')` — each by its key ([PoEntry.key]).
Iterable<String> translatedLiterals(String source) sync* {
  for (final m in _literal.allMatches(source)) {
    final id = _dartText((m[1] ?? m[2])!);
    final context = m[3] ?? m[4];
    yield context == null ? id : '${_dartText(context)}\u0004$id';
  }
}

/// The texts a bundled extension's file translates (`assets/extensions/<id>/…`): in its Lua, the
/// literals given to `curator.tr("…")` or `tr("…")`; in connect.json, every node's `title`; in
/// extension.json, its `name` and `summary`.
Iterable<String> extensionTexts(String path, String source) sync* {
  if (path.endsWith('.lua')) {
    for (final m in _luaLiteral.allMatches(source)) {
      yield _dartText((m[1] ?? m[2])!);
    }
  } else if (path.endsWith('connect.json') || path.endsWith('extension.json')) {
    for (final m in _jsonText.allMatches(source)) {
      if (jsonDecode(m[1]!) case final String text when text.isNotEmpty) yield text;
    }
  }
}

final _luaLiteral = RegExp(r'\btr\(\s*(?:' '$_quoted' r')');
final _jsonText = RegExp(r'"(?:title|name|summary)"\s*:\s*("(?:[^"\\]|\\.)*")');

/// A quoted Dart string (no interpolation), its text captured: single, then double quotes.
const _quoted = r"""'((?:[^'\\\n]|\\.)*)'|"((?:[^"\\\n]|\\.)*)""" '"';
final _literal = RegExp('(?:$_quoted)' r'\s*\.(?:tr\b|fill\(|trIn\(\s*' '(?:$_quoted)' r'\s*\))');

String _dartText(String s) => s.replaceAllMapped(RegExp(r'\\(u\{?[0-9a-fA-F]+\}?|.)'), (m) {
      final c = m[1]!;
      if (c.startsWith('u') && c.length > 1) return String.fromCharCode(int.parse(c.replaceAll(RegExp('[u{}]'), ''), radix: 16));
      return switch (c) { 'n' => '\n', 't' => '\t', final c => c };
    });

void _field(StringBuffer out, String keyword, String value) {
  if (!value.contains('\n') || value.indexOf('\n') == value.length - 1) {
    out.writeln('$keyword ${_quote(value)}');
    return;
  }
  out.writeln('$keyword ""');
  for (final part in RegExp(r'[^\n]*\n|[^\n]+$').allMatches(value)) {
    out.writeln(_quote(part[0]!));
  }
}

String _quote(String s) =>
    '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n').replaceAll('\t', r'\t')}"';

String _unquote(String s) {
  if (s.length < 2 || !s.startsWith('"') || !s.endsWith('"')) throw FormatException('Not a quoted string', s);
  return s.substring(1, s.length - 1).replaceAllMapped(RegExp(r'\\(.)'), (m) => switch (m[1]!) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        final c => c, // \" and \\
      });
}
