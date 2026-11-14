// Markdown as a release's description has it (markdown_text.dart): its blocks, the styles in a
// line, and which addresses are links.
import 'package:curated_score/markdown_text.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('blocks: headings, lists, quotes, code, rules, paragraphs', () {
    final blocks = parseMarkdown('''
## What's New ##
First line
second line

- one
  still one
  - nested
* [x] done
* [ ] to do
2) second

> quoted
> on

```dart
final a = *b*;
```
---
Last''');
    expect([for (final b in blocks) (b.kind, b.level, b.marker, b.kind == MdKind.code ? b.code : b.text)], [
      (MdKind.heading, 2, '', "What's New"),
      (MdKind.paragraph, 0, '', 'First line\nsecond line'),
      (MdKind.item, 0, '•', 'one\nstill one'),
      (MdKind.item, 1, '•', 'nested'),
      (MdKind.item, 0, '☑', 'done'),
      (MdKind.item, 0, '☐', 'to do'),
      (MdKind.item, 0, '2.', 'second'),
      (MdKind.quote, 0, '', 'quoted\non'),
      (MdKind.code, 0, '', 'final a = *b*;'),
      (MdKind.rule, 0, '', ''),
      (MdKind.paragraph, 0, '', 'Last'),
    ]);
  });

  test('a line: bold, italic, struck, code; a name with underscores is left alone', () {
    String styles(MdRun r) => '${r.bold ? 'b' : ''}${r.italic ? 'i' : ''}${r.strike ? 's' : ''}${r.code ? 'c' : ''}';
    final runs = parseInline(r'**Bold *both*** _it_ ~~gone~~ `a*b*` app_build_number 2 * 3 * 4 \*kept\* <b>tag</b>');
    expect([for (final r in runs) if (styles(r).isNotEmpty) (r.text, styles(r))], [
      ('Bold ', 'b'),
      ('both', 'bi'),
      ('it', 'i'),
      ('gone', 's'),
      ('a*b*', 'c'),
    ]);
    expect(runs.map((r) => r.text).join(), 'Bold both it gone a*b* app_build_number 2 * 3 * 4 *kept* tag');
  });

  test('links: written, bare and GitHub\'s own; nothing but http(s) is one', () {
    final runs = parseInline('[site](https://curator.0x57.cc/) by @x in https://github.com/xy057/curator/pull/12, '
        '**Full Changelog**: https://github.com/xy057/curator/compare/v0.8.0...v0.9.0. (see https://example.com/a_(b)) '
        '[run](file:///Applications/Calculator.app) [js](javascript:alert(1)) <https://example.com/x>');
    expect([for (final r in runs) if (r.link != null) (r.text, '${r.link}')], [
      ('site', 'https://curator.0x57.cc/'),
      ('#12', 'https://github.com/xy057/curator/pull/12'),
      ('v0.8.0...v0.9.0', 'https://github.com/xy057/curator/compare/v0.8.0...v0.9.0'),
      ('https://example.com/a_(b)', 'https://example.com/a_(b)'),
      ('https://example.com/x', 'https://example.com/x'),
    ]);
    final text = runs.map((r) => r.text).join();
    expect(text, contains('#12, Full Changelog: v0.8.0...v0.9.0. (see https://example.com/a_(b)) run '));
  });

  testWidgets('drawn, a link calls back with its address', (tester) async {
    final opened = <Uri>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: MarkdownText('# Title\n\nRead [the notes](https://example.com/notes) now\n\n- item', onLink: opened.add)),
    ));
    expect(find.text('Title'), findsOneWidget);
    expect(find.text('•'), findsOneWidget);
    final paragraph = tester.widget<RichText>(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().contains('the notes')));
    TextSpan? link;
    paragraph.text.visitChildren((span) {
      if (span is TextSpan && span.text == 'the notes') link = span;
      return link == null;
    });
    (link!.recognizer! as TapGestureRecognizer).onTap!();
    expect(opened, [Uri.parse('https://example.com/notes')]);
  });
}
