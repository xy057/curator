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

/// Bars [from] to [to] (exclusive) engraved with the bars around them ([lead] before, [trail]
/// after: [EditableScore.chunk]), of which it draws its own: what starts in them, whole (a tie
/// or slur into the next bar, a text wider than its bar), and nothing that starts in the others.
/// Chunks side by side so draw everything once, as one engraving of the whole score would.
class EditChunk {
  EditChunk._(this.from, this.to, this.lead, this.trail, this.data, this.list, this.left, this.right);

  final int from, to;

  /// How many bars before [from] and after [to] were engraved with it.
  final int lead, trail;
  final EngravingData data;
  final ScoreDisplayList list;

  /// How many bars a chunk holds in a score of [staves] staves: fewer the more there are, as a
  /// key typed engraves its chunk again and Verovio takes as long as the notes are many (two
  /// bars of an orchestra, six of a piano).
  static int barsFor(int staves) => (24 ~/ math.max(1, staves)).clamp(2, 6);

  /// Engraves bars [from] to [to] of [score] (Verovio runs on an isolate).
  static Future<EditChunk> engrave(EditableScore score, int from, int to, {String? resourceDirectory}) async {
    final (:xml, :lead, :trail) = score.chunk(from, to);
    final data = await Engraver.engrave(xml, resourceDirectory: resourceDirectory ?? engineResourceDirectory());
    final list = ScoreDisplayList.build(data, const RenderStyle(), indexSources: true);
    final bars = data.measures;
    double left;
    if (lead > 0 && lead < bars.length) {
      // From the barline before its first bar: a key, a time signature or a repeat's start
      // between that and the bar's first note is the bar's.
      left = bars[lead - 1].right;
    } else {
      // The score's first bars: from where the staff lines start (the names and the brace left
      // of them are the editor's own column).
      final l = list.staves.fold(double.infinity, (m, s) => math.min(m, s.inkLeft ?? double.infinity));
      left = l.isFinite ? l : 0.0;
    }
    final last = math.min(bars.length, lead + (to - from)) - 1;
    final right = last < 0 ? data.width : bars[last].right;
    return EditChunk._(from, to, lead, trail, data, list, left, right);
  }

  /// Where its own bars start and end in its engraving: the barline before the first (the staff
  /// lines' left, for the score's first bars) and the last's right one.
  final double left, right;
  double get width => right - left;

  /// The engraving of bar [m] (one of its own).
  MeasureLayout? measure(int m) => m < from || m >= to || m - from + lead >= data.measures.length ? null : data.measures[m - from + lead];

  /// Whether [item] is its own to draw: one that starts in its bars. A barline between two
  /// chunks is the later one's (its left edge is before the bar by half its width).
  bool owns(DisplayItem item) {
    final x = item.bounds.left + data.staffSpace * _seam;
    return (lead == 0 || x >= left) && (trail == 0 || x < right);
  }

  /// How far before a bar's left barline what is drawn there is still the bar's, staff spaces.
  static const _seam = 0.5;

  /// How far right of [right] its own ink runs (a slur into the bars after).
  late final double spill = () {
    var reach = 0.0;
    for (final layer in [...list.staves, list.barlines]) {
      for (final item in layer.itemsIn(right - data.staffSpace * 40, 1e12)) {
        if (owns(item)) reach = math.max(reach, item.bounds.right - right);
      }
    }
    return reach;
  }();

  /// Each tagged element's outline per staff, in the chunk's units: of what it draws.
  late final Map<String, List<({int staff, ui.Rect rect})>> outlines = () {
    final out = <String, List<({int staff, ui.Rect rect})>>{};
    for (final MapEntry(key: id, value: items) in list.sourced.entries) {
      final byStaff = <int, ui.Rect>{};
      for (final (:staff, :item) in items) {
        if (!owns(item)) continue;
        byStaff[staff] = byStaff[staff]?.expandToInclude(item.bounds) ?? item.bounds;
      }
      if (byStaff.isNotEmpty) out[id] = [for (final MapEntry(key: staff, value: rect) in byStaff.entries) (staff: staff, rect: rect)];
    }
    return out;
  }();

  void dispose() => list.dispose();
}

/// The chunks side by side as one endless system (Dorico's galley view), in Verovio's units:
/// staff [n] (1-based in score order) at [staffTop] for all of them.
class EditGalley {
  /// [bars]: how many bars a chunk not engraved yet holds (its width is a guess).
  EditGalley(List<EditChunk?> chunks, {double margin = 0, int bars = 4}) : chunks = List.unmodifiable(chunks) {
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
          if (layer != null) spaceAbove = math.max(spaceAbove ?? 0, layer.maxInk(c.left, c.right).above);
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
      if (c != null && layer != null) below = math.max(below, layer.maxInk(c.left, c.right).below);
    }
    height = (tops[count] ?? margin) + (_heights[count] ?? 0) + below + margin;
    // Chunks: one after another; one not engraved yet is as wide as its bars at a guess.
    final space = staffSpace;
    var x = margin;
    for (final c in chunks) {
      _lefts.add(x);
      x += c?.width ?? bars * space * 14;
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

  /// The chunk bar [m] is in, if it is engraved.
  EditChunk? _chunkOf(int m) {
    for (final c in chunks) {
      if (c != null && m >= c.from && m < c.to) return c;
    }
    return null;
  }

  /// Whether chunk [k] has anything to draw between [left] and [right] (galley units): its own
  /// bars, or what runs on from them.
  bool _inView(int k, double left, double right) {
    final c = chunks[k];
    return c != null && _lefts[k] <= right && _lefts[k] + c.width + c.spill >= left;
  }

  /// Draws what of it lies in [visible] (galley units), in [ink], and [selected] in [accent].
  void paint(ui.Canvas canvas, ui.Rect visible, {required ui.Color ink, Set<String> selected = const {}, ui.Color? accent}) {
    canvas.saveLayer(visible, ui.Paint()..colorFilter = ui.ColorFilter.mode(ink, ui.BlendMode.srcIn));
    final linePaint = ui.Paint()..color = const ui.Color(0xFF000000);
    for (var k = 0; k < chunks.length; k++) {
      if (!_inView(k, visible.left, visible.right)) continue;
      final c = chunks[k]!;
      for (final layer in c.list.staves) {
        final shift = _shift(k, layer.info.n);
        final top = layer.info.top + shift.dy;
        if (top - staffSpace * 12 > visible.bottom || top + layer.info.height + staffSpace * 12 < visible.top) continue;
        canvas
          ..save()
          ..translate(shift.dx, shift.dy);
        final left = visible.left - shift.dx, right = visible.right - shift.dx;
        // The staff's lines over its own bars.
        final from = math.max(left - 10, c.left), to = math.min(right + 10, c.right);
        for (final line in layer.lines) {
          final a = math.max(line.left, from), b = math.min(line.right, to);
          if (a >= b) continue;
          linePaint.strokeWidth = line.thickness;
          canvas.drawLine(ui.Offset(a, line.y), ui.Offset(b, line.y), linePaint);
        }
        for (final item in layer.itemsIn(left, right)) {
          if (c.owns(item)) item.paint(canvas);
        }
        // The system's barlines, the stretch over this staff's lines.
        canvas.clipRect(ui.Rect.fromLTRB(left, layer.info.top - 0.5, right, layer.info.top + layer.info.height + 0.5));
        for (final item in c.list.barlines.itemsIn(left, right)) {
          if (c.owns(item)) item.paint(canvas);
        }
        canvas.restore();
      }
    }
    canvas.restore();
    if (selected.isEmpty || accent == null) return;
    canvas.saveLayer(visible, ui.Paint()..colorFilter = ui.ColorFilter.mode(accent, ui.BlendMode.srcIn));
    for (var k = 0; k < chunks.length; k++) {
      if (!_inView(k, visible.left, visible.right)) continue;
      final c = chunks[k]!;
      for (final id in selected) {
        for (final (:staff, :item) in c.list.sourced[id] ?? const <({int staff, DisplayItem item})>[]) {
          if (!c.owns(item)) continue;
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
    if (c == null) return null;
    final local = x - _lefts[k] + c.left;
    for (var bar = c.from; bar < c.to; bar++) {
      final m = c.measure(bar);
      if (m == null) break;
      if (local >= m.right && bar < c.to - 1 && c.measure(bar + 1) != null) continue;
      final points = _points(m);
      var best = points.first;
      for (final pt in points) {
        if (pt.time >= m.duration - 1e-9) continue;
        if ((pt.x - local).abs() < (best.x - local).abs()) best = pt;
      }
      return (measure: bar, time: _frac(best.time));
    }
    return null;
  }

  /// Where in bar [m] time [t] is drawn: at a note starting then, else between its neighbours.
  double? xOf(int m, Frac t) {
    final c = _chunkOf(m), layout = c?.measure(m);
    if (c == null || layout == null) return null;
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
    return x - c.left + _lefts[chunks.indexOf(c)];
  }

  /// A bar's left and right barlines, galley units.
  ({double left, double right})? barOf(int m) {
    final c = _chunkOf(m), layout = c?.measure(m);
    if (c == null || layout == null) return null;
    final shift = _lefts[chunks.indexOf(c)] - c.left;
    return (left: layout.left + shift, right: layout.right + shift);
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
