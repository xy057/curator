import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:xml/xml_events.dart';

import 'native/constants.dart';

/// One thing LilyPond drew, in device units (y down): a path, filled and or stroked, or a run of
/// text at its baseline.
sealed class LilyShape {
  const LilyShape();

  /// Where its ink is (a text's, roughly: from its size).
  ui.Rect get bounds;
}

/// A path: its elements as the engraving records them, an op ([VBPathOp]) and six numbers each,
/// in absolute device units.
class LilyPath extends LilyShape {
  LilyPath(this.ops, this.points, {required this.fill, required this.stroke, this.width = 0, this.flags = 0, this.dash = 0, this.gap = 0, this.rect = false});

  final List<int> ops;

  /// Six numbers an op (unused ones 0).
  final List<double> points;
  final bool fill, stroke;

  /// The stroke's width, and its caps and joins ([VBFlag]).
  final double width;
  final int flags;
  final double dash, gap;

  /// Whether it was a rectangle (`<rect>`): a barline's or a stem's, never a glyph's.
  final bool rect;

  @override
  late final ui.Rect bounds = () {
    var l = double.infinity, t = double.infinity, r = -double.infinity, b = -double.infinity;
    for (var i = 0; i < ops.length; i++) {
      final n = switch (ops[i]) { VBPathOp.move || VBPathOp.line => 1, VBPathOp.quad => 2, VBPathOp.cubic => 3, _ => 0 };
      for (var k = 0; k < n; k++) {
        final x = points[i * 6 + k * 2], y = points[i * 6 + k * 2 + 1];
        l = math.min(l, x);
        r = math.max(r, x);
        t = math.min(t, y);
        b = math.max(b, y);
      }
    }
    if (l > r) return ui.Rect.zero;
    final half = stroke ? width / 2 : 0.0;
    return ui.Rect.fromLTRB(l - half, t - half, r + half, b + half);
  }();

  /// A horizontal line from (x0, y) to (x1, y): a staff line.
  bool get isHorizontalLine =>
      ops.length == 2 && ops[0] == VBPathOp.move && ops[1] == VBPathOp.line && points[1] == points[7] && stroke && !fill;
}

/// A run of text, its baseline's start at [x], [y] ([anchor]: 0 there, 1 centred on it, 2 ending
/// there).
class LilyText extends LilyShape {
  LilyText(this.text, this.x, this.y, this.size, {this.italic = false, this.bold = false, this.anchor = 0, this.family = ''});

  final String text;
  final double x, y, size;
  final bool italic, bold;
  final int anchor;
  final String family;

  @override
  ui.Rect get bounds {
    // A guess (the text isn't laid out here): half an em a character, its ascent and descent.
    final width = text.runes.length * size * 0.5;
    final left = x - width * anchor / 2;
    return ui.Rect.fromLTRB(left, y - size * 0.75, left + width, y + size * 0.25);
  }
}

/// What a tagged group of LilyPond's SVG drew: the graphical object (grob) [id] of kind [kind]
/// on line [line] (a staff's or lyrics' context, -1 for the score's or a group's), and where in
/// the source it came from ([file], [sourceLine], [column]; null when it says nothing).
class LilyGroup {
  LilyGroup(this.id, this.kind, this.line);
  final int id;
  final String kind;
  final int line;
  final shapes = <LilyShape>[];
  String? file;
  int? sourceLine, column;

  ui.Rect get bounds => shapes.isEmpty ? ui.Rect.zero : shapes.map((s) => s.bounds).reduce((a, b) => a.expandToInclude(b));
}

/// A 2D affine transform: (x, y) → (a x + c y + e, b x + d y + f).
class _Matrix {
  const _Matrix(this.a, this.b, this.c, this.d, this.e, this.f);
  const _Matrix.scale(double s) : this(s, 0, 0, s, 0, 0);
  final double a, b, c, d, e, f;

  _Matrix times(_Matrix m) => _Matrix(a * m.a + c * m.b, b * m.a + d * m.b, a * m.c + c * m.d, b * m.c + d * m.d,
      a * m.e + c * m.f + e, b * m.e + d * m.f + f);

  double x(double x, double y) => a * x + c * y + e;
  double y(double x, double y) => b * x + d * y + f;

  /// How much it scales a length (the mean of its axes').
  double get scale => (math.sqrt(a * a + b * b) + math.sqrt(c * c + d * d)) / 2;

  /// [attribute] (`translate(1, 2) scale(0.004, -0.004)`…) over this.
  _Matrix apply(String? attribute) {
    if (attribute == null) return this;
    var m = this;
    for (final t in RegExp(r'(\w+)\s*\(([^)]*)\)').allMatches(attribute)) {
      final v = _numbers(t.group(2)!);
      double at(int i, [double or = 0]) => i < v.length ? v[i] : or;
      m = m.times(switch (t.group(1)) {
        'translate' => _Matrix(1, 0, 0, 1, at(0), at(1)),
        'scale' => _Matrix(at(0, 1), 0, 0, v.length > 1 ? v[1] : at(0, 1), 0, 0),
        'rotate' => () {
            final r = at(0) * math.pi / 180, cos = math.cos(r), sin = math.sin(r);
            final rot = _Matrix(cos, sin, -sin, cos, 0, 0);
            if (v.length < 3) return rot;
            return _Matrix(1, 0, 0, 1, v[1], v[2]).times(rot).times(_Matrix(1, 0, 0, 1, -v[1], -v[2]));
          }(),
        'matrix' when v.length == 6 => _Matrix(v[0], v[1], v[2], v[3], v[4], v[5]),
        'skewX' => _Matrix(1, 0, math.tan(at(0) * math.pi / 180), 1, 0, 0),
        'skewY' => _Matrix(1, math.tan(at(0) * math.pi / 180), 0, 1, 0, 0),
        _ => const _Matrix.scale(1),
      });
    }
    return m;
  }
}

/// Every number in [text] (SVG's way: `10-5` is two, `.5.5` too).
List<double> _numbers(String text) {
  final out = <double>[];
  for (final m in RegExp(r'[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?').allMatches(text)) {
    out.add(double.parse(m.group(0)!));
  }
  return out;
}

/// Reads the groups LilyPond tagged in an SVG of Curator's settings (`data-c`, `data-g`,
/// `data-l` on a `<g>`), each with what it drew, in drawing order, scaled by [unit] (device units
/// a staff space: the SVG's are staff spaces).
List<LilyGroup> readLilyPondSvg(String svg, {required double unit}) {
  final groups = <LilyGroup>[];
  final matrices = <_Matrix>[_Matrix.scale(unit)];
  final tagged = <LilyGroup?>[null];
  LilyGroup? group;
  // The text being read (its attributes and matrix), until its end.
  ({Map<String, String> attributes, _Matrix matrix, StringBuffer text})? reading;
  for (final event in parseEvents(svg)) {
    switch (event) {
      case XmlStartElementEvent(:final localName, :final attributes, :final isSelfClosing):
        final a = {for (final x in attributes) x.localName: x.value};
        final matrix = matrices.last.apply(a['transform']);
        if (localName == 'g' && a['data-c'] != null) {
          group = LilyGroup(int.tryParse(a['data-c']!) ?? -1, a['data-g'] ?? '', int.tryParse(a['data-l'] ?? '') ?? -1);
          groups.add(group);
        }
        if (localName == 'a' && group != null && group.sourceLine == null) _link(group, a['href'] ?? '');
        if (group != null) {
          if (_shape(localName, a, matrix) case final shape?) group.shapes.add(shape);
          if (localName == 'text') reading = (attributes: a, matrix: matrix, text: StringBuffer());
        }
        if (!isSelfClosing) {
          matrices.add(matrix);
          tagged.add(group);
        } else if (localName == 'text') {
          reading = null;
        }
      // The text as written (LilyPond's runs keep their spaces: `white-space: pre`), but for the
      // line breaks the file is laid out with.
      case XmlTextEvent(:final value) when reading != null && !(value.contains('\n') && value.trim().isEmpty):
        reading.text.write(value);
      case XmlCDATAEvent(:final value) when reading != null:
        reading.text.write(value);
      case XmlEndElementEvent(:final localName):
        if (localName == 'text' && reading != null) {
          final text = reading.text.toString().replaceAll('\n', ' ');
          if (text.trim().isNotEmpty) group?.shapes.add(_text(text, reading.attributes, reading.matrix));
          reading = null;
        }
        if (matrices.length > 1) {
          matrices.removeLast();
          tagged.removeLast();
          group = tagged.last;
        }
      default:
    }
  }
  return groups;
}

/// A point-and-click link (`textedit:///path/to/file.ly:12:4:5`): the file, its line and the
/// character in it it names.
void _link(LilyGroup group, String href) {
  final m = RegExp(r'^textedit://(.*):(\d+):(\d+):(\d+)$').firstMatch(href);
  if (m == null) return;
  group
    ..file = Uri.decodeComponent(m.group(1)!)
    ..sourceLine = int.parse(m.group(2)!)
    ..column = int.parse(m.group(3)!);
}

LilyText _text(String text, Map<String, String> a, _Matrix m) => LilyText(
      text,
      m.x(0, 0),
      m.y(0, 0),
      (double.tryParse(a['font-size'] ?? '') ?? 2.2) * m.scale,
      italic: a['font-style'] == 'italic' || a['font-style'] == 'oblique',
      bold: a['font-weight'] == 'bold' || (int.tryParse(a['font-weight'] ?? '') ?? 400) >= 600,
      anchor: switch (a['text-anchor']) { 'middle' => 1, 'end' => 2, _ => 0 },
      family: a['font-family'] ?? '',
    );

/// The drawing element [name] with attributes [a] under [m], as a path; null for anything that
/// draws nothing.
LilyPath? _shape(String name, Map<String, String> a, _Matrix m) {
  double n(String key, [double or = 0]) => double.tryParse(a[key] ?? '') ?? or;
  final path = _PathBuilder(m);
  switch (name) {
    case 'path':
      path.data(a['d'] ?? '');
    case 'rect':
      final x = n('x'), y = n('y'), w = n('width'), h = n('height');
      if (w <= 0 || h <= 0) return null;
      final r = math.min(math.min(n('ry', n('rx')), n('rx', n('ry'))), math.min(w, h) / 2);
      path.roundedRect(x, y, w, h, r);
    case 'line':
      path
        ..move(n('x1'), n('y1'))
        ..line(n('x2'), n('y2'));
    case 'polygon' || 'polyline':
      final v = _numbers(a['points'] ?? '');
      for (var i = 0; i + 1 < v.length; i += 2) {
        i == 0 ? path.move(v[i], v[i + 1]) : path.line(v[i], v[i + 1]);
      }
      if (name == 'polygon') path.close();
    case 'circle':
      path.ellipse(n('cx'), n('cy'), n('r'), n('r'));
    case 'ellipse':
      path.ellipse(n('cx'), n('cy'), n('rx'), n('ry'));
    default:
      return null;
  }
  if (path.ops.isEmpty) return null;
  bool paints(String? value) => value != null && value != 'none' && value != 'transparent';
  // SVG fills what has no fill named, but a line, which has no inside.
  final fill = name != 'line' && (a['fill'] == null || paints(a['fill']));
  final stroke = paints(a['stroke']) || (name == 'line' && a['stroke'] == null);
  if (!fill && !stroke) return null;
  final dashes = _numbers(a['stroke-dasharray'] ?? '');
  final scale = m.scale;
  return LilyPath(
    path.ops,
    path.points,
    fill: fill,
    stroke: stroke,
    width: stroke ? n('stroke-width', 1) * scale : 0,
    flags: switch (a['stroke-linecap']) { 'round' => VBFlag.roundCap, 'square' => VBFlag.squareCap, _ => 0 } |
        switch (a['stroke-linejoin']) { 'round' => VBFlag.roundJoin, 'bevel' => VBFlag.bevelJoin, _ => 0 },
    dash: dashes.isNotEmpty && dashes.first > 0 ? dashes.first * scale : 0,
    gap: dashes.length > 1 ? dashes[1] * scale : (dashes.isNotEmpty ? dashes.first * scale : 0),
    rect: name == 'rect',
  );
}

/// Builds a path in absolute device units from SVG's commands under a matrix.
class _PathBuilder {
  _PathBuilder(this.m);
  final _Matrix m;
  final ops = <int>[];
  final points = <double>[];

  void _add(int op, [List<double> p = const []]) {
    ops.add(op);
    for (var i = 0; i < 6; i++) {
      points.add(i < p.length ? p[i] : 0);
    }
  }

  void move(double x, double y) => _add(VBPathOp.move, [m.x(x, y), m.y(x, y)]);
  void line(double x, double y) => _add(VBPathOp.line, [m.x(x, y), m.y(x, y)]);
  void cubic(double x1, double y1, double x2, double y2, double x, double y) =>
      _add(VBPathOp.cubic, [m.x(x1, y1), m.y(x1, y1), m.x(x2, y2), m.y(x2, y2), m.x(x, y), m.y(x, y)]);
  void quad(double x1, double y1, double x, double y) => _add(VBPathOp.quad, [m.x(x1, y1), m.y(x1, y1), m.x(x, y), m.y(x, y)]);
  void close() => _add(VBPathOp.close);

  /// Bézier quarters of an ellipse (exact under any matrix, unlike [VBPathOp.ellipse]).
  void ellipse(double cx, double cy, double rx, double ry) {
    if (rx <= 0 || ry <= 0) return;
    const k = 0.5522847498;
    move(cx + rx, cy);
    cubic(cx + rx, cy + ry * k, cx + rx * k, cy + ry, cx, cy + ry);
    cubic(cx - rx * k, cy + ry, cx - rx, cy + ry * k, cx - rx, cy);
    cubic(cx - rx, cy - ry * k, cx - rx * k, cy - ry, cx, cy - ry);
    cubic(cx + rx * k, cy - ry, cx + rx, cy - ry * k, cx + rx, cy);
    close();
  }

  void roundedRect(double x, double y, double w, double h, double r) {
    if (r <= 0) {
      move(x, y);
      line(x + w, y);
      line(x + w, y + h);
      line(x, y + h);
      close();
      return;
    }
    const k = 0.5522847498;
    move(x + r, y);
    line(x + w - r, y);
    cubic(x + w - r + r * k, y, x + w, y + r - r * k, x + w, y + r);
    line(x + w, y + h - r);
    cubic(x + w, y + h - r + r * k, x + w - r + r * k, y + h, x + w - r, y + h);
    line(x + r, y + h);
    cubic(x + r - r * k, y + h, x, y + h - r + r * k, x, y + h - r);
    line(x, y + r);
    cubic(x, y + r - r * k, x + r - r * k, y, x + r, y);
    close();
  }

  /// SVG path data: every command, absolute and relative (arcs as Béziers).
  void data(String d) {
    final tokens = RegExp(r'[MmLlHhVvCcSsQqTtAaZz]|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?').allMatches(d).map((t) => t.group(0)!).toList();
    var i = 0;
    var x = 0.0, y = 0.0, startX = 0.0, startY = 0.0;
    double? cx2, cy2; // the last cubic's second control point, or a quad's control point
    var lastCommand = '';
    String command = '';
    bool isCommand(String t) => RegExp(r'^[A-Za-z]$').hasMatch(t);
    double next() => i < tokens.length && !isCommand(tokens[i]) ? double.parse(tokens[i++]) : double.nan;
    while (i < tokens.length) {
      if (isCommand(tokens[i])) {
        command = tokens[i++];
      } else if (command.isEmpty) {
        i++; // a number before any command
        continue;
      }
      final rel = command == command.toLowerCase();
      final ox = rel ? x : 0.0, oy = rel ? y : 0.0;
      switch (command.toUpperCase()) {
        case 'M':
          final nx = next() + ox, ny = next() + oy;
          if (nx.isNaN || ny.isNaN) return;
          move(nx, ny);
          (x, y, startX, startY) = (nx, ny, nx, ny);
          command = rel ? 'l' : 'L'; // further pairs are lines
          cx2 = null;
        case 'L':
          final nx = next() + ox, ny = next() + oy;
          if (nx.isNaN || ny.isNaN) return;
          line(nx, ny);
          (x, y) = (nx, ny);
          cx2 = null;
        case 'H':
          final nx = next() + ox;
          if (nx.isNaN) return;
          line(nx, y);
          x = nx;
          cx2 = null;
        case 'V':
          final ny = next() + oy;
          if (ny.isNaN) return;
          line(x, ny);
          y = ny;
          cx2 = null;
        case 'C':
          final v = [for (var k = 0; k < 6; k++) next() + (k.isEven ? ox : oy)];
          if (v.any((n) => n.isNaN)) return;
          cubic(v[0], v[1], v[2], v[3], v[4], v[5]);
          (cx2, cy2, x, y) = (v[2], v[3], v[4], v[5]);
        case 'S':
          final v = [for (var k = 0; k < 4; k++) next() + (k.isEven ? ox : oy)];
          if (v.any((n) => n.isNaN)) return;
          final smooth = 'CcSs'.contains(lastCommand) && cx2 != null;
          final x1 = smooth ? 2 * x - cx2 : x, y1 = smooth ? 2 * y - cy2! : y;
          cubic(x1, y1, v[0], v[1], v[2], v[3]);
          (cx2, cy2, x, y) = (v[0], v[1], v[2], v[3]);
        case 'Q':
          final v = [for (var k = 0; k < 4; k++) next() + (k.isEven ? ox : oy)];
          if (v.any((n) => n.isNaN)) return;
          quad(v[0], v[1], v[2], v[3]);
          (cx2, cy2, x, y) = (v[0], v[1], v[2], v[3]);
        case 'T':
          final nx = next() + ox, ny = next() + oy;
          if (nx.isNaN || ny.isNaN) return;
          final smooth = 'QqTt'.contains(lastCommand) && cx2 != null;
          final x1 = smooth ? 2 * x - cx2 : x, y1 = smooth ? 2 * y - cy2! : y;
          quad(x1, y1, nx, ny);
          (cx2, cy2, x, y) = (x1, y1, nx, ny);
        case 'A':
          final rx = next(), ry = next(), rotation = next(), large = next(), sweep = next();
          final nx = next() + ox, ny = next() + oy;
          if ([rx, ry, rotation, large, sweep, nx, ny].any((n) => n.isNaN)) return;
          _arc(x, y, rx.abs(), ry.abs(), rotation, large != 0, sweep != 0, nx, ny);
          (x, y) = (nx, ny);
          cx2 = null;
        case 'Z':
          close();
          (x, y) = (startX, startY);
          cx2 = null;
          lastCommand = command;
          continue; // takes no numbers; a number after it begins a line
        default:
          return;
      }
      lastCommand = command;
    }
  }

  /// SVG's endpoint arc as cubic Béziers (the specification's conversion to a centre).
  void _arc(double x1, double y1, double rx, double ry, double degrees, bool large, bool sweep, double x2, double y2) {
    if (rx == 0 || ry == 0 || (x1 == x2 && y1 == y2)) {
      line(x2, y2);
      return;
    }
    final phi = degrees * math.pi / 180, cos = math.cos(phi), sin = math.sin(phi);
    final dx = (x1 - x2) / 2, dy = (y1 - y2) / 2;
    final xp = cos * dx + sin * dy, yp = -sin * dx + cos * dy;
    final lambda = xp * xp / (rx * rx) + yp * yp / (ry * ry);
    if (lambda > 1) {
      rx *= math.sqrt(lambda);
      ry *= math.sqrt(lambda);
    }
    final num = rx * rx * ry * ry - rx * rx * yp * yp - ry * ry * xp * xp;
    final den = rx * rx * yp * yp + ry * ry * xp * xp;
    var coef = math.sqrt(math.max(0, num / den));
    if (large == sweep) coef = -coef;
    final cxp = coef * rx * yp / ry, cyp = -coef * ry * xp / rx;
    final cx = cos * cxp - sin * cyp + (x1 + x2) / 2, cy = sin * cxp + cos * cyp + (y1 + y2) / 2;
    double angle(double ux, double uy, double vx, double vy) {
      final a = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
      return a;
    }

    final start = angle(1, 0, (xp - cxp) / rx, (yp - cyp) / ry);
    var delta = angle((xp - cxp) / rx, (yp - cyp) / ry, (-xp - cxp) / rx, (-yp - cyp) / ry);
    if (!sweep && delta > 0) delta -= 2 * math.pi;
    if (sweep && delta < 0) delta += 2 * math.pi;
    final pieces = (delta.abs() / (math.pi / 2)).ceil().clamp(1, 4);
    final step = delta / pieces, k = 4 / 3 * math.tan(step / 4);
    var a0 = start;
    for (var p = 0; p < pieces; p++) {
      final a1 = a0 + step;
      final (c0, s0, c1, s1) = (math.cos(a0), math.sin(a0), math.cos(a1), math.sin(a1));
      (double, double) at(double ex, double ey) => (cx + rx * ex * cos - ry * ey * sin, cy + rx * ex * sin + ry * ey * cos);
      final (p1x, p1y) = at(c0 - k * s0, s0 + k * c0);
      final (p2x, p2y) = at(c1 + k * s1, s1 - k * c1);
      final (p3x, p3y) = at(c1, s1);
      cubic(p1x, p1y, p2x, p2y, p3x, p3y);
      a0 = a1;
    }
  }
}
