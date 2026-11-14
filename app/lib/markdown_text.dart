// Markdown as a release's description on GitHub has it, drawn in the app's own text: headings,
// lists (task lists too), quotes, code and rules; bold, italic, struck, code and links within a
// line. A line break is a line break, as GitHub shows a description. What this doesn't know (a
// table) shows as it is written; an HTML tag is left out, as GitHub leaves out what it doesn't
// allow.
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import 'app_colors.dart';

enum MdKind { heading, paragraph, item, quote, code, rule }

/// One block of a Markdown text.
@immutable
class MdBlock {
  const MdBlock(this.kind, {this.level = 0, this.marker = '', this.runs = const [], this.code = ''});
  final MdKind kind;

  /// A heading's level (1–6); a list item's depth (0 the outermost).
  final int level;

  /// A list item's bullet or number: `•`, `2.`, `☐`.
  final String marker;

  /// Its text, in runs of one style.
  final List<MdRun> runs;

  /// A code block's text.
  final String code;

  /// Its text without the styles.
  String get text => runs.map((r) => r.text).join();
}

/// A run of text in one style. Each is its own (a link's tap is kept by its run).
class MdRun {
  MdRun(this.text, {this.bold = false, this.italic = false, this.strike = false, this.code = false, this.link});
  final String text;
  final bool bold, italic, strike, code;

  /// Where it leads: an http or https address, never another kind.
  final Uri? link;
}

final _fence = RegExp(r'^\s*(```+|~~~+)');
final _rule = RegExp(r'^ {0,3}([-*_])(?:\s*\1){2,}\s*$');
final _heading = RegExp(r'^ {0,3}(#{1,6})\s+(.*?)(?:\s+#+)?\s*$');
final _item = RegExp(r'^(\s*)([-*+]|\d{1,9}[.)])\s+(\S.*)$');
final _task = RegExp(r'^\[([ xX])\]\s+');
final _quote = RegExp(r'^ {0,3}>\s?(.*)$');

/// [source] as blocks, in order.
List<MdBlock> parseMarkdown(String source) {
  final blocks = <MdBlock>[];
  // The paragraph, list item or quote being read: its lines until a blank one or another block.
  MdKind? open;
  var level = 0, marker = '';
  final lines = <String>[];
  void close() {
    if (open case final kind?) blocks.add(MdBlock(kind, level: level, marker: marker, runs: parseInline(lines.join('\n'))));
    open = null;
    lines.clear();
  }

  void start(MdKind kind, String text, {int depth = 0, String bullet = ''}) {
    close();
    open = kind;
    level = depth;
    marker = bullet;
    lines.add(text);
  }

  final all = source.replaceAll('\r\n', '\n').replaceAll('\t', '    ').split('\n');
  for (var i = 0; i < all.length; i++) {
    final line = all[i];
    if (_fence.firstMatch(line) case final fence?) {
      close();
      final code = <String>[];
      for (i++; i < all.length && !all[i].trimLeft().startsWith(fence[1]!); i++) {
        code.add(all[i]);
      }
      blocks.add(MdBlock(MdKind.code, code: code.join('\n')));
    } else if (line.trim().isEmpty) {
      close();
    } else if (_rule.hasMatch(line)) {
      close();
      blocks.add(const MdBlock(MdKind.rule));
    } else if (_heading.firstMatch(line) case final m?) {
      close();
      blocks.add(MdBlock(MdKind.heading, level: m[1]!.length, runs: parseInline(m[2]!)));
    } else if (_item.firstMatch(line) case final m?) {
      var text = m[3]!, bullet = m[2]!.length == 1 ? '•' : m[2]!.replaceFirst(')', '.');
      if (_task.firstMatch(text) case final task?) {
        bullet = task[1] == ' ' ? '☐' : '☑';
        text = text.substring(task.end);
      }
      start(MdKind.item, text, depth: (m[1]!.length ~/ 2).clamp(0, 4), bullet: bullet);
    } else if (_quote.firstMatch(line) case final m?) {
      if (open == MdKind.quote) {
        lines.add(m[1]!);
      } else {
        start(MdKind.quote, m[1]!);
      }
    } else if (open != null) {
      lines.add(line.trim()); // the block goes on
    } else {
      start(MdKind.paragraph, line.trim());
    }
  }
  close();
  return blocks;
}

final _inline = RegExp(
  r'(?<tick>`+)(?<code>.+?)\k<tick>(?!`)'
  r'|!?\[(?<label>[^\]\n]*)\]\(\s*<?(?<href>[^)\s>]+)>?(?:\s+"[^"\n]*")?\s*\)'
  r'|<(?<auto>https?://[^>\s]+)>'
  r'|(?<url>https?://[^\s<>]+)'
  r'|(?<br><br\s*/?>)'
  r'|(?<tag></?[A-Za-z][A-Za-z0-9-]*(?:\s[^<>\n]*)?/?>)'
  r'|\*\*(?=\S)(?<bold>.+?)(?<=\S)\*\*(?!\*)'
  r'|(?<!\w)__(?=\S)(?<bold2>.+?)(?<=\S)__(?!\w)'
  r'|\*(?=[^\s*])(?<em>.+?)(?<=[^\s*])\*'
  r'|(?<!\w)_(?=[^\s_])(?<em2>.+?)(?<=[^\s_])_(?!\w)'
  r'|~~(?=\S)(?<strike>.+?)(?<=\S)~~'
  r'|\\(?<escaped>[!-/:-@\[-`{-~])',
);

/// A link on GitHub as GitHub writes it: `#12` for a pull request or an issue, `v1.0.0...v1.1.0`
/// for a comparison.
final _github = RegExp(r'^https://github\.com/[^/]+/[^/]+/(?:(?:pull|issues)/(\d+)|compare/([^?#]+))$');

/// [address] as a link: http or https, with somewhere to go; null for anything else.
Uri? _link(String address) {
  final uri = Uri.tryParse(address);
  return uri != null && (uri.scheme == 'https' || uri.scheme == 'http') && uri.host.isNotEmpty ? uri : null;
}

/// One block's [text] as runs, each inside the styles given.
List<MdRun> parseInline(String text, {bool bold = false, bool italic = false, bool strike = false, Uri? link}) {
  final runs = <MdRun>[];
  void add(String text, {bool code = false, Uri? to}) {
    if (text.isNotEmpty) runs.add(MdRun(text, bold: bold, italic: italic, strike: strike, code: code, link: to ?? link));
  }

  var at = 0;
  for (final m in _inline.allMatches(text)) {
    if (m.start < at) continue; // inside an address cut short below
    add(text.substring(at, m.start));
    at = m.end;
    if (m.namedGroup('code') case final code?) {
      add(code.trim().isEmpty ? code : code.trim(), code: true);
    } else if (m.namedGroup('href') case final href?) {
      final label = m.namedGroup('label')!;
      runs.addAll(parseInline(label.isEmpty ? href : label, bold: bold, italic: italic, strike: strike, link: _link(href) ?? link));
    } else if (m.namedGroup('auto') ?? m.namedGroup('url') case final found?) {
      // An address written out ends before the sentence's own punctuation, and before a bracket
      // it didn't open.
      var address = found;
      while (address.isNotEmpty) {
        final last = address[address.length - 1];
        final closes = last == ')' && '('.allMatches(address).length < ')'.allMatches(address).length;
        if (!closes && !'.,;:!?\'"*_~'.contains(last)) break;
        address = address.substring(0, address.length - 1);
      }
      if (m.namedGroup('url') != null) at = m.start + address.length;
      final github = _github.firstMatch(address);
      add(github == null ? address : github[1] != null ? '#${github[1]}' : github[2]!, to: _link(address));
    } else if (m.namedGroup('br') != null) {
      add('\n');
    } else if (m.namedGroup('tag') != null) {
      // left out
    } else if (m.namedGroup('bold') ?? m.namedGroup('bold2') case final inner?) {
      runs.addAll(parseInline(inner, bold: true, italic: italic, strike: strike, link: link));
    } else if (m.namedGroup('em') ?? m.namedGroup('em2') case final inner?) {
      runs.addAll(parseInline(inner, bold: bold, italic: true, strike: strike, link: link));
    } else if (m.namedGroup('strike') case final inner?) {
      runs.addAll(parseInline(inner, bold: bold, italic: italic, strike: true, link: link));
    } else if (m.namedGroup('escaped') case final char?) {
      add(char);
    }
  }
  add(text.substring(at));
  return runs;
}

/// [source], Markdown, as the app's text. A link calls [onLink] when clicked.
class MarkdownText extends StatefulWidget {
  const MarkdownText(this.source, {super.key, this.onLink});
  final String source;
  final void Function(Uri link)? onLink;

  @override
  State<MarkdownText> createState() => _MarkdownTextState();
}

class _MarkdownTextState extends State<MarkdownText> {
  late List<MdBlock> _blocks;

  /// Each link's tap: made as the text is read, let go with it.
  final _taps = <MdRun, TapGestureRecognizer>{};

  @override
  void initState() {
    super.initState();
    _read();
  }

  @override
  void didUpdateWidget(MarkdownText old) {
    super.didUpdateWidget(old);
    if (old.source != widget.source) _read();
  }

  @override
  void dispose() {
    _forget();
    super.dispose();
  }

  void _forget() {
    for (final tap in _taps.values) {
      tap.dispose();
    }
    _taps.clear();
  }

  void _read() {
    _forget();
    _blocks = parseMarkdown(widget.source);
    for (final run in _blocks.expand((b) => b.runs)) {
      if (run.link case final link?) _taps[run] = TapGestureRecognizer()..onTap = () => widget.onLink?.call(link);
    }
  }

  static const _mono = TextStyle(fontFamily: 'Menlo', fontFamilyFallback: ['Consolas', 'monospace'], fontSize: 12);

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = AppStyle.of(context).radius(6);
    final body = TextStyle(fontSize: 13, height: 1.45, color: colors.text);
    final linked = Theme.of(context).brightness == Brightness.dark ? colors.accent : colors.accentStrong;
    final shade = colors.line.withValues(alpha: 0.45);

    Widget text(MdBlock block, TextStyle style) => Text.rich(TextSpan(style: style, children: [
          for (final run in block.runs)
            TextSpan(
              text: run.text,
              recognizer: _taps[run],
              mouseCursor: run.link == null ? null : SystemMouseCursors.click,
              style: TextStyle(
                fontWeight: run.bold ? FontWeight.w600 : null,
                fontStyle: run.italic ? FontStyle.italic : null,
                decoration: run.strike ? TextDecoration.lineThrough : null,
                color: run.link == null ? null : linked,
                fontFamily: run.code ? _mono.fontFamily : null,
                fontFamilyFallback: run.code ? _mono.fontFamilyFallback : null,
                fontSize: run.code ? style.fontSize! - 1 : null,
                backgroundColor: run.code ? shade : null,
              ),
            ),
        ]));

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (i, block) in _blocks.indexed)
        switch (block.kind) {
          MdKind.heading => Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 8, bottom: 6),
              child: text(block, body.copyWith(fontSize: const [17.0, 15.0, 13.5][(block.level - 1).clamp(0, 2)], height: 1.3, fontWeight: FontWeight.w600)),
            ),
          MdKind.paragraph => Padding(padding: const EdgeInsets.only(bottom: 8), child: text(block, body)),
          MdKind.item => Padding(
              // The last of a list is as far from what follows as a paragraph is.
              padding: EdgeInsets.only(left: 18.0 * block.level, bottom: i + 1 < _blocks.length && _blocks[i + 1].kind == MdKind.item ? 3 : 8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 18),
                  child: Padding(padding: const EdgeInsets.only(right: 6), child: Text(block.marker, style: body.copyWith(color: colors.textMuted))),
                ),
                Expanded(child: text(block, body)),
              ]),
            ),
          MdKind.quote => Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.only(left: 10),
              decoration: BoxDecoration(border: Border(left: BorderSide(color: colors.textMuted.withValues(alpha: 0.4), width: 3))),
              child: text(block, body.copyWith(color: colors.textMuted)),
            ),
          MdKind.code => Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              decoration: BoxDecoration(color: shade, borderRadius: radius),
              child: Text(block.code, style: _mono.copyWith(height: 1.45, color: colors.text)),
            ),
          MdKind.rule => Divider(height: 20, color: colors.line),
        },
    ]);
  }
}
