/// The score editor's galley: the score engraved a few bars at a time ([EditChunk]) so an edit
/// engraves only its own bars again, the chunks set side by side with every staff at one height
/// ([EditGalley]), drawn, and asked what is where.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'curated_scene.dart' show engineResourceDirectory;
import 'display_list.dart';
import 'engraving.dart';
import 'score_editing.dart';

/// Bars [from] to [to] (exclusive) engraved as a score of their own.
class EditChunk {
  EditChunk._(this.from, this.to, this.data, this.list, this._hidden, this.left);

  final int from, to;
  final EngravingData data;
  final ScoreDisplayList list;

  /// Commands left out: the clefs, keys and time signature Verovio draws at a chunk's start
  /// that the bar only carries in.
  final Set<int> _hidden;

  /// How many bars a chunk holds.
  static const bars = 8;

  /// Engraves bars [from] to [to] of [score] (Verovio runs on an isolate).
  static Future<EditChunk> engrave(EditableScore score, int from, int to, {String? resourceDirectory}) async {
    final (:xml, :timeShown, :clefsShown, :keysShown) = score.chunk(from, to);
    final data = await Engraver.engrave(xml, resourceDirectory: resourceDirectory ?? engineResourceDirectory());
    final hidden = <int>{};
    // After the first, a chunk carries on the one before: Verovio's system start (brace,
    // brackets, clefs, key, time) is cut off at the first bar, but for what the bar changes.
    var start = double.negativeInfinity;
    if (from > 0 && data.measures.isNotEmpty) {
      final barLeft = data.measures.first.left;
      start = barLeft;
      for (final s in data.signatures) {
        if (s.x >= barLeft) continue;
        final shown = switch (s) {
          ClefSignature() => clefsShown.contains(s.staff),
          KeySignature() => keysShown.contains(s.staff),
          TimeSignature() => timeShown,
        };
        if (shown) {
          start = math.min(start, s.x - data.staffSpace * 0.5);
        } else {
          for (var i = s.commandStart; i < s.commandStart + s.commandCount; i++) {
            hidden.add(i);
          }
        }
      }
    }
    final list = ScoreDisplayList.build(data, const RenderStyle(), hiddenCommands: hidden, indexSources: true);
    double left = start;
    if (!left.isFinite) {
      final l = list.staves.fold(double.infinity, (m, s) => math.min(m, s.inkLeft ?? double.infinity));
      left = l.isFinite ? l : 0.0;
    }
    return EditChunk._(from, to, data, list, hidden, left);
  }

  /// Where it starts: its staff lines' left, or (after the first) where its first bar or the
  /// first change it shows does; nothing left of it is drawn.
  final double left;
  late final double right = data.measures.isEmpty ? data.width : data.measures.last.right;
  double get width => right - left;

  /// Each tagged element's outline per staff, in the chunk's units.
  late final Map<String, List<({int staff, ui.Rect rect})>> outlines = {
    for (final MapEntry(key: id, value: items) in list.sourced.entries)
      id: [
        for (final staff in {for (final i in items) i.staff})
          (staff: staff, rect: items.where((i) => i.staff == staff).map((i) => i.item.bounds).reduce((a, b) => a.expandToInclude(b))),
      ],
  };

  /// Whether command [i] is left out.
  bool hides(int i) => _hidden.contains(i);

  void dispose() => list.dispose();
}

/// The chunks side by side as one endless system (Dorico's galley view), in Verovio's units:
/// staff [n] (1-based in score order) at [staffTop] for all of them.
class EditGalley {
  EditGalley(List<EditChunk?> chunks, {double margin = 0}) : chunks = List.unmodifiable(chunks) {
    // Staves: each gap the most any chunk needs.
    final count = chunks.fold(0, (m, c) => math.max(m, c?.data.staves.length ?? 0));
    _staffCount = count;
    final tops = <int, double>{};
    var y = margin;
    double? spaceAbove;
    for (var n = 1; n <= count; n++) {
      var gap = 0.0, height = 0.0;
      for (final c in chunks) {
        if (c == null) continue;
        final staves = c.data.staves;
        final here = staves.where((s) => s.n == n).firstOrNull;
        if (here == null) continue;
        height = math.max(height, here.height);
        final above = n == 1 ? null : staves.where((s) => s.n == n - 1).firstOrNull;
        if (above != null) gap = math.max(gap, here.top - above.top);
        if (n == 1) {
          // Room above the top staff: as much ink as rises over it anywhere.
          final layer = c.list.staves.where((l) => l.info.n == 1).firstOrNull;
          if (layer != null) spaceAbove = math.max(spaceAbove ?? 0, layer.maxInk(0, 1e9).above);
        }
      }
      if (n == 1) y += spaceAbove ?? 0;
      y += n == 1 ? 0 : gap;
      tops[n] = y;
      _heights[n] = height;
    }
    _tops.addAll(tops);
    // Room below the last staff.
    var below = 0.0;
    for (final c in chunks) {
      final layer = c?.list.staves.where((l) => l.info.n == count).firstOrNull;
      if (layer != null) below = math.max(below, layer.maxInk(0, 1e9).below);
    }
    height = (tops[count] ?? margin) + (_heights[count] ?? 0) + below + margin;
    // Chunks: one after another; one not engraved yet is as wide as its bars at a guess.
    final space = staffSpace;
    var x = margin;
    for (final c in chunks) {
      _lefts.add(x);
      x += c?.width ?? EditChunk.bars * space * 14;
    }
    width = x + margin;
  }

  final List<EditChunk?> chunks;
  int _staffCount = 0;
  final _tops = <int, double>{}, _heights = <int, double>{};
  final _lefts = <double>[];
  late final double width;
  late final double height;

  /// Device units a staff space: the engraving's.
  double get staffSpace => chunks.firstWhere((c) => c != null, orElse: () => null)?.data.staffSpace ?? 90;

  double? staffTop(int n) => _tops[n];
  double staffHeight(int n) => _heights[n] ?? staffSpace * 4;

  /// Chunk [k]'s left edge in the galley.
  double chunkLeft(int k) => _lefts[k];

  int _chunkAtX(double x) {
    for (var k = _lefts.length - 1; k >= 0; k--) {
      if (x >= _lefts[k]) return k;
    }
    return 0;
  }

  /// How far chunk [k]'s staff [n] moves to its place.
  ui.Offset _shift(int k, int n) {
    final c = chunks[k]!;
    final info = c.data.staves.where((s) => s.n == n).firstOrNull;
    return ui.Offset(_lefts[k] - c.left, (_tops[n] ?? 0) - (info?.top ?? 0));
  }

  /// Draws what of it lies in [visible] (galley units), in [ink], and [selected] in [accent].
  void paint(ui.Canvas canvas, ui.Rect visible, {required ui.Color ink, Set<String> selected = const {}, ui.Color? accent}) {
    canvas.saveLayer(visible, ui.Paint()..colorFilter = ui.ColorFilter.mode(ink, ui.BlendMode.srcIn));
    final linePaint = ui.Paint()..color = const ui.Color(0xFF000000);
    for (var k = 0; k < chunks.length; k++) {
      final c = chunks[k];
      if (c == null) continue;
      if (_lefts[k] > visible.right || _lefts[k] + c.width < visible.left) continue;
      for (final layer in c.list.staves) {
        final shift = _shift(k, layer.info.n);
        final top = layer.info.top + shift.dy;
        if (top - staffSpace * 12 > visible.bottom || top + layer.info.height + staffSpace * 12 < visible.top) continue;
        canvas
          ..save()
          ..translate(shift.dx, shift.dy)
          ..clipRect(ui.Rect.fromLTRB(c.left, -1e9, 1e12, 1e9)); // what the chunk starts with cut off
        final left = math.max(visible.left - shift.dx, c.left), right = visible.right - shift.dx;
        for (final line in layer.lines) {
          if (line.right < left || line.left > right) continue;
          linePaint.strokeWidth = line.thickness;
          canvas.drawLine(ui.Offset(math.max(line.left, left - 10), line.y), ui.Offset(math.min(line.right, right + 10), line.y), linePaint);
        }
        for (final item in layer.itemsIn(left, right)) {
          item.paint(canvas);
        }
        // The system's barlines, the stretch over this staff's lines.
        canvas
          ..save()
          ..clipRect(ui.Rect.fromLTRB(left, layer.info.top - 0.5, right, layer.info.top + layer.info.height + 0.5));
        for (final item in c.list.barlines.itemsIn(left, right)) {
          item.paint(canvas);
        }
        canvas
          ..restore()
          ..restore();
      }
    }
    canvas.restore();
    if (selected.isEmpty || accent == null) return;
    canvas.saveLayer(visible, ui.Paint()..colorFilter = ui.ColorFilter.mode(accent, ui.BlendMode.srcIn));
    for (var k = 0; k < chunks.length; k++) {
      final c = chunks[k];
      if (c == null || _lefts[k] > visible.right || _lefts[k] + c.width < visible.left) continue;
      for (final id in selected) {
        for (final (:staff, :item) in c.list.sourced[id] ?? const <({int staff, DisplayItem item})>[]) {
          final shift = _shift(k, staff);
          canvas
            ..save()
            ..translate(shift.dx, shift.dy);
          item.paint(canvas);
          canvas.restore();
        }
      }
    }
    canvas.restore();
  }

  /// The tagged element at [p] (galley units): the smallest outline around it, else the nearest
  /// within a staff space.
  String? hitTest(ui.Offset p) {
    String? best;
    double bestScore = double.infinity;
    final k = _chunkAtX(p.dx);
    for (final j in {k, k - 1, k + 1}) {
      if (j < 0 || j >= chunks.length || chunks[j] == null) continue;
      for (final MapEntry(key: id, value: outlines) in chunks[j]!.outlines.entries) {
        for (final (:staff, :rect) in outlines) {
          final r = rect.shift(_shift(j, staff)).inflate(staffSpace * 0.25);
          if (!r.inflate(staffSpace * 0.75).contains(p)) continue;
          final inside = r.contains(p);
          final distance = inside ? 0.0 : (r.center - p).distance;
          final score = inside ? r.width * r.height : 1e12 + distance;
          if (score < bestScore) {
            bestScore = score;
            best = id;
          }
        }
      }
    }
    return best;
  }

  /// Where [id] is drawn (the union over its staves), galley units.
  ui.Rect? boundsOf(String id) {
    ui.Rect? out;
    for (var k = 0; k < chunks.length; k++) {
      for (final (:staff, :rect) in chunks[k]?.outlines[id] ?? const <({int staff, ui.Rect rect})>[]) {
        final r = rect.shift(_shift(k, staff));
        out = out?.expandToInclude(r) ?? r;
      }
    }
    return out;
  }

  /// The staff nearest [y] (its number).
  int staffAtY(double y) {
    var best = 1;
    var bestDistance = double.infinity;
    for (var n = 1; n <= _staffCount; n++) {
      final top = _tops[n]!, bottom = top + staffHeight(n);
      final d = y < top ? top - y : y > bottom ? y - bottom : 0.0;
      if (d < bestDistance) {
        bestDistance = d;
        best = n;
      }
    }
    return best;
  }

  /// The bar and the time in it nearest [x]: a note's start, or a bar's.
  ({int measure, Frac time})? timeAtX(double x) {
    final k = _chunkAtX(x);
    final c = chunks[k];
    if (c == null || c.data.measures.isEmpty) return null;
    final local = x - _lefts[k] + c.left;
    for (final (i, m) in c.data.measures.indexed) {
      if (local >= m.right && i < c.data.measures.length - 1) continue;
      final points = _points(m);
      var best = points.first;
      for (final pt in points) {
        if (pt.time >= m.duration - 1e-9) continue;
        if ((pt.x - local).abs() < (best.x - local).abs()) best = pt;
      }
      return (measure: c.from + i, time: _frac(best.time));
    }
    return null;
  }

  /// Where in bar [m] time [t] is drawn: at a note starting then, else between its neighbours.
  double? xOf(int m, Frac t) {
    final k = m ~/ EditChunk.bars;
    if (k >= chunks.length) return null;
    final c = chunks[k];
    if (c == null || m - c.from >= c.data.measures.length || m < c.from) return null;
    final layout = c.data.measures[m - c.from];
    final time = t.toDouble();
    final points = _points(layout);
    var x = points.last.x;
    for (var i = 0; i < points.length; i++) {
      if ((points[i].time - time).abs() < 1e-6) {
        x = points[i].x;
        break;
      }
      if (points[i].time > time && i > 0) {
        final a = points[i - 1], b = points[i];
        x = a.x + (b.x - a.x) * (time - a.time) / (b.time - a.time);
        break;
      }
    }
    return x - c.left + _lefts[k];
  }

  /// A bar's left and right barlines, galley units.
  ({double left, double right})? barOf(int m) {
    final k = m ~/ EditChunk.bars;
    if (k >= chunks.length) return null;
    final c = chunks[k];
    if (c == null || m - c.from >= c.data.measures.length || m < c.from) return null;
    final layout = c.data.measures[m - c.from];
    return (left: layout.left - c.left + _lefts[k], right: layout.right - c.left + _lefts[k]);
  }

  static List<({double time, double x})> _points(MeasureLayout m) {
    final points = <({double time, double x})>[];
    for (var i = 0; i < m.onsetTimes.length; i++) {
      points.add((time: m.onsetTimes[i], x: m.onsetXs[i]));
    }
    if (points.isEmpty || points.first.time > 1e-9) points.insert(0, (time: 0, x: points.isEmpty ? m.left + (m.right - m.left) * 0.15 : m.left + (points.first.x - m.left) * 0.5));
    points.add((time: m.duration, x: m.right));
    return points;
  }

  static Frac _frac(double quarters) => Frac((quarters * 3840).round(), 3840);
}
