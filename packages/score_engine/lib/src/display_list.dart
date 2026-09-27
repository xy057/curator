import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'engraving.dart';
import 'native/bindings.dart';

/// One drawable thing from the engraving, in Verovio device units (y down).
sealed class DisplayItem {
  DisplayItem(this.bounds);
  final ui.Rect bounds;
  void paint(ui.Canvas canvas);
}

class ShapeItem extends DisplayItem {
  ShapeItem(this.path, super.bounds, {this.fill, this.stroke});
  final ui.Path path;
  final ui.Paint? fill;
  final ui.Paint? stroke;

  @override
  void paint(ui.Canvas canvas) {
    if (fill != null) canvas.drawPath(path, fill!);
    if (stroke != null) canvas.drawPath(path, stroke!);
  }
}

/// A SMuFL glyph or a run of text, laid out once as a paragraph.
class ParagraphItem extends DisplayItem {
  ParagraphItem(this.paragraph, this.offset, super.bounds, {this.sourceId});
  final ui.Paragraph paragraph;
  final ui.Offset offset;

  /// For editable text: the id of the MusicXML text it shows (see ScoreText).
  final String? sourceId;

  @override
  void paint(ui.Canvas canvas) => canvas.drawParagraph(paragraph, offset);
}

/// A glyph turned about its origin (arpeggio and glissando wiggles stand upright).
class RotatedGlyphItem extends DisplayItem {
  RotatedGlyphItem(this.paragraph, this.origin, this.radians, super.bounds);
  final ui.Paragraph paragraph;
  final ui.Offset origin;
  final double radians;

  @override
  void paint(ui.Canvas canvas) {
    canvas
      ..save()
      ..translate(origin.dx, origin.dy)
      ..rotate(radians)
      ..drawParagraph(paragraph, ui.Offset(0, -paragraph.alphabeticBaseline))
      ..restore();
  }
}

/// Everything drawn for one staff, bucketed by x so a tile only touches nearby items.
class StaffLayer {
  StaffLayer(this.info, this.items, {required double binWidth}) : _binWidth = binWidth {
    final maxX = items.fold<double>(0, (m, i) => math.max(m, i.bounds.right));
    final count = (maxX / binWidth).floor() + 1;
    _bins = List.generate(count, (_) => <int>[]);
    _binTop = List.filled(count, 0);
    _binBottom = List.filled(count, info.height);
    for (var i = 0; i < items.length; i++) {
      final b = items[i].bounds;
      final bin = math.max(0, (b.left / binWidth).floor());
      _bins[bin].add(i);
      _binTop[bin] = math.min(_binTop[bin], b.top - info.top);
      _binBottom[bin] = math.max(_binBottom[bin], b.bottom - info.top);
      _maxItemWidth = math.max(_maxItemWidth, b.width);
    }
  }

  final StaffInfo info;
  final List<DisplayItem> items;
  final double _binWidth;
  late final List<List<int>> _bins;
  late final List<double> _binTop, _binBottom; // ink extent per bin, relative to the top line
  double _maxItemWidth = 0;

  /// Items whose bounds may intersect [left, right].
  Iterable<DisplayItem> itemsIn(double left, double right) sync* {
    if (_bins.isEmpty) return;
    final first = math.max(0, ((left - _maxItemWidth) / _binWidth).floor());
    final last = math.min(_bins.length - 1, (right / _binWidth).floor());
    for (var bin = first; bin <= last; bin++) {
      for (final i in _bins[bin]) {
        final b = items[i].bounds;
        if (b.right >= left && b.left <= right) yield items[i];
      }
    }
  }

  /// How far ink reaches above the top line and below the bottom line anywhere in an x range,
  /// in device units. Used ahead of time by the spacing plan, never per frame.
  ({double above, double below}) maxInk(double left, double right) {
    var above = 0.0, below = 0.0;
    if (_bins.isEmpty) return (above: above, below: below);
    final first = math.max(0, ((left - _maxItemWidth) / _binWidth).floor());
    final last = math.min(_bins.length - 1, (right / _binWidth).floor());
    for (var bin = first; bin <= last; bin++) {
      above = math.max(above, -_binTop[bin]);
      below = math.max(below, _binBottom[bin] - info.height);
    }
    return (above: above, below: below);
  }
}

class RenderStyle {
  const RenderStyle({
    this.paper = const ui.Color(0xFFFFFFFF),
    this.ink = const ui.Color(0xFF14171A),
    this.pointer = const ui.Color(0xFF4DA8F0),
    this.staffSpace = 9,
    this.pointerFraction = 0.3,
    this.pointerWidth = 1.5,
    this.headerWidth = 132,
    this.musicFontFamily = 'packages/score_engine/Bravura',
    this.textFontFamily = 'packages/score_engine/Academico',
    this.labelFontSize = 13,
  });

  final ui.Color paper;
  final ui.Color ink;
  final ui.Color pointer;

  /// Logical pixels per staff space. 8–10 reads like a printed full score.
  final double staffSpace;

  /// Fixed pointer position as a fraction of the frame width.
  final double pointerFraction;
  final double pointerWidth;

  /// Width of the sticky header holding instrument names.
  final double headerWidth;
  final String musicFontFamily;
  final String textFontFamily;
  final double labelFontSize;

  RenderStyle copyWith({double? staffSpace}) => RenderStyle(
        paper: paper,
        ink: ink,
        pointer: pointer,
        staffSpace: staffSpace ?? this.staffSpace,
        pointerFraction: pointerFraction,
        pointerWidth: pointerWidth,
        headerWidth: headerWidth,
        musicFontFamily: musicFontFamily,
        textFontFamily: textFontFamily,
        labelFontSize: labelFontSize,
      );
}

/// The engraving converted to drawable items, one layer per staff.
class ScoreDisplayList {
  ScoreDisplayList._(this.data, this.staves, this.barlines);

  final EngravingData data;
  final List<StaffLayer> staves;

  /// System barlines; each staff draws the slice that crosses its own lines.
  final StaffLayer barlines;

  /// Releases the laid-out text and glyphs (glyphs are shared between items).
  void dispose() {
    final paragraphs = <ui.Paragraph>{
      for (final layer in [...staves, barlines])
        for (final item in layer.items)
          if (item case ParagraphItem(:final paragraph) || RotatedGlyphItem(:final paragraph)) paragraph,
    };
    for (final paragraph in paragraphs) {
      paragraph.dispose();
    }
  }

  /// [withoutKeySignatures]: staff numbers (unpitched percussion) whose key signatures are
  /// dropped: Verovio draws a key change on every staff of the system, percussion included.
  /// [hiddenCommands]: recorded commands to leave out (the opening clefs and keys, which the
  /// frozen zone shows instead).
  static ScoreDisplayList build(EngravingData data, RenderStyle style,
      {Set<int> withoutKeySignatures = const {}, Set<int> hiddenCommands = const {}}) {
    final builder = _ItemBuilder(data, style);
    final byStaff = <int, List<DisplayItem>>{};
    final barlineItems = <DisplayItem>[];
    final barLineClass = data.classNames.indexOf('barLine');
    final keyClasses = {
      for (final (i, name) in data.classNames.indexed)
        if (name == 'keySig' || name == 'keyAccid') i,
    };
    for (var i = 0; i < data.commandCount; i++) {
      if (hiddenCommands.contains(i)) continue;
      final staff = data.commandInts[i * Cmd.words + Cmd.staff];
      final isBarline = data.commandInts[i * Cmd.words + Cmd.classIndex] == barLineClass;
      if (staff == 0 && !isBarline) continue; // brackets, system labels: the header replaces them
      if (withoutKeySignatures.contains(staff) && keyClasses.contains(data.commandInts[i * Cmd.words + Cmd.classIndex])) {
        continue;
      }
      final item = builder.item(i);
      if (item == null) continue;
      (staff == 0 ? barlineItems : byStaff.putIfAbsent(staff, () => [])).add(item);
    }
    final binWidth = data.staffSpace * 16;
    return ScoreDisplayList._(
      data,
      [for (final info in data.staves) StaffLayer(info, byStaff[info.n] ?? [], binWidth: binWidth)],
      StaffLayer(const StaffInfo(n: 0, top: 0, height: 0, lines: 0), barlineItems, binWidth: binWidth),
    );
  }
}

class _ItemBuilder {
  _ItemBuilder(this.d, this.style);
  final EngravingData d;
  final RenderStyle style;
  final _glyphs = <(int, double), ui.Paragraph>{};

  DisplayItem? item(int index) {
    final base = index * Cmd.words;
    return switch (d.commandInts[base + Cmd.kind]) {
      VBKind.path => _shape(base),
      VBKind.glyph => _glyph(base),
      VBKind.text when d.commandInts[base + Cmd.flags] & VBFlag.newTextBlock != 0 => _textBlock(index),
      _ => null, // text runs continuing a block are merged into it
    };
  }

  DisplayItem _shape(int base) {
    final ints = d.commandInts, floats = d.commandFloats;
    final path = ui.Path();
    final start = ints[base + Cmd.start], count = ints[base + Cmd.count];
    for (var e = start; e < start + count; e++) {
      final p = e * 7 + 1;
      final f = d.pathFloats;
      switch (d.pathInts[e * 7]) {
        case VBPathOp.move:
          path.moveTo(f[p], f[p + 1]);
        case VBPathOp.line:
          path.lineTo(f[p], f[p + 1]);
        case VBPathOp.quad:
          path.quadraticBezierTo(f[p], f[p + 1], f[p + 2], f[p + 3]);
        case VBPathOp.cubic:
          path.cubicTo(f[p], f[p + 1], f[p + 2], f[p + 3], f[p + 4], f[p + 5]);
        case VBPathOp.close:
          path.close();
        case VBPathOp.ellipse:
          path.addOval(ui.Rect.fromLTWH(f[p], f[p + 1], f[p + 2], f[p + 3]));
      }
    }
    final flags = ints[base + Cmd.flags];
    final width = floats[base + Cmd.strokeWidth];
    final dash = floats[base + Cmd.dash], gap = floats[base + Cmd.gap];
    final stroked = flags & VBFlag.stroke != 0 ? (dash > 0 ? _dashed(path, dash, gap) : path) : null;
    final shapePath = stroked != null && flags & VBFlag.fill == 0 ? stroked : path;
    return ShapeItem(
      shapePath,
      path.getBounds().inflate(width),
      fill: flags & VBFlag.fill != 0 ? (ui.Paint()..color = style.ink) : null,
      stroke: stroked == null
          ? null
          : (ui.Paint()
            ..color = style.ink
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = width
            ..strokeCap = flags & VBFlag.roundCap != 0
                ? ui.StrokeCap.round
                : (flags & VBFlag.squareCap != 0 ? ui.StrokeCap.square : ui.StrokeCap.butt)
            ..strokeJoin = flags & VBFlag.roundJoin != 0
                ? ui.StrokeJoin.round
                : (flags & VBFlag.bevelJoin != 0 ? ui.StrokeJoin.bevel : ui.StrokeJoin.miter)),
    );
  }

  static ui.Path _dashed(ui.Path source, double dash, double gap) {
    final out = ui.Path();
    for (final metric in source.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += dash + gap) {
        out.addPath(metric.extractPath(d, math.min(d + dash, metric.length)), ui.Offset.zero);
      }
    }
    return out;
  }

  DisplayItem _glyph(int base) {
    final floats = d.commandFloats;
    final codepoint = d.commandInts[base + Cmd.codepoint];
    final size = floats[base + Cmd.size].toDouble();
    final paragraph = _glyphs.putIfAbsent((codepoint, size), () {
      final builder = ui.ParagraphBuilder(ui.ParagraphStyle(fontFamily: style.musicFontFamily, fontSize: size))
        ..pushStyle(ui.TextStyle(color: style.ink, fontFamily: style.musicFontFamily, fontSize: size))
        ..addText(String.fromCharCode(codepoint));
      return builder.build()..layout(ui.ParagraphConstraints(width: size * 8));
    });
    final origin = ui.Offset(floats[base + Cmd.x], floats[base + Cmd.y]);
    final b = base + Cmd.bounds;
    final bounds = ui.Rect.fromLTWH(floats[b], floats[b + 1], floats[b + 2], floats[b + 3]);
    final rotation = floats[base + Cmd.rotation];
    if (rotation != 0) return RotatedGlyphItem(paragraph, origin, rotation * math.pi / 180, bounds);
    return ParagraphItem(paragraph, origin.translate(0, -paragraph.alphabeticBaseline), bounds);
  }

  /// Joins consecutive text runs of one positioned block into one paragraph.
  DisplayItem _textBlock(int index) {
    final ints = d.commandInts, floats = d.commandFloats;
    final base = index * Cmd.words;
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(fontFamily: style.textFontFamily));
    var i = index;
    do {
      final b = i * Cmd.words;
      final flags = ints[b + Cmd.flags];
      final start = ints[b + Cmd.start];
      final music = flags & VBFlag.smuflText != 0;
      builder
        ..pushStyle(ui.TextStyle(
          color: style.ink,
          fontFamily: music ? style.musicFontFamily : style.textFontFamily,
          fontSize: floats[b + Cmd.size],
          fontStyle: flags & VBFlag.italic != 0 ? ui.FontStyle.italic : ui.FontStyle.normal,
          fontWeight: flags & VBFlag.bold != 0 ? ui.FontWeight.bold : ui.FontWeight.normal,
        ))
        ..addText(utf8.decode(d.text.sublist(start, start + ints[b + Cmd.count]), allowMalformed: true))
        ..pop();
      i++;
    } while (i < d.commandCount &&
        ints[i * Cmd.words + Cmd.kind] == VBKind.text &&
        ints[i * Cmd.words + Cmd.flags] & VBFlag.newTextBlock == 0);

    final paragraph = builder.build()..layout(const ui.ParagraphConstraints(width: double.maxFinite));
    final width = paragraph.maxIntrinsicWidth;
    var x = floats[base + Cmd.x].toDouble();
    final alignment = ints[base + Cmd.alignment];
    if (alignment == 1) x -= width / 2;
    if (alignment == 2) x -= width;
    final top = floats[base + Cmd.y] - paragraph.alphabeticBaseline;
    final source = ints[base + Cmd.source];
    return ParagraphItem(paragraph, ui.Offset(x, top), ui.Rect.fromLTWH(x, top, width, paragraph.height),
        sourceId: source >= 0 && source < d.sourceIds.length ? d.sourceIds[source] : null);
  }
}
