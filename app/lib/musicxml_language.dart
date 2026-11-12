import 'package:material_ui/material_ui.dart';
import 'package:re_editor/re_editor.dart';

part 'musicxml_schema.dart';

/// MusicXML as the score editor's MusicXML view reads it: its text in a controller that colours
/// each line as it is drawn ([musicXmlCode]: [musicXmlTokens], in [musicXmlTheme]'s colours), its
/// elements folded ([MusicXmlFolds]), what is offered as it is typed ([MusicXmlPrompts], from the
/// MusicXML 4.0 schema: musicxml_schema.dart, which Tools/make_musicxml_schema.py writes) and where
/// a bar is in it ([MusicXmlLines]).
///
/// Not re_highlight, as the LilyPond editor is: it colours the whole text at once, on every change,
/// and copies what is left of the text at every word it colours, so the time grows as the square
/// of the text (a 55,000-line orchestral score: 35 seconds). A line is coloured alone, by what is
/// on it: MusicXML written an element a line has nothing that runs over a line but a comment.

/// A name as XML writes one.
const _name = r'[A-Za-z_][\w.:-]*';

/// A tag: whether it ends an element (1), its name (2), whether it ends itself (3).
final _tag = RegExp('<(/?)($_name)(?:\\s[^<>]*?)?(/?)>');

/// The elements that make a score's shape (its parts, their bars, what a bar holds), coloured
/// apart from the rest.
const _structural = {
  'score-partwise', 'work', 'identification', 'defaults', 'credit', 'part-list', 'score-part', 'part-group', 'part', 'measure',
  'attributes', 'note', 'backup', 'forward', 'direction', 'harmony', 'figured-bass', 'print', 'sound', 'listening', 'barline',
  'grouping', 'link', 'bookmark',
};

/// The MusicXML view's text, [text] to begin with: a controller whose lines are coloured as they
/// are drawn ([musicXmlTokens], in [musicXmlTheme]'s colours for the page's brightness).
CodeLineEditingController musicXmlCode(String text) => CodeLineEditingController(
      codeLines: CodeLines.fromText(text),
      spanBuilder: ({required context, required index, required codeLine, required textSpan, required style}) {
        final theme = _themes[Theme.of(context).brightness] ??= musicXmlTheme(Theme.of(context).brightness);
        return TextSpan(style: style, children: [
          for (final (scope, text) in musicXmlTokens(codeLine.text)) TextSpan(text: text, style: scope == null ? null : theme[scope]),
        ]);
      },
    );

final _themes = <Brightness, Map<String, TextStyle>>{};

/// [line] of MusicXML in runs, each with what it is (null: nothing to colour): `comment`, `meta`
/// (the declaration, a doctype, CDATA), `tag` (its `<`, `</`, `>`, `/>`), `keyword` (the name of an
/// element that makes the score's shape), `name` (another's), `attr`, `string` (a value, quotes
/// and all), `symbol` (an entity), `number` (an element's text that is one). Read alone: a tag
/// begun on the line before is read as text.
List<(String?, String)> musicXmlTokens(String line) {
  final out = <(String?, String)>[];
  void add(String? scope, int from, int to) {
    if (to <= from) return;
    if (out.isNotEmpty && out.last.$1 == scope) {
      out.last = (scope, out.last.$2 + line.substring(from, to));
    } else {
      out.add((scope, line.substring(from, to)));
    }
  }

  int upTo(String end, int from) {
    final at = line.indexOf(end, from);
    return at < 0 ? line.length : at + end.length;
  }

  var i = 0;
  var inTag = false;
  while (i < line.length) {
    final c = line[i];
    if (inTag) {
      if (line.startsWith('/>', i) || c == '>') {
        final to = i + (c == '>' ? 1 : 2);
        add('tag', i, to);
        i = to;
        inTag = false;
      } else if (c == '"' || c == "'") {
        final to = upTo(c, i + 1);
        add('string', i, to);
        i = to;
      } else if (_nameStart.matchAsPrefix(line, i) case final m?) {
        add('attr', i, m.end);
        i = m.end;
      } else {
        add(null, i, i + 1);
        i++;
      }
    } else if (line.startsWith('<!--', i)) {
      final to = upTo('-->', i + 4);
      add('comment', i, to);
      i = to;
    } else if (line.startsWith('<?', i) || line.startsWith('<!', i)) {
      final to = upTo(line.startsWith('<![CDATA[', i) ? ']]>' : line.startsWith('<?', i) ? '?>' : '>', i + 2);
      add('meta', i, to);
      i = to;
    } else if ((c == '<' ? _tagStart.matchAsPrefix(line, i) : null) case final m?) {
      add('tag', i, i + m[1]!.length);
      add(_structural.contains(m[2]) ? 'keyword' : 'name', i + m[1]!.length, m.end);
      i = m.end;
      inTag = true;
    } else if ((c == '&' ? _entity.matchAsPrefix(line, i) : null) case final m?) {
      add('symbol', i, m.end);
      i = m.end;
    } else {
      // Text, to the next tag or entity: a number on its own is one.
      var to = i + 1;
      while (to < line.length && line[to] != '<' && line[to] != '&') {
        to++;
      }
      final text = line.substring(i, to).trim();
      final number = _number.hasMatch(text) && (to == line.length || line.startsWith('</', to)) && (i == 0 || line[i - 1] == '>');
      if (number) {
        final lead = line.indexOf(text, i);
        add(null, i, lead);
        add('number', lead, lead + text.length);
        add(null, lead + text.length, to);
      } else {
        add(null, i, to);
      }
      i = to;
    }
  }
  return out;
}

final _nameStart = RegExp(_name), _tagStart = RegExp('(</?)($_name)');
final _entity = RegExp(r'&(?:[A-Za-z]+|#\d+|#x[0-9A-Fa-f]+);'), _number = RegExp(r'^-?\d+(?:\.\d+)?$');

/// The colours [musicXmlTokens]' kinds are drawn in: on a light page, or a dark one (the
/// LilyPond editor's: a name as a command, an attribute as a context, a value as a string).
Map<String, TextStyle> musicXmlTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  Color c(int light, int night) => Color(dark ? night : light);
  return {
    'comment': TextStyle(color: c(0xFF8A8F98, 0xFF7F848E), fontStyle: FontStyle.italic),
    'meta': TextStyle(color: c(0xFF6B7280, 0xFF8B929C)),
    'tag': TextStyle(color: c(0xFF6B7280, 0xFF8B929C)),
    'name': TextStyle(color: c(0xFF0B61A4, 0xFF61AFEF)),
    'keyword': TextStyle(color: c(0xFFA626A4, 0xFFC678DD), fontWeight: FontWeight.w600),
    'attr': TextStyle(color: c(0xFF0E7C86, 0xFF56B6C2)),
    'string': TextStyle(color: c(0xFF2F7D32, 0xFF98C379)),
    'number': TextStyle(color: c(0xFFB45309, 0xFFD19A66)),
    'symbol': TextStyle(color: c(0xFFC2410C, 0xFFE06C75)),
  };
}

/// The MusicXML view's folds: each element whose start and end tags are on lines of their own
/// (a bar, a note, a part), from its start tag's line to its end tag's.
class MusicXmlFolds implements CodeChunkAnalyzer {
  const MusicXmlFolds();

  @override
  List<CodeChunk> run(CodeLines codeLines) {
    final chunks = <CodeChunk>[];
    final open = <(String, int)>[];
    for (var i = 0; i < codeLines.length; i++) {
      for (final m in _tag.allMatches(codeLines[i].text)) {
        if (m[3] == '/') continue;
        if (m[1] != '/') {
          open.add((m[2]!, i));
          continue;
        }
        // An end tag closes the element of its name nearest (those left open in it with it).
        final k = open.lastIndexWhere((e) => e.$1 == m[2]);
        if (k < 0) continue;
        final start = open[k].$2;
        open.removeRange(k, open.length);
        if (start < i) chunks.add(CodeChunk(start, i));
      }
    }
    return chunks..sort((a, b) => a.index - b.index);
  }
}

/// What a word offered is (shown beside it): an element, the end tag of the one the caret is
/// in, an attribute, a value (an attribute's, an element's text), an entity.
enum MusicXmlKind { element, endTag, attribute, value, entity }

/// A word offered, and what choosing it puts in: [insert] (the word, if null) with the caret
/// [caret] characters into it (its end, if null).
class MusicXmlPrompt extends CodePrompt {
  const MusicXmlPrompt(String word, this.kind, {this.insert, this.caret}) : super(word: word);
  final MusicXmlKind kind;
  final String? insert;
  final int? caret;

  @override
  CodeAutocompleteResult get autocomplete {
    final text = insert ?? word;
    return CodeAutocompleteResult(input: '', word: text, selection: TextSelection.collapsed(offset: caret ?? text.length));
  }

  @override
  bool match(String input) => word != input && word.startsWith(input);

  @override
  bool operator ==(Object other) =>
      other is MusicXmlPrompt && other.word == word && other.kind == kind && other.insert == insert && other.caret == caret;

  @override
  int get hashCode => Object.hash(word, kind, insert, caret);
}

/// What to offer where the caret is in MusicXML, as the schema has it: after `<` the elements
/// the one the caret is in holds (in the schema's order; put in with their end tag, the caret
/// between, or as `<chord/>` when they hold nothing), after `</` the end tag of the one it is
/// in, in a start tag its attributes not written yet (put in as `type=""`, the caret between the
/// quotes), in an attribute's quotes its values, in an element's text its values (`quarter`,
/// `G`, `begin`), after `&` an entity. Nothing in a comment.
class MusicXmlPrompts implements CodeAutocompletePromptsBuilder {
  /// [line]: line i (from 0) of the text as it is now; the lines above the caret's are read
  /// for the element it is in.
  MusicXmlPrompts(this.line);
  final String Function(int i) line;

  /// How many are shown at most.
  static const limit = 40;

  /// How many lines above the caret are read for the element it is in, at most (none found,
  /// every element is offered).
  static const reach = 4000;

  @override
  CodeAutocompleteEditingValue? build(BuildContext context, CodeLine codeLine, CodeLineSelection selection) {
    final at = selection.extentOffset.clamp(0, codeLine.text.length);
    return promptsFor(codeLine.text.substring(0, at), after: codeLine.text.substring(at), above: _above(selection.extentIndex));
  }

  Iterable<String> _above(int index) sync* {
    for (var i = index - 1; i >= 0 && i >= index - reach; i--) {
      yield line(i);
    }
  }

  static final _attribute = '\\s+[\\w:.-]+\\s*=\\s*(?:"[^"]*"|\'[^\']*\')';
  static final _inValue = RegExp('<($_name)(?:$_attribute)*\\s+([\\w:.-]+)\\s*=\\s*"([^"]*)\$');
  static final _inTag = RegExp('<($_name)((?:$_attribute)*)\\s+([\\w:.-]*)\$');
  static final _inText = RegExp('<($_name)(?:$_attribute)*\\s*>([^<>]*)\$');
  static final _endTag = RegExp(r'</([\w.:-]*)$');
  static final _startTag = RegExp(r'<([\w.:-]*)$');
  static final _entity = RegExp(r'&([A-Za-z]*)$');
  static final _attributeName = RegExp(r'([\w:.-]+)\s*=');

  /// Whether what follows the caret goes on with a name, or with the rest of a tag: what is
  /// chosen is then the word alone.
  static final _goesOn = RegExp(r'^(?:[\w.:-]|\s*/?>|\s+[\w:.-]+\s*=)');

  /// What to offer with [before] (the line up to the caret) typed, [after] the rest of the line,
  /// [above] the lines above it (the nearest first): what is being typed and the words it may
  /// become; null for nothing.
  CodeAutocompleteEditingValue? promptsFor(String before, {String after = '', Iterable<String> above = const []}) {
    if (_inComment(before)) return null;
    CodeAutocompleteEditingValue? offer(String input, Iterable<MusicXmlPrompt> all) {
      final seen = <String>{};
      final prompts = [
        for (final p in all)
          if ((input.isEmpty || p.match(input)) && p.word != input && seen.add(p.word)) p,
      ].take(limit).toList();
      return prompts.isEmpty ? null : CodeAutocompleteEditingValue(input: input, prompts: prompts, index: 0);
    }

    final plain = _goesOn.hasMatch(after);
    if (_inValue.firstMatch(before) case final m?) {
      return offer(m[3]!, [for (final v in attributeValues(m[1]!, m[2]!)) MusicXmlPrompt(v, MusicXmlKind.value)]);
    }
    if (_inTag.firstMatch(before) case final m?) {
      final written = {for (final a in _attributeName.allMatches(m[2]!)) a[1]!};
      return offer(m[3]!, [
        for (final a in attributesOf(m[1]!))
          if (!written.contains(a))
            MusicXmlPrompt(a, MusicXmlKind.attribute, insert: plain ? null : '$a=""', caret: plain ? null : a.length + 2),
      ]);
    }
    if (_endTag.firstMatch(before) case final m?) {
      final open = openElement(before, above);
      if (open == null || open.isEmpty) return null;
      return offer(m[1]!, [MusicXmlPrompt(open, MusicXmlKind.endTag, insert: after.startsWith('>') ? null : '$open>')]);
    }
    if (_startTag.firstMatch(before) case final m?) {
      final open = openElement(before.substring(0, m.start), above);
      final names = open == null
          ? const ['score-partwise']
          : _elements.containsKey(open)
              ? childrenOf(open)
              : (_elements.keys.toList()..sort()); // not found, or not MusicXML's
      return offer(m[1]!, [
        for (final name in names)
          MusicXmlPrompt(name, MusicXmlKind.element,
              insert: plain ? null : (isEmpty(name) ? '$name/>' : '$name></$name>'), caret: plain || isEmpty(name) ? null : name.length + 1),
      ]);
    }
    if (_inText.firstMatch(before) case final m? when textValues(m[1]!).isNotEmpty) {
      final values = textValues(m[1]!);
      final close = after.trimLeft().startsWith('<') ? '' : '</${m[1]}>';
      return offer(m[2]!, [for (final v in values) MusicXmlPrompt(v, MusicXmlKind.value, insert: close.isEmpty ? null : '$v$close', caret: v.length)]);
    }
    if (_entity.firstMatch(before) case final m?) {
      return offer(m[1]!, [for (final e in entities) MusicXmlPrompt(e, MusicXmlKind.entity, insert: '$e;')]);
    }
    return null;
  }

  /// Whether the caret is in a comment: one begun before it and not ended.
  static bool _inComment(String before) => before.lastIndexOf('<!--') > before.lastIndexOf('-->');

  /// The element the end of [before] is in, read back through it and [above] (the lines above,
  /// the nearest first): its name; null at the top, outside every element; '' when it isn't
  /// found within the lines given. An element seen whole on the way (a sibling) that has only
  /// one element it can be in answers at once (a `<measure>` is in a `<part>`).
  static String? openElement(String before, Iterable<String> above) {
    var depth = 0;
    String? sibling(String name) {
      final parents = parentsOf(name);
      return parents.length == 1 ? parents.single : null;
    }

    var read = 0;
    for (final text in [before].followedBy(above)) {
      read++;
      final tags = _tag.allMatches(text).toList();
      for (final m in tags.reversed) {
        final name = m[2]!;
        if (m[1] == '/') {
          depth++;
          continue;
        }
        if (depth == 0 && m[3] != '/') return name;
        if (m[3] != '/') depth--;
        // A sibling seen whole.
        if (depth == 0 && sibling(name) != null) return sibling(name);
      }
    }
    // Read to the top: outside every element; or not that far.
    return read - 1 < reach ? null : '';
  }

  /// The entities XML has.
  static const entities = ['amp', 'lt', 'gt', 'quot', 'apos'];

  /// The elements [element] holds, in the schema's order.
  static List<String> childrenOf(String element) => _split(_elements[element]?.$1, ' ');

  /// The attributes [element] has, in the schema's order.
  static List<String> attributesOf(String element) => [for (final a in _split(_elements[element]?.$2, ' ')) a.split('=').first];

  /// The values [element]'s [attribute] takes, if the schema lists them.
  static List<String> attributeValues(String element, String attribute) {
    for (final a in _split(_elements[element]?.$2, ' ')) {
      final [name, ...k] = a.split('=');
      if (name == attribute) return k.isEmpty ? const [] : _split(_values[int.parse(k.single)], '|');
    }
    return const [];
  }

  /// The values [element]'s text takes, if the schema lists them.
  static List<String> textValues(String element) {
    final text = _elements[element]?.$3 ?? '';
    return text.startsWith('=') ? _split(_values[int.parse(text.substring(1))], '|') : const [];
  }

  /// Whether [element] holds nothing (written `<chord/>`).
  static bool isEmpty(String element) => _elements[element]?.$3 == '/';

  /// The elements [element] can be in.
  static List<String> parentsOf(String element) => _parents[element] ?? const [];

  static final Map<String, List<String>> _parents = () {
    final out = <String, List<String>>{};
    for (final MapEntry(key: parent, value: e) in _elements.entries) {
      for (final child in _split(e.$1, ' ')) {
        (out[child] ??= []).add(parent);
      }
    }
    return out;
  }();

  static List<String> _split(String? text, String by) => text == null || text.isEmpty ? const [] : text.split(by);
}

/// Where a part and a bar are in MusicXML written an element a line (as the MusicXML view
/// shows it: `EditableScore.toMusicXMLText`), each line read with [line] (from 0).
abstract final class MusicXmlLines {
  static final _part = RegExp(r'^\s*<part[\s>]'), _partEnd = RegExp(r'^\s*</part>');
  static final _measure = RegExp(r'^\s*<measure[\s>/]'), _measureEnd = RegExp(r'^\s*</measure>');
  static final _id = RegExp(r'''\sid\s*=\s*["']([^"']*)["']'''), _number = RegExp(r'''\snumber\s*=\s*["']([^"']*)["']''');

  /// The bar line [index] is in (or its `<measure>` line): its part's place among the parts
  /// and id, its place among the part's bars (from 0) and the number it is written with; null
  /// outside a bar. With [count] false, the places are not counted (-1): only the part's id and
  /// the bar's number are read, which is quicker.
  static ({int part, String id, int measure, String number})? barAt(String Function(int i) line, int index, {bool count = true}) {
    int? start;
    for (var i = index; i >= 0; i--) {
      final text = line(i);
      if (_measure.hasMatch(text)) {
        start = i;
        break;
      }
      if ((i < index && _measureEnd.hasMatch(text)) || _part.hasMatch(text) || _partEnd.hasMatch(text)) return null;
    }
    if (start == null) return null;
    final number = _number.firstMatch(line(start))?[1] ?? '';
    var measures = 0;
    for (var i = start; i >= 0; i--) {
      final text = line(i);
      if (_part.hasMatch(text)) {
        final id = _id.firstMatch(text)?[1] ?? '';
        if (!count) return (part: -1, id: id, measure: -1, number: number);
        var parts = 0;
        for (var j = i - 1; j >= 0; j--) {
          if (_part.hasMatch(line(j))) parts++;
        }
        return (part: parts, id: id, measure: measures - 1, number: number);
      }
      if (count && _measure.hasMatch(text)) measures++;
    }
    return null;
  }

  /// The line bar [measure] (from 0) of the [part]-th part (from 0) starts on, of [length]
  /// lines; null if it isn't there.
  static int? lineOfBar(String Function(int i) line, int length, int part, int measure) {
    var parts = -1, measures = -1;
    for (var i = 0; i < length; i++) {
      final text = line(i);
      if (_part.hasMatch(text)) {
        if (++parts > part) return null;
        measures = -1;
      } else if (parts == part && _measure.hasMatch(text) && ++measures == measure) {
        return i;
      }
    }
    return null;
  }
}
