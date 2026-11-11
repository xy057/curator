import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'pdf_layout.dart';

/// Part of a page as ink: a byte a pixel (0 paper … 255 black), [scale] pixels a point, its top
/// left at ([left], [top]) points on the page.
class PdfRaster {
  PdfRaster(this.ink, this.width, this.height, {required this.scale, this.left = 0, this.top = 0});

  final Uint8List ink;
  final int width, height;
  final double scale, left, top;

  /// Pixel column / row of a page x / y (points).
  double col(double x) => (x - left) * scale;
  double row(double y) => (y - top) * scale;

  /// Page x / y (points) of a pixel column / row.
  double xOf(num col) => left + col / scale;
  double yOf(num row) => top + row / scale;

  static const dark = 110;

  /// Ink at all: a hairline drawn between two pixels is grey in both.
  static const faint = 40;

  bool isDark(int x, int y) => x >= 0 && y >= 0 && x < width && y < height && ink[y * width + x] >= dark;
  bool isInked(int x, int y) => x >= 0 && y >= 0 && x < width && y < height && ink[y * width + x] >= faint;
}

/// Whose each pixel of a system's raster is ([PdfDetect.assign]): no one's, one staff's, or
/// (a mark lying whole where staves' regions overlap) each of theirs.
final class PdfParts {
  PdfParts(this.of, this.sets);

  /// Per pixel, row by row, its owners: an index into [sets]; -1: no one's.
  final Int16List of;

  /// The sets of owners, each its staves' indices top to bottom.
  final List<List<int>> sets;

  /// The staves pixel [i] is, top to bottom.
  List<int> at(int i) => of[i] < 0 ? const [] : sets[of[i]];

  /// Per set of owners, whether staff [staff] is among them (1) or not (0).
  Uint8List holding(int staff) => Uint8List.fromList([for (final s in sets) s.contains(staff) ? 1 : 0]);
}

/// A staff found on a page: its lines' top, spacing and horizontal reach, points.
typedef FoundStaff = ({double top, double space, double left, double right, double thickness});

/// Finds what a PDF score's pages hold: staves, systems, barlines, where a system's music starts,
/// and per bar how far each staff's ink reaches and whether it plays. Works on a page's ink
/// ([PdfRaster]); everything it finds is in points, so it holds at any resolution.
abstract final class PdfDetect {
  /// Pixels a point pages are read at for finding things: a staff space of 4 points is 10 pixels.
  static const scale = 2.5;

  /// The staves of [page] (five-line ones), top to bottom.
  static List<FoundStaff> staves(PdfRaster page) {
    final w = page.width, h = page.height, ink = page.ink;
    // A staff line's row is mostly long runs of ink: text has short ones.
    final long = List<int>.filled(h, 0);
    final minRun = math.max(8, (w * 0.02).round());
    for (var y = 0; y < h; y++) {
      var inLong = 0, run = 0;
      final base = y * w;
      for (var x = 0; x <= w; x++) {
        if (x < w && ink[base + x] >= PdfRaster.dark) {
          run++;
        } else {
          if (run >= minRun) inLong += run;
          run = 0;
        }
      }
      long[y] = inLong;
    }
    // Rows of ink together are one line: its first and last row, and how much its fullest fills.
    final lines = <(int, int, int)>[];
    for (var y = 0; y < h; y++) {
      if (long[y] < w * 0.2) continue;
      var end = y;
      while (end + 1 < h && long[end + 1] >= w * 0.2) {
        end++;
      }
      lines.add((y, end, [for (var r = y; r <= end; r++) long[r]].reduce(math.max)));
      y = end;
    }
    double middle(int k) => (lines[k].$1 + lines[k].$2) / 2;
    int weakest(List<int> five) => [for (final k in five) lines[k].$3].reduce(math.min);
    // Five lines evenly apart are a staff, from line [i] and line [j] (the next or the one after)
    // on, each next the fuller of the two after the last that lie a gap on. A line it leaves out
    // (one between two of its lines at most) fills under half as much of its row as they do
    // (ties' crests, a beam), or is a third of a gap or less from one of them. Null if none.
    List<int>? five(int i, int j) {
      final gap = middle(j) - middle(i), off = math.max(1.5, gap * 0.2);
      // A space is under a fortieth of the page's width: a line of each of five staves (their
      // others too faint to be found) is no staff.
      if (gap < 3 || gap > w / 40) return null;
      final picked = [i, j];
      while (picked.length < 5) {
        final want = middle(picked.last) + gap;
        int? next;
        for (var k = picked.last + 1; k <= picked.last + 2 && k < lines.length; k++) {
          if ((middle(k) - want).abs() <= off && (next == null || lines[k].$3 > lines[next].$3)) next = k;
        }
        if (next == null) return null;
        picked.add(next);
      }
      final least = weakest(picked);
      for (var k = i + 1; k < picked.last; k++) {
        if (!picked.contains(k) && lines[k].$3 * 2 >= least && !picked.any((p) => (middle(p) - middle(k)).abs() <= gap / 3)) {
          return null;
        }
      }
      return picked;
    }

    // The five from line [i] whose weakest line is fullest: a staff's lines run its length.
    List<int>? fullest(int i) {
      List<int>? best;
      for (var j = i + 1; j <= i + 2 && j < lines.length; j++) {
        final staff = five(i, j);
        if (staff != null && (best == null || weakest(staff) > weakest(best))) best = staff;
      }
      return best;
    }

    final found = <FoundStaff>[];
    var i = 0;
    while (i < lines.length) {
      final first = fullest(i);
      if (first == null) {
        i++;
        continue;
      }
      // Ties a space above a staff can fill a row as a line would: of the fives starting before
      // this one's last line, the fullest.
      var staff = first;
      for (var k = i + 1; k < first.last; k++) {
        final other = fullest(k);
        if (other != null && weakest(other) > weakest(staff)) staff = other;
      }
      // A line a scan leans across rows can break in two: a line left out close to one of the
      // five, filling half as much or more, is part of it.
      final rows = [for (final k in staff) (lines[k].$1, lines[k].$2)];
      final near = (middle(staff.last) - middle(staff.first)) / 12;
      for (var k = staff.first + 1; k < staff.last; k++) {
        for (final (n, p) in staff.indexed) {
          if (k != p && (middle(k) - middle(p)).abs() <= near && lines[k].$3 * 2 >= lines[p].$3) {
            rows[n] = (math.min(rows[n].$1, lines[k].$1), math.max(rows[n].$2, lines[k].$2));
          }
        }
      }
      final mids = [for (final (a, b) in rows) (a + b) / 2];
      final space = (mids[4] - mids[0]) / 4;
      final thickness = [for (final (a, b) in rows) b - a + 1].reduce(math.max);
      final at = [for (final m in mids) m.round()];
      var (left, right) = _reach(page, at, space);
      left = _lineStart(page, at, space, left, left + (space * 4).round()) ?? left;
      if (right - left > space * 8) {
        found.add((
          top: page.yOf(mids[0]),
          space: space / page.scale,
          left: page.xOf(left),
          right: page.xOf(right),
          thickness: thickness / page.scale,
        ));
      }
      i = staff.last + 1;
    }
    return found;
  }

  /// Whether column [x] has ink on four of a staff's lines (at [rows], [space] pixels apart),
  /// give or take a fifth of a space: a scan leaning puts a line a row or two off its middle
  /// row at its ends.
  static bool _lined(PdfRaster page, List<int> rows, double space, int x) {
    final near = math.max(1, (space * 0.2).round());
    var n = 0;
    for (final y in rows) {
      for (var d = -near; d <= near; d++) {
        if (page.isDark(x, y + d)) {
          n++;
          break;
        }
      }
    }
    return n >= 4;
  }

  /// The columns from where a staff's lines start to where they end: the longest stretch where
  /// four of its five lines have ink, gaps under a staff space bridged.
  static (int, int) _reach(PdfRaster page, List<int> rows, double space) {
    final w = page.width;
    bool lined(int x) => _lined(page, rows, space, x);

    var best = (0, 0), start = -1, lastLined = -1;
    final bridge = space.ceil();
    for (var x = 0; x <= w; x++) {
      final on = x < w && lined(x);
      if (on) {
        if (start < 0 || x - lastLined > bridge) start = x;
        lastLined = x;
        if (lastLined - start > best.$2 - best.$1) best = (start, lastLined);
      }
    }
    return best;
  }

  /// The first column from [from] to [to] where a staff's lines (at [rows]) start: four of them
  /// inked and its spaces not (a brace's, a bracket's or a barline's column has both), for a
  /// space on. Null if none.
  static int? _lineStart(PdfRaster page, List<int> rows, double space, int from, int to) {
    bool lined(int x) => _lined(page, rows, space, x);

    bool open(int x) {
      var n = 0;
      for (var k = 0; k + 1 < rows.length; k++) {
        if (!page.isInked(x, (rows[k] + rows[k + 1]) ~/ 2)) n++;
      }
      return n >= rows.length - 2;
    }

    final run = math.max(2, space.round());
    for (var x = math.max(0, from); x <= math.min(page.width - 1 - run, to); x++) {
      if (!lined(x) || !open(x)) continue;
      var k = 1;
      while (k < run && lined(x + k)) {
        k++;
      }
      if (k == run) return x;
    }
    return null;
  }

  /// Where [staff]'s lines start on [page] (points), braces and brackets left of them left out.
  static double staffLeft(PdfRaster page, PdfStaff staff) {
    final rows = [for (var k = 0; k < staff.lines; k++) page.row(staff.top + k * staff.space).round()];
    final x = _lineStart(page, rows, staff.space * page.scale, 0, page.width);
    return x == null ? 0 : page.xOf(x);
  }

  /// [staves] grouped into systems: staves joined at their left by a line (the system's
  /// barline, a bracket or a brace) are one system.
  static List<List<FoundStaff>> systems(PdfRaster page, List<FoundStaff> staves) {
    final out = <List<FoundStaff>>[];
    for (final staff in staves) {
      final last = out.lastOrNull?.last;
      if (last != null && _joined(page, last, staff)) {
        out.last.add(staff);
      } else {
        out.add([staff]);
      }
    }
    return out;
  }

  /// Whether a vertical line runs from [above]'s bottom line to [below]'s top line near their
  /// left ends.
  static bool _joined(PdfRaster page, FoundStaff above, FoundStaff below) {
    if ((above.left - below.left).abs() > above.space * 3) return false;
    final from = page.row(above.top + 4 * above.space).round(), to = page.row(below.top).round();
    if (to <= from) return true;
    final left = page.col(math.min(above.left, below.left) - above.space * 3).floor();
    final right = page.col(math.max(above.left, below.left) + above.space * 0.6).ceil();
    for (var x = math.max(0, left); x <= math.min(page.width - 1, right); x++) {
      var y = from;
      while (y <= to && (page.isInked(x, y) || page.isInked(x - 1, y) || page.isInked(x + 1, y))) {
        y++;
      }
      if (y > to) return true;
    }
    return false;
  }

  /// Where the music of a system whose staves are [staves] starts: past the clef, key and time
  /// signature at their left (points).
  static double musicStart(PdfRaster page, List<FoundStaff> staves) {
    final space = staves.map((s) => s.space).reduce(math.min);
    final start = staves.map((s) => s.left).reduce(math.min);
    final from = page.col(start + space * 0.4).round(), to = math.min(page.width, page.col(start + space * 22).round());
    if (to <= from) return start;
    // Columns holding ink besides the staff lines, in any staff.
    final inked = List<bool>.filled(to - from, false);
    for (final staff in staves) {
      final lineRows = <int>{
        for (var k = 0; k < 5; k++)
          for (var d = -1; d <= 1; d++) page.row(staff.top + k * staff.space).round() + d,
      };
      final top = page.row(staff.top - staff.space).round(), bottom = page.row(staff.top + 5 * staff.space).round();
      for (var x = from; x < to; x++) {
        if (inked[x - from]) continue;
        for (var y = top; y <= bottom; y++) {
          if (!lineRows.contains(y) && page.isDark(x, y)) {
            inked[x - from] = true;
            break;
          }
        }
      }
    }
    // Runs of inked columns, small gaps bridged: glyphs.
    final px = space * page.scale;
    final glyphs = <(int, int)>[];
    for (var x = 0; x < inked.length; x++) {
      if (!inked[x]) continue;
      var end = x;
      while (end + 1 < inked.length && (inked[end + 1] || (end + 2 < inked.length && inked[end + 2] && px > 6))) {
        end++;
      }
      glyphs.add((x, end));
      x = end;
    }
    if (glyphs.isEmpty || glyphs.first.$1 > px * 2.5) return start + space * 0.5; // no clef here
    // The clef, then what follows it closely and is no wider than an accidental or a time
    // signature's digits: the key and time signature.
    var end = glyphs.first.$2;
    if (end - glyphs.first.$1 > px * 4.5) return page.xOf(from + glyphs.first.$1) + space * 3.2; // run into the music
    for (final (a, b) in glyphs.skip(1).take(10)) {
      if (b - a > px * 2.6) break;
      // The key's accidentals close together; a time signature can stand a little apart, alike
      // in every staff.
      if (a - end > px * 1.15 && (a - end > px * 4 || !_signatureLike(page, staves, from + a, from + b))) break;
      end = b;
    }
    final next = glyphs.where((g) => g.$1 > end).firstOrNull;
    final gap = next == null ? px : math.min(px, (next.$1 - end) / 2);
    return page.xOf(from + end + gap);
  }

  /// Whether columns [a]–[b] hold a time signature: ink within every staff's lines (or most of
  /// them), alike from staff to staff, at least two spaces tall.
  static bool _signatureLike(PdfRaster page, List<FoundStaff> staves, int a, int b) {
    final extents = <(double, double)>[];
    var inked = 0;
    for (final staff in staves) {
      final px = staff.space * page.scale;
      final lineRows = <int>{
        for (var k = 0; k < 5; k++)
          for (var d = -1; d <= 1; d++) page.row(staff.top + k * staff.space).round() + d,
      };
      final top = page.row(staff.top - staff.space * 1.5).round(), bottom = page.row(staff.top + staff.space * 5.5).round();
      double? lo, hi;
      for (var y = top; y <= bottom; y++) {
        if (lineRows.contains(y)) continue;
        for (var x = a; x <= b; x++) {
          if (page.isDark(x, y)) {
            final at = (y - page.row(staff.top)) / px;
            lo ??= at;
            hi = at;
            break;
          }
        }
      }
      if (lo == null) continue;
      inked++;
      if (lo < -0.4 || hi! > 4.4 || hi - lo < 1.5) return false;
      extents.add((lo, hi));
    }
    if (inked < math.max(1, (staves.length * 0.7).ceil())) return false;
    final los = [for (final e in extents) e.$1]..sort(), his = [for (final e in extents) e.$2]..sort();
    final lo = los[los.length ~/ 2], hi = his[his.length ~/ 2];
    return extents.every((e) => (e.$1 - lo).abs() <= 0.45 && (e.$2 - hi).abs() <= 0.45);
  }

  /// Whether a brace joins [above] and [below] (a piano's, a harp's): a curve left of their lines
  /// (which start at [left], points), reaching from one's top to the other's bottom, its middle
  /// further left than its arms (a bracket's line is straight).
  static bool braced(PdfRaster page, PdfStaff above, PdfStaff below, double left) {
    final space = math.min(above.space, below.space);
    // The right edge of the first run of ink left of the lines at row [y], past the system's
    // barline.
    double? edge(double y) {
      final row = page.row(y).round();
      bool inked(int x) => page.isInked(x, row) || page.isInked(x, row - 1) || page.isInked(x, row + 1);
      final px = space * page.scale, limit = math.max(0, page.col(left - space * 3).round());
      final runs = <(int, int)>[];
      for (var x = page.col(left).round() - 1; x > limit && runs.length < 3; x--) {
        if (!inked(x)) continue;
        final right = x;
        while (x > limit && inked(x - 1)) {
          x--;
        }
        if (runs.isNotEmpty && runs.last.$2 - right > px * 1.5) break;
        runs.add((right, x));
      }
      // The system's barline: thin, right at the lines.
      if (runs.isNotEmpty && runs.first.$1 - runs.first.$2 <= px * 0.4 && page.col(left) - runs.first.$1 <= px * 0.4) {
        runs.removeAt(0);
      }
      return runs.isEmpty ? null : page.xOf(runs.first.$1);
    }

    // A brace is thick at its arms and thin at its point, which is all on its left: its right
    // edge there is well left of its arms'.
    final middle = edge((above.bottom + below.top) / 2), upper = edge(above.middle), lower = edge(below.middle);
    if (middle == null || upper == null || lower == null) return false;
    if (middle > math.min(upper, lower) - space * 0.25) return false;
    // It ends at the two staves: nothing there a space past them.
    return edge(above.top - space * 1.2) == null && edge(below.bottom + space * 1.2) == null;
  }

  /// The barlines of a system whose staves are [staves], left to right, past [musicLeft]: a
  /// vertical line through every line of a staff, at the same place in most of its staves (or,
  /// with one staff, standing alone: no notehead on it, ending at the staff).
  static List<PdfBarline> barlines(PdfRaster page, List<FoundStaff> staves, double musicLeft) {
    final space = staves.map((s) => s.space).reduce(math.min);
    final px = space * page.scale;
    final right = staves.map((s) => s.right).reduce(math.max);
    final from = math.max(0, page.col(musicLeft - space * 0.8).round()), to = math.min(page.width - 1, page.col(right + space).round());
    // Per staff, the columns where ink runs through all its lines.
    final perStaff = <List<(int, int)>>[];
    for (final staff in staves) {
      final top = page.row(staff.top).round(), bottom = page.row(staff.top + 4 * staff.space).round();
      final through = <int>[];
      for (var x = from; x <= to; x++) {
        var y = top;
        while (y <= bottom && page.isInked(x, y)) {
          y++;
        }
        if (y > bottom) through.add(x);
      }
      perStaff.add(_runs(through));
    }
    // Lines of one staff found again in the others.
    final candidates = <(int, int)>[];
    for (final run in perStaff.expand((r) => r)) {
      if (run.$2 - run.$1 > px * 0.7) continue; // too wide: a beam's end, a cluster
      candidates.add(run);
    }
    candidates.sort((a, b) => a.$1.compareTo(b.$1));
    final merged = <(int, int, int)>[]; // left, right, staves seen
    for (final c in candidates) {
      final last = merged.lastOrNull;
      if (last != null && c.$1 <= last.$2 + px * 0.25) {
        merged.last = (last.$1, math.max(last.$2, c.$2), last.$3 + 1);
      } else {
        merged.add((c.$1, c.$2, 1));
      }
    }
    final need = staves.length == 1 ? 1 : math.max(2, (staves.length * 0.6).ceil());
    final lines = <(int, int)>[];
    for (final (l, r, seen) in merged) {
      final count = [for (final runs in perStaff) runs.any((run) => run.$1 <= r + 1 && run.$2 >= l - 1)].where((b) => b).length;
      if (count < need && seen < need) continue;
      if (staves.length == 1 && !_alone(page, staves.first, l, r)) continue;
      lines.add((l, r));
    }
    // Lines close together are one barline: a double, a final or a repeat's.
    final out = <PdfBarline>[];
    final staff = staves.first;
    for (var k = 0; k < lines.length; k++) {
      var group = [lines[k]];
      while (k + 1 < lines.length && lines[k + 1].$1 - group.last.$2 <= px * 0.9) {
        group.add(lines[++k]);
      }
      final l = group.first.$1, r = group.last.$2;
      if (page.xOf(r) < musicLeft + space * 0.6 && out.isEmpty && !_dotsRight(page, staff, r)) continue; // the system's start
      final widths = [for (final g in group) g.$2 - g.$1 + 1];
      final thick = [for (final w in widths) w > math.max(2, px * 0.28)];
      final dotsLeft = _dotsLeft(page, staff, l), dotsRight = _dotsRight(page, staff, r);
      final kind = switch ((dotsLeft, dotsRight)) {
        (true, true) => PdfBarlineKind.repeatBoth,
        (true, false) => PdfBarlineKind.repeatEnd,
        (false, true) => PdfBarlineKind.repeatStart,
        _ when group.length >= 2 && thick.last => PdfBarlineKind.end,
        _ when group.length >= 2 => PdfBarlineKind.double,
        _ => PdfBarlineKind.normal,
      };
      // Where the bar changes: a repeat's start at its thick line, everything else at its right.
      final x = kind == PdfBarlineKind.repeatStart ? page.xOf(l) : page.xOf(r + 1);
      out.add(PdfBarline(x, kind));
    }
    return out;
  }

  static List<(int, int)> _runs(List<int> xs) {
    final out = <(int, int)>[];
    for (final x in xs) {
      if (out.isNotEmpty && x <= out.last.$2 + 1) {
        out.last = (out.last.$1, x);
      } else {
        out.add((x, x));
      }
    }
    return out;
  }

  /// Whether the line at columns [l]–[r] of a lone staff stands alone: no notehead touching it,
  /// and it ends at the staff (a stem goes on past it).
  static bool _alone(PdfRaster page, FoundStaff staff, int l, int r) {
    final px = staff.space * page.scale;
    final top = page.row(staff.top).round(), bottom = page.row(staff.top + 4 * staff.space).round();
    final reach = (px * 0.8).round();
    if (page.isDark(l, top - reach) || page.isDark(l, bottom + reach)) return false;
    for (final side in [l - 2, r + 2]) {
      for (var y = top - reach; y <= bottom + reach; y++) {
        // A head's ink beside the line, a staff space wide, not on a staff line.
        var run = 0;
        for (var d = 0; d < px; d++) {
          if (page.isDark(side + (side < l ? -d : d), y)) run++;
        }
        if (run > px * 0.75 && !_onLine(page, staff, y)) return false;
      }
    }
    return true;
  }

  static bool _onLine(PdfRaster page, FoundStaff staff, int y) {
    for (var k = 0; k < 5; k++) {
      if ((page.row(staff.top + k * staff.space) - y).abs() <= math.max(1, staff.thickness * page.scale)) return true;
    }
    return false;
  }

  static bool _dotsLeft(PdfRaster page, FoundStaff staff, int x) => _dots(page, staff, x, -1);
  static bool _dotsRight(PdfRaster page, FoundStaff staff, int x) => _dots(page, staff, x, 1);

  /// Repeat dots beside column [x], to the [side]: in the second and third spaces.
  static bool _dots(PdfRaster page, FoundStaff staff, int x, int side) {
    final px = staff.space * page.scale;
    bool dotAt(double spaceFromTop) {
      final y = page.row(staff.top + spaceFromTop * staff.space).round();
      for (var d = (px * 0.2).round(); d <= px * 1.4; d++) {
        final cx = x + side * d;
        // A dot: ink here, none half a space up or down (no line through it).
        if (page.isDark(cx, y) && page.isDark(cx, y - (px * 0.12).round()) && !page.isDark(cx, y - (px * 0.45).round()) &&
            !page.isDark(cx, y + (px * 0.45).round())) {
          return true;
        }
      }
      return false;
    }

    return dotAt(1.5) && dotAt(2.5);
  }

  /// A page's systems as found: staves, where the music starts, barlines, each staff's region
  /// (from the music's start to its end, the regions meeting at the row the least ink crosses
  /// between two staves). Each staff is no one's yet.
  static List<PdfSystem> page(PdfRaster page, int index) {
    final found = systems(page, staves(page));
    final out = <PdfSystem>[];
    for (final (k, staves) in found.indexed) {
      final space = staves.map((s) => s.space).reduce(math.min);
      final left = musicStart(page, staves);
      final right = staves.map((s) => s.right).reduce(math.max);
      final barlines = PdfDetect.barlines(page, staves, left).where((b) => b.x > left - space && b.x <= right + space).toList();
      // A last barline a hair off the staves' end is that end; one a little before it ends the
      // music, the next key or time signature after it.
      var end = right;
      if (barlines.isNotEmpty && (barlines.last.x - right).abs() < space * 0.8) {
        barlines.last = barlines.last.copyWith(x: right);
      } else if (barlines.isNotEmpty && right - barlines.last.x < space * 5) {
        end = barlines.last.x;
      }
      final first = staves.first, last = staves.last;
      final above = k == 0 ? page.yOf(0) : found[k - 1].last.top + 4 * found[k - 1].last.space;
      final below = k == found.length - 1 ? page.yOf(page.height) : found[k + 1].first.top;
      out.add(PdfSystem.cut(
        page: index,
        top: math.max(above + (first.top - above) / 2, first.top - space * 7),
        bottom: math.min(last.top + 4 * last.space + (below - last.top - 4 * last.space) / 2, last.top + 4 * last.space + space * 7),
        left: left,
        right: end,
        staves: [for (final s in staves) PdfStaff(top: s.top, space: s.space)],
        cuts: [for (var i = 0; i + 1 < staves.length; i++) _cut(page, staves[i], staves[i + 1], left, end)],
        barlines: barlines,
      ));
    }
    return out;
  }

  /// Where to crop between [above] and [below], from [left] to [right]: the row the least ink
  /// crosses (a stem or a ledger line reaching for the other staff), the middle way breaking ties.
  static double _cut(PdfRaster page, FoundStaff above, FoundStaff below, double left, double right) {
    final from = page.row(above.top + 4 * above.space + above.space * 0.6).round();
    final to = page.row(below.top - below.space * 0.6).round();
    final middle = page.row((above.top + 4 * above.space + below.top) / 2);
    if (to <= from) return page.yOf(middle);
    final x0 = math.max(0, page.col(left).round()), x1 = math.min(page.width - 1, page.col(right).round());
    var best = middle.round(), bestScore = double.infinity;
    for (var y = from; y <= to; y++) {
      var ink = 0;
      for (var x = x0; x <= x1; x++) {
        if (page.isInked(x, y)) ink++;
      }
      // A pixel of ink outweighs being a little off the middle.
      final score = ink + (y - middle).abs() / (to - from + 1);
      if (score < bestScore) {
        bestScore = score;
        best = y;
      }
    }
    return page.yOf(best);
  }

  /// The row from [from] to [to] (points) nearest [near] of those the least ink crosses between
  /// [left] and [right] (a barline through them all aside: give or take a third of a staff
  /// [space]): an edge there cuts through nothing printed.
  static double quietRow(PdfRaster page, double from, double to, double near, double left, double right, {double space = 0}) {
    final a = page.row(math.min(from, to)).round(), b = page.row(math.max(from, to)).round();
    final want = page.row(near);
    final ink = [for (var y = a; y <= b; y++) _inkIn(page, y, left, right)];
    if (ink.isEmpty) return near;
    final least = ink.reduce(math.min), slack = (space * page.scale / 3).round();
    var best = a;
    for (var y = a; y <= b; y++) {
      if (ink[y - a] <= least + slack && ((y - want).abs() < (best - want).abs() || ink[best - a] > least + slack)) best = y;
    }
    return page.yOf(best);
  }

  /// From [from] toward [to] (points, either way): where the ink reaching on from there ends,
  /// before [gap] points with none between [left] and [right] (a barline through them all aside,
  /// give or take a third of [gap]); [from] when none reaches on.
  static double inkEnd(PdfRaster page, double from, double to, double gap, double left, double right) {
    final a = page.row(from).round(), b = page.row(to).round(), step = b >= a ? 1 : -1;
    final ink = [for (var y = a; step > 0 ? y <= b : y >= b; y += step) _inkIn(page, y, left, right)];
    if (ink.isEmpty) return from;
    final least = ink.reduce(math.min), slack = (gap * page.scale / 3).round();
    final clear = math.max(1, (gap * page.scale).round());
    var end = 0, run = 0;
    for (var k = 0; k < ink.length; k++) {
      if (ink[k] > least + slack) {
        end = k;
        run = 0;
      } else if (++run >= clear) {
        break;
      }
    }
    return page.yOf(a + end * step);
  }

  /// How many pixels of row [y] between [left] and [right] (points) are inked.
  static int _inkIn(PdfRaster page, int y, double left, double right) {
    final x0 = math.max(0, page.col(left).round()), x1 = math.min(page.width - 1, page.col(right).round());
    var ink = 0;
    for (var x = x0; x <= x1; x++) {
      if (page.isInked(x, y)) ink++;
    }
    return ink;
  }

  /// The barline nearest [x] (points) within [reach] of it: a vertical line through every line of
  /// most of [staves] (of a lone staff, through its lines). Where the bar changes, as [barlines]
  /// says it (past its right edge); null when no line is there.
  static double? lineNear(PdfRaster page, List<PdfStaff> staves, double x, double reach) {
    if (staves.isEmpty) return null;
    final from = math.max(0, page.col(x - reach).floor()), to = math.min(page.width - 1, page.col(x + reach).ceil());
    final need = staves.length == 1 ? 1 : math.max(2, (staves.length * 0.6).ceil());
    final rows = [for (final s in staves) (page.row(s.top).round(), page.row(s.bottom).round())];
    final through = <int>[];
    for (var c = from; c <= to; c++) {
      var count = 0;
      for (final (top, bottom) in rows) {
        var y = top;
        while (y <= bottom && page.isInked(c, y)) {
          y++;
        }
        if (y > bottom) count++;
      }
      if (count >= need) through.add(c);
    }
    (int, int)? best;
    final want = page.col(x);
    double off((int, int) run) => ((run.$1 + run.$2) / 2 - want).abs();
    for (final run in _runs(through)) {
      if (best == null || off(run) < off(best)) best = run;
    }
    return best == null ? null : page.xOf(best.$2 + 1);
  }

  /// [system]'s staves' ink, per staff and bar: how far it reaches past the lines and whether
  /// anything is played (a notehead, filled or open, or a stem), from its parts ([assign]).
  static List<List<PdfInk>> ink(PdfRaster raster, PdfSystem system, List<ui.Rect> masks,
      {Map<int, List<ui.Rect>> staffMasks = const {}}) {
    final parts = assign(raster, system, masks, staffMasks: staffMasks);
    final segments = system.segments;
    // Ink anyone owns, summed over every rectangle from the top left: a block's ink in four reads.
    final w = raster.width, h = raster.height;
    final sat = Int32List((w + 1) * (h + 1));
    for (var y = 0; y < h; y++) {
      var row = 0;
      for (var x = 0; x < w; x++) {
        final i = y * w + x;
        if (parts.of[i] >= 0 && raster.ink[i] >= PdfRaster.dark) row++;
        sat[(y + 1) * (w + 1) + x + 1] = sat[y * (w + 1) + x + 1] + row;
      }
    }
    return [
      for (final (s, staff) in system.staves.indexed)
        [
          for (final (l, r) in segments) _barInk(raster, parts.of, parts.holding(s), sat, staff, l, r),
        ],
    ];
  }

  /// One staff's ink in the bar from [l] to [r]: the pixels whose owners ([PdfParts.of]) are those
  /// [holds] marks as holding it.
  static PdfInk _barInk(PdfRaster raster, Int16List parts, Uint8List holds, Int32List sat, PdfStaff staff, double l, double r) {
    final w = raster.width, h = raster.height;
    final x0 = math.max(0, raster.col(l + staff.space * 0.4).round()), x1 = math.min(w - 1, raster.col(r - staff.space * 0.4).round());
    final top = raster.row(staff.top), bottom = raster.row(staff.bottom);
    var minY = top, maxY = bottom;
    final px = staff.space * raster.scale;
    final lineRows = <int>{
      for (var k = 0; k < staff.lines; k++)
        for (var d = -(px * 0.08).ceil(); d <= (px * 0.08).ceil(); d++) raster.row(staff.top + k * staff.space).round() + d,
    };
    bool owns(int i) => parts[i] >= 0 && holds[parts[i]] != 0;
    bool mine(int x, int y) => x >= 0 && y >= 0 && x < w && y < h && owns(y * w + x) && raster.ink[y * w + x] >= PdfRaster.dark;
    for (var y = 0; y < h; y++) {
      for (var x = x0; x <= x1; x++) {
        if (mine(x, y)) {
          minY = math.min(minY, y.toDouble());
          maxY = math.max(maxY, y.toDouble());
          break;
        }
      }
    }
    // Played: a filled head (a block 0.5 × 0.72 spaces of ink), a stem (ink straight down 2.5
    // spaces, staff lines counted), or an open head (a hole inside the staff closed left and right).
    var played = false;
    // Taller than a whole or half rest's block (half a space, a staff line on it).
    final bw = math.max(2, (px * 0.5).round()), bh = math.max(3, (px * 0.72).round());
    final y0 = math.max(0, (top - px * 4).round()), y1 = math.min(h - 1, (bottom + px * 4).round());
    final stride = w + 1;
    for (var y = y0; y <= y1 - bh && !played; y++) {
      for (var x = x0; x <= x1 - bw; x++) {
        final sum = sat[(y + bh) * stride + x + bw] - sat[y * stride + x + bw] - sat[(y + bh) * stride + x] + sat[y * stride + x];
        if (sum == bw * bh && owns((y + bh ~/ 2) * w + x + bw ~/ 2)) {
          played = true;
          break;
        }
      }
    }
    final stem = (px * 2.6).round();
    for (var x = x0; x <= x1 && !played; x++) {
      var run = 0;
      for (var y = y0; y <= y1; y++) {
        if (mine(x, y) || (lineRows.contains(y) && run > 0)) {
          if (++run >= stem && !mine(x - (px * 0.5).round(), y) && !mine(x + (px * 0.5).round(), y)) {
            played = true;
            break;
          }
        } else {
          run = 0;
        }
      }
    }
    for (var y = top.round(); y <= bottom.round() && !played; y++) {
      if (lineRows.contains(y)) continue;
      for (var x = x0; x <= x1; x++) {
        if (mine(x, y)) continue;
        // A hole: ink within 0.65 spaces left and right, and up and down.
        int reach(int dx, int dy) {
          for (var d = 1; d <= px * 0.65; d++) {
            if (mine(x + dx * d, y + dy * d)) return d;
          }
          return 0;
        }

        final a = reach(-1, 0), b = reach(1, 0);
        if (a == 0 || b == 0 || a + b < px * 0.5) continue;
        if (reach(0, -1) > 0 && reach(0, 1) > 0) {
          played = true;
          break;
        }
      }
    }
    return (above: math.max(0, (top - minY) / px), below: math.max(0, (maxY - bottom) / px), played: played);
  }

  /// Whose each pixel of [raster] (a part of [system]'s page) is ([PdfParts]): what is under a
  /// mask, outside every staff's region ([PdfSystem.regionOf]) or outside the system is no one's;
  /// a staff's lines are its own, inside its region; every other mark is the staff's whose region
  /// holds it whole, both's where two regions overlap round it, else goes whole to the staff whose
  /// region holds most of it; but one that runs through the lines of two staves or more (a
  /// barline, a beam across them) is cut, each pixel going to the staff whose region it is in
  /// (where they overlap, the one whose lines are nearest: [PdfSystem.staffAt]). [masks] in
  /// points; [staffMasks] (by staff index) are one staff's: what is under them is no one's where
  /// it would have been that staff's.
  static PdfParts assign(PdfRaster raster, PdfSystem system, List<ui.Rect> masks,
      {Map<int, List<ui.Rect>> staffMasks = const {}}) {
    final w = raster.width, h = raster.height, ink = raster.ink;
    final sets = <List<int>>[];
    final setIndex = <String, int>{};
    int setOf(List<int> staves) => setIndex.putIfAbsent(staves.join(' '), () {
          sets.add(List.unmodifiable(staves));
          return sets.length - 1;
        });
    final out = Int16List(w * h)..fillRange(0, w * h, -1);
    final n = system.staves.length;
    if (n == 0) return PdfParts(out, sets);
    // Each staff's region in pixels, its rows and columns from the first to the first past it,
    // and its lines' rows; the regions each row is in (mostly one, two where they overlap).
    final rowFrom = Int32List(n), rowTo = Int32List(n), colFrom = Int32List(n), colTo = Int32List(n);
    final linesFrom = Float64List(n), linesTo = Float64List(n);
    for (final (k, s) in system.staves.indexed) {
      final r = system.regionOf(k);
      rowFrom[k] = (raster.row(r.top) - 0.5).ceil().clamp(0, h);
      rowTo[k] = math.max(rowFrom[k], (raster.row(r.bottom) - 0.5).ceil().clamp(0, h));
      colFrom[k] = (raster.col(r.left) - 0.5).ceil().clamp(0, w);
      colTo[k] = math.max(colFrom[k], ((raster.col(r.right) - 0.5).floor() + 1).clamp(0, w));
      linesFrom[k] = raster.row(s.top);
      linesTo[k] = raster.row(s.bottom);
    }
    final inRows = List<List<int>>.generate(h, (y) => [
          for (var k = 0; k < n; k++)
            if (y >= rowFrom[k] && y < rowTo[k]) k,
        ]);
    bool inside(int k, int x) => x >= colFrom[k] && x < colTo[k];
    // The staff whose region pixel (x, y) is in; where they overlap, the one whose lines are
    // nearest ([PdfSystem.staffAt]). -1: none's.
    int nearest(int x, int y) {
      var best = -1;
      var off = double.infinity;
      for (final k in inRows[y]) {
        if (!inside(k, x)) continue;
        final d = y + 0.5 < linesFrom[k] ? linesFrom[k] - y - 0.5 : math.max(0.0, y + 0.5 - linesTo[k]);
        if (d < off) {
          off = d;
          best = k;
        }
      }
      return best;
    }

    final single = [for (var k = 0; k < n; k++) setOf([k])];
    final blocked = Uint8List(w * h);
    for (final m in masks) {
      // (A mask right of what was read starts at its edge: past it, the last row's would start
      // past the end.)
      final x0 = raster.col(m.left).floor().clamp(0, w), x1 = math.min(w, raster.col(m.right).ceil());
      final y0 = math.max(0, raster.row(m.top).floor()), y1 = math.min(h, raster.row(m.bottom).ceil());
      for (var y = y0; y < y1; y++) {
        blocked.fillRange(y * w + x0, y * w + math.max(x0, x1), 1);
      }
    }
    final xLeft = raster.col(system.left - system.space * 0.3), xRight = raster.col(system.right + system.space * 0.5);
    // Staff lines: thin runs of rows on a line's place, given to the staff straight away.
    final lineOf = Int8List(h)..fillRange(0, h, -1);
    final lineHalf = Int32List(h);
    for (final (i, staff) in system.staves.indexed) {
      final half = math.max(1, (staff.space * raster.scale * 0.12).ceil());
      for (var k = 0; k < staff.lines; k++) {
        final y = raster.row(staff.top + k * staff.space).round();
        for (var d = -half; d <= half; d++) {
          if (y + d >= 0 && y + d < h) {
            lineOf[y + d] = i;
            lineHalf[y + d] = half;
          }
        }
      }
    }
    bool isLine(int x, int y) {
      if (lineOf[y] < 0) return false;
      // Ink only a line's thickness tall here.
      final half = lineHalf[y];
      var up = 0, down = 0;
      while (y - up - 1 >= 0 && ink[(y - up - 1) * w + x] >= PdfRaster.dark && up <= 2 * half + 1) {
        up++;
      }
      while (y + down + 1 < h && ink[(y + down + 1) * w + x] >= PdfRaster.dark && down <= 2 * half + 1) {
        down++;
      }
      return up + down <= 2 * half + 1;
    }

    // Union-find over the rest of the ink, 8-connected.
    final label = Int32List(w * h)..fillRange(0, w * h, -1);
    final parent = <int>[];
    int find(int a) {
      while (parent[a] != a) {
        parent[a] = parent[parent[a]];
        a = parent[a];
      }
      return a;
    }

    void union(int a, int b) {
      a = find(a);
      b = find(b);
      if (a != b) parent[math.max(a, b)] = math.min(a, b);
    }

    for (var y = 0; y < h; y++) {
      final rows = inRows[y];
      if (rows.isEmpty) continue;
      for (var x = math.max(0, xLeft.floor()); x < math.min(w, xRight.ceil()); x++) {
        final i = y * w + x;
        if (ink[i] < PdfRaster.dark || blocked[i] != 0 || !rows.any((k) => inside(k, x))) continue;
        if (isLine(x, y)) {
          if (inside(lineOf[y], x) && rows.contains(lineOf[y])) out[i] = single[lineOf[y]];
          continue;
        }
        var l = -1;
        for (final j in [i - 1, i - w - 1, i - w, i - w + 1]) {
          if (j < 0 || (j % w - x).abs() > 1) continue;
          final lj = label[j];
          if (lj < 0) continue;
          if (l < 0) {
            l = lj;
          } else {
            union(l, lj);
          }
        }
        if (l < 0) {
          l = parent.length;
          parent.add(l);
        }
        label[i] = l;
      }
    }
    // Each mark: its ink in each region, its rows and columns, and which staves' lines it crosses.
    final count = parent.length;
    final perBand = Int32List(count * n);
    final top = Int32List(count)..fillRange(0, count, h), bottom = Int32List(count)..fillRange(0, count, -1);
    final left = Int32List(count)..fillRange(0, count, w), right = Int32List(count)..fillRange(0, count, -1);
    final crosses = List<int>.filled(count, 0); // bit per staff whose line zone it reaches
    final zoneOf = Int8List(h)..fillRange(0, h, -1);
    for (final (i, staff) in system.staves.indexed) {
      for (var y = math.max(0, raster.row(staff.top).round()); y <= math.min(h - 1, raster.row(staff.bottom).round()); y++) {
        zoneOf[y] = i;
      }
    }
    for (var y = 0; y < h; y++) {
      final rows = inRows[y];
      for (var x = 0; x < w; x++) {
        final l = label[y * w + x];
        if (l < 0) continue;
        final root = find(l);
        label[y * w + x] = root;
        for (final b in rows) {
          if (inside(b, x)) perBand[root * n + b]++;
        }
        if (y < top[root]) top[root] = y;
        if (y > bottom[root]) bottom[root] = y;
        if (x < left[root]) left[root] = x;
        if (x > right[root]) right[root] = x;
        if (zoneOf[y] >= 0 && zoneOf[y] < 30) crosses[root] |= 1 << zoneOf[y];
      }
    }
    // Its owners: -1, split by row.
    final owner = Int32List(count)..fillRange(0, count, -1);
    for (var root = 0; root < count; root++) {
      if (parent[root] != root) continue;
      if (crosses[root] & (crosses[root] - 1) != 0) continue;
      final whole = [
        for (var b = 0; b < n; b++)
          if (top[root] >= rowFrom[b] && bottom[root] < rowTo[b] && left[root] >= colFrom[b] && right[root] < colTo[b]) b,
      ];
      if (whole.isNotEmpty) {
        owner[root] = whole.length == 1 ? single[whole.single] : setOf(whole);
        continue;
      }
      var best = 0, most = -1;
      for (var b = 0; b < n; b++) {
        final c = perBand[root * n + b];
        if (c > most) {
          most = c;
          best = b;
        }
      }
      owner[root] = single[best];
    }
    // Light ink around marks (anti-aliasing) goes with the region it is in, as does a split mark.
    int where(int x, int y) => switch (nearest(x, y)) { < 0 => -1, final k => single[k] };
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = y * w + x;
        if (out[i] >= 0 || blocked[i] != 0 || ink[i] == 0) continue;
        final l = label[i];
        if (l >= 0) {
          final o = owner[l];
          out[i] = o >= 0 ? o : where(x, y);
        } else if (x >= xLeft && x < xRight) {
          // Next to a mark: its owners, so its edge goes with it.
          var o = -1;
          for (final j in [i - 1, i + 1, i - w, i + w]) {
            if (j < 0 || j >= w * h) continue;
            final lj = label[j];
            if (lj >= 0 && owner[lj] >= 0) {
              o = owner[lj];
              break;
            }
          }
          out[i] = o >= 0 ? o : where(x, y);
        }
      }
    }
    for (final MapEntry(key: staff, value: rects) in staffMasks.entries) {
      // Each set of owners without the staff.
      final without = <int, int>{};
      int less(int set) => without.putIfAbsent(set, () {
            final rest = [for (final s in sets[set]) if (s != staff) s];
            return rest.isEmpty ? -1 : setOf(rest);
          });
      for (final m in rects) {
        final x0 = math.max(0, raster.col(m.left).floor()), x1 = math.min(w, raster.col(m.right).ceil());
        final y0 = math.max(0, raster.row(m.top).floor()), y1 = math.min(h, raster.row(m.bottom).ceil());
        for (var y = y0; y < y1; y++) {
          for (var x = x0; x < x1; x++) {
            final i = y * w + x;
            if (out[i] >= 0 && sets[out[i]].contains(staff)) out[i] = less(out[i]);
          }
        }
      }
    }
    return PdfParts(out, sets);
  }

  /// A system's slots (a staff alone, or two a brace joins: each its staves' [signature]s) given
  /// to [instruments] (each its staves' signatures, as the system with the most staves has them),
  /// keeping their order: each slot an instrument and which of its staves it starts at (from 0),
  /// or null for no one's. A pair goes only to a two-staff instrument, whole; a lone staff to any
  /// staff (one of a piano's, its other hidden), or to the one-staff instrument the slot above
  /// went to (a section divided onto two staves: divisi). The assignment that looks most alike
  /// wins.
  static List<(int, int)?> match(List<List<List<double>>> slots, List<List<List<double>>> instruments) {
    final targets = [
      for (final (k, staves) in instruments.indexed)
        for (final (j, look) in staves.indexed) (k, j, look, staves.length),
    ];
    final n = slots.length, t = targets.length;
    // best[i][m]: the best score with the first i slots placed on the first m targets.
    final best = List.generate(n + 1, (_) => List<double>.filled(t + 1, double.negativeInfinity));
    // 0 skip target, 1 skip slot, 2 one, 3 two, 4 the target before again (divisi)
    final how = List.generate(n + 1, (_) => List<int>.filled(t + 1, 0));
    for (var m = 0; m <= t; m++) {
      best[0][m] = 0;
    }
    for (var i = 1; i <= n; i++) {
      final slot = slots[i - 1];
      best[i][0] = best[i - 1][0] - 1;
      how[i][0] = 1;
      for (var m = 1; m <= t; m++) {
        void offer(double v, int h) {
          if (v > best[i][m]) {
            best[i][m] = v;
            how[i][m] = h;
          }
        }

        offer(best[i][m - 1], 0);
        offer(best[i - 1][m] - 1, 1);
        final (_, j, look, count) = targets[m - 1];
        if (slot.length == 1) {
          offer(best[i - 1][m - 1] + similarity(slot[0], look) - (count > 1 ? 0.1 : 0), 2);
          // Divisi: the slot above took this one-staff target too.
          if (i >= 2 && count == 1 && slots[i - 2].length == 1 && how[i - 1][m] >= 2 && how[i - 1][m] != 3) {
            offer(best[i - 1][m] + similarity(slot[0], look) - 0.35, 4);
          }
        } else if (slot.length == 2 && count == 2 && j == 1 && m >= 2) {
          final upper = targets[m - 2];
          offer(best[i - 1][m - 2] + (similarity(slot[0], upper.$3) + similarity(slot[1], look)) / 2, 3);
        }
      }
    }
    final out = List<(int, int)?>.filled(n, null);
    for (var i = n, m = t; i > 0;) {
      switch (how[i][m]) {
        case 0:
          m--;
        case 1:
          i--;
        case 2:
          out[i - 1] = (targets[m - 1].$1, targets[m - 1].$2);
          i--;
          m--;
        case 4:
          out[i - 1] = (targets[m - 1].$1, targets[m - 1].$2);
          i--;
        default:
          out[i - 1] = (targets[m - 1].$1, 0);
          i--;
          m -= 2;
      }
    }
    return out;
  }

  /// How alike two [signature]s are, 0 to 1.
  static double similarity(List<double> a, List<double> b) {
    if (a.isEmpty || b.isEmpty || a.length != b.length) return 0;
    var dot = 0.0, na = 0.0, nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    return na == 0 || nb == 0 ? (na == nb ? 1 : 0) : dot / math.sqrt(na * nb);
  }

  /// What a staff's start looks like (its clef and key signature, and the name beside it): ink on
  /// a grid of quarter staff spaces, from [name] spaces left of its lines to 9 spaces into them,
  /// two spaces above and below. Staves of one instrument look alike from system to system.
  static List<double> signature(PdfRaster page, PdfStaff staff, double staffLeft, {double name = 0}) {
    const step = 0.25;
    final out = <double>[];
    for (var gy = -2.0; gy < 6; gy += step) {
      for (var gx = -name; gx < 9; gx += step) {
        final x0 = page.col(staffLeft + gx * staff.space).floor(), y0 = page.row(staff.top + gy * staff.space).floor();
        final cell = math.max(1, (step * staff.space * page.scale).round());
        var sum = 0;
        for (var dy = 0; dy < cell; dy++) {
          for (var dx = 0; dx < cell; dx++) {
            if (page.isDark(x0 + dx, y0 + dy)) sum++;
          }
        }
        out.add(sum / (cell * cell));
      }
    }
    return out;
  }
}
