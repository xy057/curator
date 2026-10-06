import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

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

/// The captions in time: each as often as its music sounds, in order, a caption cut short
/// where the next one starts (one shows at a time).
List<CaptionSpan> captionSpans(List<Caption> captions, ScoreTimeline timeline) {
  final spans = <CaptionSpan>[
    for (final (i, c) in captions.indexed)
      if (c.text.trim().isNotEmpty)
        for (final s in timeline.spans(c.start, c.end)) (caption: i, start: s.startSeconds, end: s.endSeconds),
  ]..sort((a, b) => a.start.compareTo(b.start));
  return [
    for (final (i, s) in spans.indexed)
      if (i + 1 < spans.length && spans[i + 1].start < s.end)
        (caption: s.caption, start: s.start, end: math.max(s.start, spans[i + 1].start))
      else
        s,
  ];
}

/// The bar the captions show in, under the staves: the text, centred, and under it a hairline
/// that shortens towards its middle as the caption's time runs out. A caption rises gently
/// into place as it fades in, and fades out as its time ends.
class CaptionBar {
  CaptionBar(this.fontFamily);
  final String fontFamily;

  /// Room the staves leave under them for the bar (on top of the scene's margin).
  static const reserve = 36.0;

  /// How long a caption takes to fade in and out, seconds.
  static const fade = 0.4;

  static const fontSize = 14.0;

  /// From the frame's bottom to the hairline, and from there up to the text.
  static const _bottom = 16.0, _gap = 8.0;

  /// Space either side of the text, and the widest it gets.
  static const _side = 24.0, _maxWidth = 560.0;

  final _paragraphs = <(String, double), ui.Paragraph>{};

  ui.Paragraph _paragraph(String text, double width) => _paragraphs.putIfAbsent((text, width), () {
        if (_paragraphs.length > 64) _paragraphs.clear();
        final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
          fontFamily: fontFamily,
          fontSize: fontSize,
          height: 1.3,
          textAlign: ui.TextAlign.center,
          maxLines: 2,
          ellipsis: '…',
        ))
          ..pushStyle(ui.TextStyle(color: const ui.Color(0xFF000000), letterSpacing: 0.15))
          ..addText(text.trim());
        return builder.build()..layout(ui.ParagraphConstraints(width: width));
      });

  double _width(ui.Size size) => math.min(size.width - 2 * _side, _maxWidth);

  /// Where [span]'s text sits in a frame of [size] (for hit tests).
  ui.Rect rectOf(String text, ui.Size size) {
    final p = _paragraph(text, _width(size));
    final line = size.height - _bottom, w = math.max(p.longestLine, 64.0);
    return ui.Rect.fromLTRB(size.width / 2 - w / 2, line - _gap - p.height, size.width / 2 + w / 2, line + 2);
  }

  /// Draws what shows at [time]: the span under way, if any.
  void paint(ui.Canvas canvas, ui.Size size, double time, List<CaptionSpan> spans, List<Caption> captions, ui.Color ink) {
    for (final s in spans) {
      if (time < s.start || time >= s.end) continue;
      double ease(double t) => t * t * (3 - 2 * t);
      final into = ((time - s.start) / fade).clamp(0.0, 1.0), left = ((s.end - time) / fade).clamp(0.0, 1.0);
      final opacity = ease(math.min(into, left));
      if (opacity <= 0.001) continue;
      final p = _paragraph(captions[s.caption].text, _width(size));
      final rise = (1 - ease(into)) * 4;
      final line = size.height - _bottom, cx = size.width / 2;
      canvas.saveLayer(null,
          ui.Paint()
            ..color = ui.Color.fromRGBO(0, 0, 0, opacity)
            ..colorFilter = ui.ColorFilter.mode(ink, ui.BlendMode.srcIn));
      canvas.drawParagraph(p, ui.Offset(cx - p.width / 2, line - _gap - p.height + rise));
      canvas.restore();

      // The countdown: a hairline as wide as the text, drawing in to its middle.
      final half = math.max(p.longestLine, 64.0) / 2, remaining = ((s.end - time) / (s.end - s.start)).clamp(0.0, 1.0);
      final stroke = ui.Paint()
        ..strokeWidth = 1.25
        ..strokeCap = ui.StrokeCap.round;
      canvas.drawLine(ui.Offset(cx - half, line), ui.Offset(cx + half, line),
          stroke..color = ink.withValues(alpha: 0.12 * opacity));
      if (remaining > 0) {
        canvas.drawLine(ui.Offset(cx - half * remaining, line), ui.Offset(cx + half * remaining, line),
            stroke..color = ink.withValues(alpha: 0.5 * opacity));
      }
    }
  }
}
