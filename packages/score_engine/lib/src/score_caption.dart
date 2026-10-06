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

/// Where the caption bar sits: under the staves or above them.
enum CaptionPosition { bottom, top }

/// How a caption shows its time running out: a hairline under (or over) the text that draws in
/// to its middle, a small ring beside it that empties, or not at all.
enum CaptionCountdown { line, ring, none }

/// The caption text's size, points.
enum CaptionSize {
  small(12),
  medium(14),
  large(17);

  const CaptionSize(this.points);
  final double points;
}

/// How captions look. [fontFamily] is a family the renderer can draw; null: the score's text font.
@immutable
class CaptionStyle {
  const CaptionStyle(
      {this.fontFamily, this.position = CaptionPosition.bottom, this.countdown = CaptionCountdown.line, this.size = CaptionSize.medium});
  final String? fontFamily;
  final CaptionPosition position;
  final CaptionCountdown countdown;
  final CaptionSize size;

  @override
  bool operator ==(Object other) =>
      other is CaptionStyle &&
      other.fontFamily == fontFamily &&
      other.position == position &&
      other.countdown == countdown &&
      other.size == size;
  @override
  int get hashCode => Object.hash(fontFamily, position, countdown, size);
}

/// The bar the captions show in, under the staves (or above them): the text, centred, and
/// its countdown ([CaptionStyle.countdown]). A caption glides gently into place as it fades
/// in, and fades out as its time ends.
class CaptionBar {
  CaptionBar(this.fontFamily, [this.style = const CaptionStyle()]);

  /// The family drawn when [style] names none (the score's text font).
  final String fontFamily;
  final CaptionStyle style;

  String get _family => style.fontFamily ?? fontFamily;
  double get fontSize => style.size.points;

  /// Room the staves leave for the bar (on top of the scene's margin), as the text's size.
  double get reserve => 36.0 * fontSize / 14;

  /// How long a caption takes to fade in and out, seconds.
  static const fade = 0.4;

  /// From the frame's edge to the hairline, and from there to the text.
  static const _bottom = 16.0, _gap = 8.0;

  /// Space either side of the text, and the widest it gets.
  static const _side = 24.0, _maxWidth = 560.0;

  final _paragraphs = <(String, double), ui.Paragraph>{};

  ui.Paragraph _paragraph(String text, double width) => _paragraphs.putIfAbsent((text, width), () {
        if (_paragraphs.length > 64) _paragraphs.clear();
        final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
          fontFamily: _family,
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

  /// The text's top-left, with no rise, and the countdown line's y.
  ({double top, double line}) _place(ui.Paragraph p, ui.Size size) => style.position == CaptionPosition.top
      ? (top: _bottom + _gap, line: _bottom)
      : (top: size.height - _bottom - _gap - p.height, line: size.height - _bottom);

  /// Where [text] is drawn in a frame of [size] (for hit tests).
  ui.Rect rectOf(String text, ui.Size size) {
    final p = _paragraph(text, _width(size));
    final (:top, :line) = _place(p, size);
    final w = math.max(p.longestLine, 64.0) + (style.countdown == CaptionCountdown.ring ? 40 : 0);
    return ui.Rect.fromLTRB(size.width / 2 - w / 2, math.min(top, line - 2), size.width / 2 + w / 2, math.max(top + p.height, line + 2));
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
      final (:top, :line) = _place(p, size);
      // It comes in from the frame's edge side: up from below, down from above.
      final rise = (1 - ease(into)) * 4 * (style.position == CaptionPosition.top ? -1 : 1);
      final cx = size.width / 2, at = ui.Offset(cx - p.width / 2, top + rise);
      // The layer (to tint and fade the text) only as big as the text, not the frame: a full
      // frame offscreen each frame is costly at 4K. A little over, for glyphs that overhang.
      canvas.saveLayer((at & ui.Size(p.width, p.height)).inflate(4),
          ui.Paint()
            ..color = ui.Color.fromRGBO(0, 0, 0, opacity)
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
          // A hairline as wide as the text, drawing in to its middle.
          final half = math.max(p.longestLine, 64.0) / 2;
          canvas.drawLine(ui.Offset(cx - half, line), ui.Offset(cx + half, line), stroke..color = track);
          if (remaining > 0) {
            canvas.drawLine(ui.Offset(cx - half * remaining, line), ui.Offset(cx + half * remaining, line), stroke..color = rest);
          }
        case CaptionCountdown.ring:
          // A small ring left of the first line, emptying clockwise from the top.
          final r = fontSize * 0.36, firstLine = p.computeLineMetrics().firstOrNull;
          final centre = ui.Offset(cx - p.longestLine / 2 - r - 10, top + rise + (firstLine?.height ?? p.height) / 2);
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
