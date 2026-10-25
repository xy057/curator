import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'score_motion.dart';
import 'score_typography.dart';
import 'scroll_map.dart';

/// A caption (the Captions extension): [text] shown in a bar under the score while the
/// music from score quarter [start] to [end] sounds, its time running out as it goes.
@immutable
class Caption {
  const Caption(this.start, this.end, this.text);
  final double start, end;
  final String text;

  Caption copyWith({double? start, double? end, String? text}) => Caption(start ?? this.start, end ?? this.end, text ?? this.text);

  @override
  bool operator ==(Object other) => other is Caption && other.start == start && other.end == end && other.text == text;
  @override
  int get hashCode => Object.hash(start, end, text);
  @override
  String toString() => 'Caption($start → $end, "$text")';
}

/// When a caption shows: [caption] (an index into the captions) from [start] to [end]
/// seconds, once for every pass that plays it.
typedef CaptionSpan = ({int caption, double start, double end});

/// [captions] with none overlapping (one shows at a time), in their order: one running into the
/// next by start (the later of two starting together) ends where that one starts, and one left
/// with no length goes.
List<Caption> separateCaptions(List<Caption> captions) {
  final order = [for (var i = 0; i < captions.length; i++) i]..sort((a, b) {
      final by = captions[a].start.compareTo(captions[b].start);
      return by != 0 ? by : a.compareTo(b);
    });
  final ends = [for (final c in captions) c.end];
  for (var k = 0; k + 1 < order.length; k++) {
    final i = order[k];
    ends[i] = math.min(ends[i], captions[order[k + 1]].start);
  }
  return [
    for (final (i, c) in captions.indexed)
      if (ends[i] - c.start > 1e-9) ends[i] == c.end ? c : c.copyWith(end: ends[i]),
  ];
}

/// The free stretch around score quarter [at] among [captions] (leaving out caption [except]):
/// from the end of the one before (or 0) to the start of the one after (or [total]). Null when
/// [at] is inside one (its start included).
({double from, double to})? captionRoom(List<Caption> captions, double at, double total, {int? except}) {
  var from = 0.0, to = total;
  for (final (i, c) in captions.indexed) {
    if (i == except) continue;
    if (at >= c.start - 1e-9 && at < c.end - 1e-9) return null;
    if (c.end <= at + 1e-9) {
      from = math.max(from, c.end);
    } else {
      to = math.min(to, c.start);
    }
  }
  return (from: from, to: to);
}

/// The caption (an index into [captions], other than [except]) that [start]–[end] runs into;
/// null when it runs into none.
int? captionOverlapping(List<Caption> captions, double start, double end, {int? except}) {
  for (final (i, c) in captions.indexed) {
    if (i != except && c.start < end - 1e-9 && c.end > start + 1e-9) return i;
  }
  return null;
}

/// The captions in time: each as often as its music sounds, in order. Captions don't overlap
/// ([separateCaptions]); should two spans meet anyway, the earlier ends where the later starts
/// (of two starting together, the later caption shows).
List<CaptionSpan> captionSpans(List<Caption> captions, ScoreTimeline timeline) {
  final spans = <CaptionSpan>[
    for (final (i, c) in captions.indexed)
      if (c.text.trim().isNotEmpty)
        for (final s in timeline.spans(c.start, c.end)) (caption: i, start: s.startSeconds, end: s.endSeconds),
  ]..sort((a, b) {
      final by = a.start.compareTo(b.start);
      return by != 0 ? by : a.caption.compareTo(b.caption);
    });
  return [
    for (final (i, s) in spans.indexed)
      if (i + 1 < spans.length && spans[i + 1].start < s.end)
        (caption: s.caption, start: s.start, end: math.max(s.start, spans[i + 1].start))
      else
        s,
  ];
}

/// A stretch of a caption's text in one face: [italic] and [bold] as its markup asks.
typedef CaptionRun = ({String text, bool italic, bool bold});

/// [text] as it is drawn: `*italic*` and `**bold**` (`***both***`), as in Markdown. A marker
/// opens before a letter and closes after one, so a lone `*` (or one between spaces, `5 * 3`)
/// is a star; `\*` is one too. One left open is drawn as typed.
List<CaptionRun> captionRuns(String text) {
  // The markers and the text between them, in order.
  final parts = <(String, bool)>[]; // (text, is a marker)
  final plain = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (ch == r'\' && i + 1 < text.length && text[i + 1] == '*') {
      plain.write('*');
      i++;
    } else if (ch == '*') {
      if (plain.isNotEmpty) parts.add((plain.toString(), false));
      plain.clear();
      final double = i + 1 < text.length && text[i + 1] == '*';
      parts.add((double ? '**' : '*', true));
      if (double) i++;
    } else {
      plain.write(ch);
    }
  }
  if (plain.isNotEmpty) parts.add((plain.toString(), false));

  // The letter next to marker [i] past any markers beside it ([step] -1: before it); null at
  // either end of the text.
  String? letter(int i, int step) {
    for (var j = i + step; j >= 0 && j < parts.length; j += step) {
      final (s, marker) = parts[j];
      if (!marker) return step < 0 ? s[s.length - 1] : s[0];
    }
    return null;
  }

  bool solid(String? ch) => ch != null && ch.trim().isNotEmpty;
  // Which markers act: an opener before a letter, its closer after one; one never closed is text.
  final acts = List.filled(parts.length, false);
  final open = <String, int>{};
  for (final (i, (s, marker)) in parts.indexed) {
    if (!marker) continue;
    if (open[s] case final at? when solid(letter(i, -1))) {
      acts[at] = acts[i] = true;
      open.remove(s);
    } else if (solid(letter(i, 1))) {
      open[s] = i;
    }
  }

  final runs = <CaptionRun>[];
  var italic = false, bold = false;
  for (final (i, (s, marker)) in parts.indexed) {
    if (marker && acts[i]) {
      s == '**' ? bold = !bold : italic = !italic;
      continue;
    }
    if (runs.lastOrNull case final last? when last.italic == italic && last.bold == bold) {
      runs[runs.length - 1] = (text: last.text + s, italic: italic, bold: bold);
    } else {
      runs.add((text: s, italic: italic, bold: bold));
    }
  }
  return runs;
}

/// [text] without its markup: what it says.
String captionPlain(String text) => captionRuns(text).map((r) => r.text).join();

/// How a caption shows its time running out: a hairline under the text that draws in
/// to its middle, a small ring beside it that empties, or not at all.
enum CaptionCountdown { line, ring, none }

/// Where a caption's text sits across the frame. Its countdown line draws in to the text's
/// middle when centred, else to the side it is set against.
enum CaptionAlign { left, center, right }

/// The caption text's size, points.
enum CaptionSize {
  small(12),
  medium(14),
  large(17);

  const CaptionSize(this.points);
  final double points;
}

/// How captions look. [fontFamily] is a family the renderer can draw; null: the score's text font.
/// [plate]: a soft backing behind the text, so it reads over staves and images.
@immutable
class CaptionStyle {
  const CaptionStyle(
      {this.fontFamily,
      this.countdown = CaptionCountdown.line,
      this.size = CaptionSize.medium,
      this.align = CaptionAlign.center,
      this.plate = false});
  final String? fontFamily;
  final CaptionCountdown countdown;
  final CaptionSize size;
  final CaptionAlign align;
  final bool plate;

  @override
  bool operator ==(Object other) =>
      other is CaptionStyle &&
      other.fontFamily == fontFamily &&
      other.countdown == countdown &&
      other.size == size &&
      other.align == align &&
      other.plate == plate;
  @override
  int get hashCode => Object.hash(fontFamily, countdown, size, align, plate);
}

/// The bar the captions show in, under the staves: the text, set as [CaptionStyle.align] says
/// with its markup's faces ([captionRuns]), its countdown ([CaptionStyle.countdown]) and, if
/// asked, a plate behind them. A caption glides gently into place as it fades in, and fades
/// out as its time ends.
class CaptionBar {
  CaptionBar(this.fontFamily, [this.style = const CaptionStyle(), this.look = TextKind.captionsHouse]);

  /// The family drawn when [style] names none (the score's text font).
  final String fontFamily;
  final CaptionStyle style;

  /// The text's size (a share of [style]'s), face, letter spacing and opacity (Project
  /// Settings ▸ Typography ▸ Captions).
  final TextLook look;

  String get _family => style.fontFamily ?? fontFamily;
  double get fontSize => style.size.points * look.size;

  /// Room the staves leave for the bar (on top of the scene's margin), as the text's size.
  double get reserve => 36.0 * fontSize / 14;

  /// From the frame's edge to the hairline, and from there to the text.
  static const _bottom = 16.0, _gap = 8.0;

  /// Space either side of the text, and the widest it gets.
  static const _side = 24.0, _maxWidth = 560.0;

  /// The plate's margin around what it backs, and its corners.
  static const _platePad = (x: 12.0, y: 6.0), _plateRadius = 6.0;

  /// The ring's radius, and the room it takes left of the text.
  double get _ringRadius => fontSize * 0.36;
  double get _ringRoom => style.countdown == CaptionCountdown.ring ? 2 * _ringRadius + 10 : 0;

  /// Each text laid out, with its first line's height (where the ring sits).
  final _paragraphs = <(String, double), ({ui.Paragraph p, double firstLine})>{};

  ui.Paragraph _paragraph(String text, double width) => _laidOut(text, width).p;

  ui.TextAlign get _textAlign => switch (style.align) {
        CaptionAlign.left => ui.TextAlign.left,
        CaptionAlign.center => ui.TextAlign.center,
        CaptionAlign.right => ui.TextAlign.right,
      };

  ({ui.Paragraph p, double firstLine}) _laidOut(String text, double width) => _paragraphs.putIfAbsent((text, width), () {
        if (_paragraphs.length > 64) _clear();
        final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
          fontFamily: _family,
          fontSize: fontSize,
          fontStyle: look.face.fontStyle,
          fontWeight: look.face.fontWeight,
          height: 1.3,
          textAlign: _textAlign,
          maxLines: 2,
          ellipsis: '…',
        ))
          ..pushStyle(ui.TextStyle(color: const ui.Color(0xFF000000), letterSpacing: look.spacingAt(fontSize)));
        // Emphasis turns an italic face upright, as in print; bold is bold.
        for (final run in captionRuns(text.trim())) {
          builder
            ..pushStyle(ui.TextStyle(
              fontStyle: run.italic != look.face.isItalic ? ui.FontStyle.italic : ui.FontStyle.normal,
              fontWeight: run.bold || look.face.isBold ? ui.FontWeight.bold : ui.FontWeight.normal,
            ))
            ..addText(run.text)
            ..pop();
        }
        final p = builder.build()..layout(ui.ParagraphConstraints(width: width));
        return (p: p, firstLine: p.computeLineMetrics().firstOrNull?.height ?? p.height);
      });

  void _clear() {
    for (final laid in _paragraphs.values) {
      laid.p.dispose();
    }
    _paragraphs.clear();
  }

  /// Frees the texts laid out; the bar can't be drawn after.
  void dispose() => _clear();

  /// The paragraph's width: set against the left, it starts after the ring.
  double _width(ui.Size size) => math.min(size.width - 2 * _side - (style.align == CaptionAlign.left ? _ringRoom : 0), _maxWidth);

  /// Where [p] goes in a frame of [size], with no rise: the paragraph's left, its text's left
  /// edge and width (its longest line), its top, and the countdown line's y.
  ({double left, double textLeft, double textWidth, double top, double line}) _place(ui.Paragraph p, ui.Size size) {
    final textWidth = p.longestLine;
    final (left, textLeft) = switch (style.align) {
      CaptionAlign.left => (_side + _ringRoom, _side + _ringRoom),
      CaptionAlign.center => (size.width / 2 - p.width / 2, size.width / 2 - textWidth / 2),
      CaptionAlign.right => (size.width - _side - p.width, size.width - _side - textWidth),
    };
    return (
      left: left,
      textLeft: textLeft,
      textWidth: textWidth,
      top: size.height - _bottom - _gap - p.height,
      line: size.height - _bottom,
    );
  }

  /// The countdown line's full stretch under a text at [textLeft], [textWidth] wide: as wide
  /// as the text (64 at least), set against the same side.
  (double, double) _lineSpan(double textLeft, double textWidth) {
    final w = math.max(textWidth, 64.0);
    return switch (style.align) {
      CaptionAlign.left => (textLeft, textLeft + w),
      CaptionAlign.center => (textLeft + textWidth / 2 - w / 2, textLeft + textWidth / 2 + w / 2),
      CaptionAlign.right => (textLeft + textWidth - w, textLeft + textWidth),
    };
  }

  /// What the plate backs, before its margin: the text, its ring and its line.
  ui.Rect _backed(ui.Paragraph p, ui.Size size, double rise) {
    final (:left, :textLeft, :textWidth, :top, :line) = _place(p, size);
    final (a, b) = _lineSpan(textLeft, textWidth);
    final l = math.min(a, textLeft - _ringRoom), r = math.max(b, textLeft + textWidth);
    final bottom = style.countdown == CaptionCountdown.line ? line + 1 : top + rise + p.height;
    return ui.Rect.fromLTRB(l, top + rise, r, bottom);
  }

  ui.Rect _padded(ui.Rect r) => ui.Rect.fromLTRB(r.left - _platePad.x, r.top - _platePad.y, r.right + _platePad.x, r.bottom + _platePad.y);

  /// Where [text] is drawn in a frame of [size] (for hit tests).
  ui.Rect rectOf(String text, ui.Size size) {
    final p = _paragraph(text, _width(size));
    final (:left, :textLeft, :textWidth, :top, :line) = _place(p, size);
    final (a, b) = _lineSpan(textLeft, textWidth);
    final rect = ui.Rect.fromLTRB(
        math.min(a, textLeft - _ringRoom), math.min(top, line - 2), math.max(b, textLeft + textWidth), math.max(top + p.height, line + 2));
    return style.plate ? _padded(rect) : rect;
  }

  /// Draws what shows at [time]: the span under way, if any. It fades in and out over
  /// [ScoreMotion.captionFade], rising [ScoreMotion.captionRise] into place along
  /// [ScoreMotion.captionCurve]. A plate takes [paper]'s colour, a touch of [ink] in it.
  void paint(ui.Canvas canvas, ui.Size size, double time, List<CaptionSpan> spans, List<Caption> captions, ui.Color ink,
      {ScoreMotion motion = ScoreMotion.standard, ui.Color paper = const ui.Color(0xFFFFFFFF)}) {
    final fade = motion.captionFade, curve = motion.captionCurve;
    for (final s in spans) {
      if (time < s.start || time >= s.end) continue;
      final into = fade > 0 ? ((time - s.start) / fade).clamp(0.0, 1.0) : 1.0;
      final left = fade > 0 ? ((s.end - time) / fade).clamp(0.0, 1.0) : 1.0;
      final opacity = curve.inside(math.min(into, left));
      if (opacity <= 0.001) continue;
      final (:p, :firstLine) = _laidOut(captions[s.caption].text, _width(size));
      final (left: x, :textLeft, :textWidth, :top, :line) = _place(p, size);
      // It comes in from the frame's edge: up from below.
      final rise = (1 - curve.at(into)) * motion.captionRise;
      final at = ui.Offset(x, top + rise);

      if (style.plate) {
        // Paper on see-through paper would be nothing: the plate is always solid paper.
        final tone = ui.Color.lerp(paper.withValues(alpha: 1), ink, 0.05)!;
        canvas.drawRRect(ui.RRect.fromRectAndRadius(_padded(_backed(p, size, rise)), const ui.Radius.circular(_plateRadius)),
            ui.Paint()..color = tone.withValues(alpha: 0.92 * opacity));
      }

      // The layer (to tint and fade the text) only as big as the text, not the frame: a full
      // frame offscreen each frame is costly at 4K. A little over, for glyphs that overhang.
      canvas.saveLayer((at & ui.Size(p.width, p.height)).inflate(4),
          ui.Paint()
            ..color = ui.Color.fromRGBO(0, 0, 0, opacity * look.opacity)
            ..colorFilter = ui.ColorFilter.mode(ink, ui.BlendMode.srcIn));
      canvas.drawParagraph(p, at);
      canvas.restore();

      final remaining = ((s.end - time) / (s.end - s.start)).clamp(0.0, 1.0);
      final stroke = ui.Paint()
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 1.25
        ..strokeCap = ui.StrokeCap.round;
      final track = ink.withValues(alpha: 0.12 * opacity), rest = ink.withValues(alpha: 0.5 * opacity);
      switch (style.countdown) {
        case CaptionCountdown.line:
          // A hairline as wide as the text, drawing in to its middle (or its side).
          final (a, b) = _lineSpan(textLeft, textWidth);
          canvas.drawLine(ui.Offset(a, line), ui.Offset(b, line), stroke..color = track);
          if (remaining > 0) {
            final (from, to) = switch (style.align) {
              CaptionAlign.left => (a, a + (b - a) * remaining),
              CaptionAlign.center => ((a + b) / 2 - (b - a) / 2 * remaining, (a + b) / 2 + (b - a) / 2 * remaining),
              CaptionAlign.right => (b - (b - a) * remaining, b),
            };
            canvas.drawLine(ui.Offset(from, line), ui.Offset(to, line), stroke..color = rest);
          }
        case CaptionCountdown.ring:
          // A small ring left of the first line, emptying clockwise from the top.
          final r = _ringRadius;
          final centre = ui.Offset(textLeft - r - 10, top + rise + firstLine / 2);
          canvas.drawCircle(centre, r, stroke..color = track);
          if (remaining > 0) {
            canvas.drawArc(ui.Rect.fromCircle(center: centre, radius: r), -math.pi / 2, 2 * math.pi * remaining, false,
                stroke..color = rest);
          }
        case CaptionCountdown.none:
          break;
      }
    }
  }
}
