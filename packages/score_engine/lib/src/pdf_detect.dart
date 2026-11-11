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
  /// signature at their left (points). Each staff's own start is looked for, and the furthest
  /// is the system's (the staff with the most sharps or flats): staves in different keys have
  /// their accidentals where another's are not, and a tie held over from the last system fills
  /// the way from a clef to its first note, so all their ink together is one long mark. When no
  /// staff's is sure, what their ink together says.
  static double musicStart(PdfRaster page, List<FoundStaff> staves) {
    final whole = _start(page, staves, staves);
    if (staves.length == 1) return whole.$1;
    // How far past its own lines' start each staff's music starts: a scan leaning has each
    // staff start a little further along than the one above, and the system's start is where
    // its middle staff's is.
    final each = [
      for (final staff in staves)
        if (_start(page, [staff], staves) case (final x, true)) x - staff.left,
    ];
    final lefts = [for (final staff in staves) staff.left]..sort();
    return each.isEmpty ? whole.$1 : lefts[lefts.length ~/ 2] + each.reduce(math.max);
  }

  /// Where the music starts by the ink of [of] (some of the system's [staves], or all), and
  /// whether that is sure: a clef was found, and it stood apart from what follows it.
  static (double, bool) _start(PdfRaster page, List<FoundStaff> of, List<FoundStaff> staves) {
    final space = staves.map((s) => s.space).reduce(math.min);
    // From where their own lines start: a scan leaning has the lines of one staff start where
    // the system's line still is in another.
    final start = of.map((s) => s.left).reduce(math.min);
    final from = page.col(start + space * 0.4).round(), to = math.min(page.width, page.col(start + space * 22).round());
    if (to <= from) return (start, false);
    // Columns holding ink besides the staff lines, in any staff. A scan's lines are some rows
    // thick, and ragged.
    final inked = List<bool>.filled(to - from, false);
    for (final staff in of) {
      final half = (staff.thickness * page.scale / 2).floor() + 1;
      final lineRows = <int>{
        for (var k = 0; k < 5; k++)
          for (var d = -half; d <= half; d++) page.row(staff.top + k * staff.space).round() + d,
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
    if (glyphs.isEmpty || glyphs.first.$1 > px * 2.5) return (start + space * 0.5, false); // no clef here
    // The clef, then what follows it closely and is no wider than an accidental or a time
    // signature's digits: the key and time signature.
    var end = glyphs.first.$2;
    if (end - glyphs.first.$1 > px * 4.5) return (page.xOf(from + glyphs.first.$1) + space * 3.2, false); // run into the music
    final clef = end, own = of.length == 1 ? of.first : null;
    for (final (a, b) in glyphs.skip(1).take(10)) {
      if (b - a > px * 2.6) break;
      // The key's accidentals close together (the first a little further from the clef in
      // some engraving, when it is as tall as an accidental and no taller: a note's stem is, its
      // head alone is not); a time signature can stand a little apart, alike in every staff. A
      // note's head, filled, is no accidental however close.
      final time = _signatureLike(page, staves, from + a, from + b, of: own, whole: true);
      final near = a - end <= px * 1.15 || (end == clef && a - end <= px * 2 && _accidentalLike(page, of, from + a, from + b));
      if (!near && !time && (a - end > px * 4 || !_signatureLike(page, staves, from + a, from + b, of: own))) break;
      if (!time && _headIn(page, of, from + a, from + b)) break;
      end = b;
      // Two digits filling the staff, in every staff: the time signature, which is the last.
      if (time && staves.length > 1) break;
    }
    // Seven accidentals and a time signature are twelve spaces: more is notes close together.
    if (end - clef > px * 13) return (page.xOf(from + clef) + space * 0.5, false);
    final next = glyphs.where((g) => g.$1 > end).firstOrNull;
    final gap = next == null ? px : math.min(px, (next.$1 - end) / 2);
    return (page.xOf(from + end + gap), true);
  }

  /// Whether what columns [a]–[b] hold in [staves] is as tall as an accidental: two staff spaces
  /// to a little over three, and at least half a space wide.
  static bool _accidentalLike(PdfRaster page, List<FoundStaff> staves, int a, int b) {
    for (final staff in staves) {
      final px = staff.space * page.scale;
      final half = (staff.thickness * page.scale / 2).floor() + 1;
      final lineRows = <int>{
        for (var k = 0; k < 5; k++)
          for (var d = -half; d <= half; d++) page.row(staff.top + k * staff.space).round() + d,
      };
      final top = page.row(staff.top - staff.space * 2).round(), bottom = page.row(staff.top + staff.space * 6).round();
      int? lo, hi, left, right;
      for (var y = top; y <= bottom; y++) {
        if (lineRows.contains(y)) continue;
        for (var x = a; x <= b; x++) {
          if (!page.isDark(x, y)) continue;
          lo ??= y;
          hi = y;
          left = left == null ? x : math.min(left, x);
          right = right == null ? x : math.max(right, x);
        }
      }
      if (lo == null) continue;
      final tall = (hi! - lo + 1) / px;
      if (tall < 1.8 || tall > 3.2 || right! - left! + 1 < px * 0.5) return false;
    }
    return true;
  }

  /// Whether columns [a]–[b] hold a filled notehead in one of [staves]: rows of ink over a staff
  /// space wide, one under the other for two fifths of a space (a sharp's bars are thinner, a
  /// flat's bowl hollow), the staff's lines aside.
  static bool _headIn(PdfRaster page, List<FoundStaff> staves, int a, int b) {
    for (final staff in staves) {
      final px = staff.space * page.scale;
      final half = (staff.thickness * page.scale / 2).floor() + 1;
      final lineRows = <int>{
        for (var k = 0; k < 5; k++)
          for (var d = -half; d <= half; d++) page.row(staff.top + k * staff.space).round() + d,
      };
      final top = page.row(staff.top - staff.space * 2).round(), bottom = page.row(staff.top + staff.space * 6).round();
      var rows = 0;
      for (var y = top; y <= bottom; y++) {
        if (lineRows.contains(y)) continue;
        var run = 0, longest = 0;
        for (var x = a; x <= b; x++) {
          run = page.isDark(x, y) ? run + 1 : 0;
          if (run > longest) longest = run;
        }
        rows = longest >= px * 1.05 ? rows + 1 : 0;
        if (rows >= px * 0.4) return true;
      }
    }
    return false;
  }

  /// Whether columns [a]–[b] hold a time signature: ink within every staff's lines (or most of
  /// them), alike from staff to staff, at least two spaces tall; [whole]: from its top line to
  /// its bottom one (two digits, one over the other). The columns are [of]'s, when given: each
  /// other staff's as far from where its own lines start.
  static bool _signatureLike(PdfRaster page, List<FoundStaff> staves, int a, int b, {FoundStaff? of, bool whole = false}) {
    final extents = <(double, double)>[];
    var inked = 0;
    for (final staff in staves) {
      final px = staff.space * page.scale;
      final half = (staff.thickness * page.scale / 2).floor() + 1;
      final lineRows = <int>{
        for (var k = 0; k < 5; k++)
          for (var d = -half; d <= half; d++) page.row(staff.top + k * staff.space).round() + d,
      };
      final top = page.row(staff.top - staff.space * 1.5).round(), bottom = page.row(staff.top + staff.space * 5.5).round();
      // As far along this staff as [a]–[b] are along [of]'s (a scan leaning).
      final along = of == null ? 0 : ((staff.left - of.left) * page.scale).round();
      double? lo, hi;
      for (var y = top; y <= bottom; y++) {
        if (lineRows.contains(y)) continue;
        for (var x = a + along; x <= b + along; x++) {
          if (page.isDark(x, y)) {
            final at = (y - page.row(staff.top)) / px;
            lo ??= at;
            hi = at;
            break;
          }
        }
      }
      // (a speck is no ink: a staff whose lines were found to start a little off has its digits
      // beside these columns)
      if (lo == null || (of != null && hi! - lo < 0.5)) continue;
      inked++;
      if (lo < -0.4 || hi! > 4.4 || hi - lo < 1.5) return false;
      extents.add((lo, hi));
    }
    if (inked < math.max(1, (staves.length * 0.7).ceil())) return false;
    final los = [for (final e in extents) e.$1]..sort(), his = [for (final e in extents) e.$2]..sort();
    final lo = los[los.length ~/ 2], hi = his[his.length ~/ 2];
    if (whole && (lo > 0.6 || hi < 3.4)) return false;
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
  /// vertical line through every line of a staff, found again in most of its staves where a
  /// barline would be there (a scan's barlines lean, each staff's a little further along than the
  /// one above's), and a barline in each: joined to the next staff's, or standing alone (no
  /// notehead on it, ending at the staff). Stems one under the other in a tutti are neither.
  static List<PdfBarline> barlines(PdfRaster page, List<FoundStaff> staves, double musicLeft) {
    final space = staves.map((s) => s.space).reduce(math.min);
    final px = space * page.scale;
    final right = staves.map((s) => s.right).reduce(math.max);
    final from = math.max(0, page.col(musicLeft - space * 0.8).round()), to = math.min(page.width - 1, page.col(right + space).round());
    final n = staves.length;
    final tops = [for (final s in staves) page.row(s.top).round()], bottoms = [for (final s in staves) page.row(s.top + 4 * s.space).round()];
    // Per staff, the lines through all its lines, no wider than a barline (a beam's end, a
    // cluster are): the columns each starts at, and those it ends at.
    final lines = <({int staff, int l, int r, int bl, int br})>[];
    for (var i = 0; i < n; i++) {
      final lead = (staves[i].thickness * page.scale).ceil() + 2, lean = math.max(1, ((bottoms[i] - tops[i]) * 0.05).ceil());
      int? start, last, bl, br;
      void close() {
        if (start != null && last! - start! <= px * 0.7 && _thin(page, staves[i], start!, last)) {
          lines.add((staff: i, l: start!, r: last, bl: bl!, br: br!));
        }
        start = null;
      }

      for (var x = from; x <= to; x++) {
        final end = _down(page, x, tops[i], bottoms[i], lead: lead, lean: lean, gap: (px * 0.12).round());
        if (end == null) {
          close();
          continue;
        }
        if (start == null) {
          start = x;
          bl = end;
        }
        last = x;
        br = end;
      }
      close();
    }
    double mid(({int staff, int l, int r, int bl, int br}) line) => (line.l + line.r + line.bl + line.br) / 4;
    double middle(int staff) => (tops[staff] + bottoms[staff]) / 2;
    // Which lines a line between the staves joins.
    final group = [for (var k = 0; k < lines.length; k++) k];
    int find(int k) {
      while (group[k] != k) {
        k = group[k] = group[group[k]];
      }
      return k;
    }

    final joined = List<bool>.filled(lines.length, false);
    final byStaff = [for (var i = 0; i < n; i++) [for (final (k, line) in lines.indexed) if (line.staff == i) k]];
    for (var i = 0; i + 1 < n; i++) {
      final rows = tops[i + 1] - bottoms[i];
      if (rows <= 0) continue;
      final lead = (staves[i].thickness * page.scale).ceil() + 2, lean = math.max(1, (rows * 0.05).ceil()), gap = (px * 0.25).round();
      for (final k in byStaff[i]) {
        for (var x = lines[k].bl; x <= lines[k].br; x++) {
          final end = _down(page, x, bottoms[i], tops[i + 1], lead: lead, lean: lean, gap: gap);
          if (end == null) continue;
          for (final j in byStaff[i + 1]) {
            if (end < lines[j].l - 1 || end > lines[j].r + 1) continue;
            joined[k] = joined[j] = true;
            group[find(k)] = find(j);
          }
        }
      }
    }
    // How far a barline leans from one staff to the next: what most lines' nearest in the staff
    // below say (columns a row).
    final slopes = <double>[];
    for (var i = 0; i + 1 < n; i++) {
      for (final k in byStaff[i]) {
        double? best;
        for (final j in byStaff[i + 1]) {
          final d = mid(lines[j]) - mid(lines[k]);
          if (d.abs() <= px * 0.6 && (best == null || d.abs() < best.abs())) best = d;
        }
        if (best != null) slopes.add(best / (middle(i + 1) - middle(i)));
      }
    }
    slopes.sort();
    final lean = slopes.isEmpty ? 0.0 : slopes[slopes.length ~/ 2];
    // A line where the one above's would be in this staff is the same barline (a staff's whose
    // line is too faint to be found is passed over).
    for (var i = 0; i < n; i++) {
      for (var d = 1; d <= 2 && i + d < n; d++) {
        for (final k in byStaff[i]) {
          final want = mid(lines[k]) + lean * (middle(i + d) - middle(i));
          for (final j in byStaff[i + d]) {
            if ((mid(lines[j]) - want).abs() <= px * 0.3 * d) group[find(k)] = find(j);
          }
        }
      }
    }
    // A barline: found in most staves, and in most a barline (joined to the next staff's, or
    // alone). Where it is: at the system's middle staff, as most of its staves say.
    final need = n == 1 ? 1 : math.max(2, (n * 0.6).ceil());
    final centre = (tops.first + bottoms.last) / 2;
    final found = <({double l, double r, int? first})>[];
    final members = <int, List<int>>{};
    for (var k = 0; k < lines.length; k++) {
      members.putIfAbsent(find(k), () => []).add(k);
    }
    for (final of in members.values) {
      final seen = {for (final k in of) lines[k].staff};
      final sure = {
        for (final k in of)
          if (joined[k] || (n == 1 ? _alone(page, staves[0], lines[k].l, lines[k].r) : _headless(page, staves, lines[k].staff, lines[k].l, lines[k].r)))
            lines[k].staff,
      };
      if (seen.length < need || sure.length < need) continue;
      double at(int k, int x) => x - lean * (middle(lines[k].staff) - centre);
      final ls = [for (final k in of) at(k, (lines[k].l + lines[k].bl) ~/ 2)]..sort();
      final rs = [for (final k in of) at(k, (lines[k].r + lines[k].br + 1) ~/ 2)]..sort();
      found.add((l: ls[ls.length ~/ 2], r: rs[rs.length ~/ 2], first: of.where((k) => lines[k].staff == 0).firstOrNull));
    }
    found.sort((a, b) => a.l.compareTo(b.l));
    // Lines close together are one barline: a double, a final or a repeat's.
    final out = <PdfBarline>[];
    final staff = staves.first;
    // (the first staff's columns of a place at the system's middle)
    int inFirst(double x) => (x + lean * (middle(0) - centre)).round();
    for (var k = 0; k < found.length; k++) {
      var group = [found[k]];
      while (k + 1 < found.length && found[k + 1].l - group.last.r <= px * 0.9) {
        group.add(found[++k]);
      }
      final l = group.first.l, r = group.last.r;
      final firstL = group.first.first == null ? inFirst(l) : lines[group.first.first!].l;
      final firstR = group.last.first == null ? inFirst(r) : lines[group.last.first!].r;
      if (page.xOf(r) < musicLeft + space * 0.6 && out.isEmpty && !_dotsRight(page, staff, firstR)) continue; // the system's start
      final thick = [for (final g in group) g.r - g.l + 1 > math.max(2, px * 0.28)];
      final dotsLeft = _dotsLeft(page, staff, firstL), dotsRight = _dotsRight(page, staff, firstR);
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

  /// Whether what runs through [staff] at columns [l]–[r] is a line: in most rows between the
  /// staff's lines its ink is no wider than that (a time signature's digits, one over the
  /// other, run through a staff too, and are wide most of the way).
  static bool _thin(PdfRaster page, FoundStaff staff, int l, int r) {
    final px = staff.space * page.scale, wide = math.max(2, (px * 0.3).round());
    final half = (staff.thickness * page.scale / 2).floor() + 1;
    final top = page.row(staff.top).round(), bottom = page.row(staff.top + 4 * staff.space).round();
    final lineRows = <int>{
      for (var k = 0; k < 5; k++)
        for (var d = -half; d <= half; d++) page.row(staff.top + k * staff.space).round() + d,
    };
    var rows = 0, fat = 0;
    for (var y = top; y <= bottom; y++) {
      if (lineRows.contains(y)) continue;
      rows++;
      var left = 0, right = 0;
      while (left < wide && page.isDark(l - 1 - left, y)) {
        left++;
      }
      while (right < wide && page.isDark(r + 1 + right, y)) {
        right++;
      }
      if (left == wide || right == wide) fat++;
    }
    return fat <= rows * 0.4;
  }

  /// The column ink starting at column [x] of row [from] ends at in row [to], running down all
  /// the way; null if it doesn't. A scan's line leans a column or so on its way ([lean] columns
  /// at most, and none in its first [lead] rows: beside a line, a staff line's ink is no start
  /// of it), and a faint one has rows missing ([gap] in a row at most).
  static int? _down(PdfRaster page, int x, int from, int to, {required int lead, int lean = 1, int gap = 0}) {
    var at = x, missing = 0;
    for (var y = from; y <= to; y++) {
      if (page.isInked(at, y)) {
        missing = 0;
      } else if (y > from + lead && at + 1 - x <= lean && page.isInked(at + 1, y)) {
        at++;
        missing = 0;
      } else if (y > from + lead && x - (at - 1) <= lean && page.isInked(at - 1, y)) {
        at--;
        missing = 0;
      } else if (++missing > gap) {
        return null;
      }
    }
    return at;
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
    return !_headBeside(page, staff, l, r, top - reach, bottom + reach);
  }

  /// Whether a notehead (or a beam) touches the line at columns [l]–[r] from row [from] to row
  /// [to]: ink beside it, a staff space wide, not on a staff line.
  static bool _headBeside(PdfRaster page, FoundStaff staff, int l, int r, int from, int to) {
    final px = staff.space * page.scale;
    for (final side in [l - 2, r + 2]) {
      for (var y = from; y <= to; y++) {
        var run = 0;
        for (var d = 0; d < px; d++) {
          if (page.isDark(side + (side < l ? -d : d), y)) run++;
        }
        if (run > px * 0.75 && !_onLine(page, staff, y)) return true;
      }
    }
    return false;
  }

  /// Whether the line at columns [l]–[r] of staff [index] of [staves] has no notehead on it, as
  /// far as it goes on above and below the staff (to the next staff at most): a barline whose
  /// way to the next staff is too faint to follow has none, a stem has one at its end.
  static bool _headless(PdfRaster page, List<FoundStaff> staves, int index, int l, int r) {
    final staff = staves[index], px = staff.space * page.scale, reach = (px * 0.8).round();
    final top = page.row(staff.top).round(), bottom = page.row(staff.top + 4 * staff.space).round();
    final least = index == 0 ? top - (px * 8).round() : page.row(staves[index - 1].top + 4 * staves[index - 1].space).round();
    final most = index == staves.length - 1 ? bottom + (px * 8).round() : page.row(staves[index + 1].top).round();
    bool inked(int y) {
      for (var x = l - 1; x <= r + 1; x++) {
        if (page.isInked(x, y)) return true;
      }
      return false;
    }

    var from = top, to = bottom;
    while (from > least && inked(from - 1)) {
      from--;
    }
    while (to < most && inked(to + 1)) {
      to++;
    }
    return !_headBeside(page, staff, l, r, math.max(least, from - reach), math.min(most, to + reach));
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

  /// Whether some row from [from] to [to] (points) has nothing across it between [left] and
  /// [right] but barlines (those at [barlines], x in points: half a staff [space] either side of
  /// each left out), give or take a third of a space of ink: a cut there goes through nothing
  /// printed, so two regions needn't overlap to keep what is theirs.
  static bool clearRow(PdfRaster page, double from, double to, double left, double right,
      {required double space, List<double> barlines = const []}) {
    final a = math.max(0, page.row(math.min(from, to)).round()), b = math.min(page.height - 1, page.row(math.max(from, to)).round());
    final x0 = math.max(0, page.col(left).round()), x1 = math.min(page.width - 1, page.col(right).round());
    if (x1 < x0) return true;
    final skip = Uint8List(x1 - x0 + 1);
    for (final x in barlines) {
      final c0 = math.max(x0, page.col(x - space / 2).floor()), c1 = math.min(x1, page.col(x + space / 2).ceil());
      for (var c = c0; c <= c1; c++) {
        skip[c - x0] = 1;
      }
    }
    final slack = (space * page.scale / 3).round();
    for (var y = a; y <= b; y++) {
      var ink = 0;
      for (var x = x0; x <= x1 && ink <= slack; x++) {
        if (skip[x - x0] == 0 && page.isInked(x, y)) ink++;
      }
      if (ink <= slack) return true;
    }
    return false;
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
    final w = raster.width, h = raster.height, of = parts.of, ink = raster.ink;
    final n = system.staves.length, bars = segments.length;
    // Per staff, the bar each column is in (-1: none's; a bar's columns are [_barColumns]). A
    // staff with a column in two bars (bars out of order, or off the raster) is looked through
    // bar by bar instead ([_barInk]).
    final barOf = [for (var s = 0; s < n; s++) Int32List(w)..fillRange(0, w, -1)];
    final apart = List<bool>.filled(n, true);
    for (final (s, staff) in system.staves.indexed) {
      for (final (b, (l, r)) in segments.indexed) {
        final (x0, x1) = _barColumns(raster, staff, l, r);
        for (var x = x0; x <= x1; x++) {
          if (barOf[s][x] >= 0) apart[s] = false;
          barOf[s][x] = b;
        }
      }
    }
    // The staff a set of owners is, when it is one staff; -1: several.
    final sets = parts.sets, only = Int32List.fromList([for (final set in sets) set.length == 1 ? set.single : -1]);
    // Each staff's first and last row with ink of its own in each bar (-1: none), and ink anyone
    // owns summed over every rectangle from the top left (a block's ink in four reads): both in
    // one pass over the raster.
    final first = Int32List(n * bars)..fillRange(0, n * bars, -1), last = Int32List(n * bars)..fillRange(0, n * bars, -1);
    void reached(int s, int x, int y) {
      final b = barOf[s][x];
      if (b < 0) return;
      if (first[s * bars + b] < 0) first[s * bars + b] = y;
      last[s * bars + b] = y;
    }

    final stride = w + 1;
    final sat = Int32List(stride * (h + 1));
    for (var y = 0, i = 0; y < h; y++) {
      var row = 0;
      final above = y * stride + 1, here = above + stride;
      for (var x = 0; x < w; x++, i++) {
        final set = of[i];
        if (set >= 0 && ink[i] >= PdfRaster.dark) {
          row++;
          final s = only[set];
          if (s >= 0) {
            reached(s, x, y);
          } else {
            for (final s in sets[set]) {
              reached(s, x, y);
            }
          }
        }
        sat[here + x] = sat[above + x] + row;
      }
    }
    return [
      for (final (s, staff) in system.staves.indexed)
        () {
          final holds = parts.holding(s);
          return [
            for (final (b, (l, r)) in segments.indexed)
              _barInk(raster, of, holds, sat, staff, l, r, rows: apart[s] ? (first[s * bars + b], last[s * bars + b]) : null),
          ];
        }(),
    ];
  }

  /// The columns of [raster] a staff's ink is looked for in, in the bar from [l] to [r]: the bar
  /// less what stands on its barlines.
  static (int, int) _barColumns(PdfRaster raster, PdfStaff staff, double l, double r) => (
        math.max(0, raster.col(l + staff.space * 0.4).round()),
        math.min(raster.width - 1, raster.col(r - staff.space * 0.4).round()),
      );

  /// One staff's ink in the bar from [l] to [r]: the pixels whose owners ([PdfParts.of]) are those
  /// [holds] marks as holding it. [rows]: the first and last row with any of it (-1: none), where
  /// they are known.
  static PdfInk _barInk(PdfRaster raster, Int16List parts, Uint8List holds, Int32List sat, PdfStaff staff, double l, double r,
      {(int, int)? rows}) {
    final w = raster.width, h = raster.height;
    final (x0, x1) = _barColumns(raster, staff, l, r);
    final top = raster.row(staff.top), bottom = raster.row(staff.bottom);
    var minY = top, maxY = bottom;
    final px = staff.space * raster.scale;
    final lineRows = <int>{
      for (var k = 0; k < staff.lines; k++)
        for (var d = -(px * 0.08).ceil(); d <= (px * 0.08).ceil(); d++) raster.row(staff.top + k * staff.space).round() + d,
    };
    bool owns(int i) => parts[i] >= 0 && holds[parts[i]] != 0;
    bool mine(int x, int y) => x >= 0 && y >= 0 && x < w && y < h && owns(y * w + x) && raster.ink[y * w + x] >= PdfRaster.dark;
    if (rows case (final first, final last)) {
      if (first >= 0) {
        minY = math.min(minY, first.toDouble());
        maxY = math.max(maxY, last.toDouble());
      }
    } else {
      for (var y = 0; y < h; y++) {
        for (var x = x0; x <= x1; x++) {
          if (mine(x, y)) {
            minY = math.min(minY, y.toDouble());
            maxY = math.max(maxY, y.toDouble());
            break;
          }
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
    // (Rows one after another in the same regions share one list.)
    final inRows = <List<int>>[];
    var last = const <int>[];
    for (var y = 0; y < h; y++) {
      var same = true, count = 0;
      for (var k = 0; k < n; k++) {
        if (y < rowFrom[k] || y >= rowTo[k]) continue;
        if (count >= last.length || last[count] != k) same = false;
        count++;
      }
      if (!same || count != last.length) {
        last = [
          for (var k = 0; k < n; k++)
            if (y >= rowFrom[k] && y < rowTo[k]) k,
        ];
      }
      inRows.add(last);
    }
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

    // The columns ink can be someone's in, and of those the ones in some region of the row's:
    // worked out once for the rows that share their regions.
    final xFrom = math.max(0, xLeft.floor()), xTo = math.min(w, xRight.ceil());
    final inSome = Uint8List(w);
    List<int>? inSomeOf;
    for (var y = 0; y < h; y++) {
      final rows = inRows[y];
      if (rows.isEmpty) continue;
      if (!identical(rows, inSomeOf)) {
        inSome.fillRange(0, w, 0);
        for (final k in rows) {
          inSome.fillRange(colFrom[k], colTo[k], 1);
        }
        inSomeOf = rows;
      }
      final line = lineOf[y], lineHere = line >= 0 && rows.contains(line);
      for (var x = xFrom, i = y * w + xFrom; x < xTo; x++, i++) {
        if (ink[i] < PdfRaster.dark || blocked[i] != 0 || inSome[x] == 0) continue;
        if (isLine(x, y)) {
          if (lineHere && inside(line, x)) out[i] = single[line];
          continue;
        }
        // The marks of the pixels before it that touch it: left, and above left, above and above
        // right.
        var l = x > 0 ? label[i - 1] : -1;
        if (y > 0) {
          for (var j = x > 0 ? i - w - 1 : i - w, to = x + 1 < w ? i - w + 1 : i - w; j <= to; j++) {
            final lj = label[j];
            if (lj < 0) continue;
            if (l < 0) {
              l = lj;
            } else if (l != lj) {
              union(l, lj);
            }
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
      if (rows.isEmpty) continue; // no marks there
      final zone = zoneOf[y] >= 0 && zoneOf[y] < 30 ? 1 << zoneOf[y] : 0;
      for (var x = xFrom, i = y * w + xFrom; x < xTo; x++, i++) {
        final l = label[i];
        if (l < 0) continue;
        final root = find(l);
        label[i] = root;
        for (final b in rows) {
          if (inside(b, x)) perBand[root * n + b]++;
        }
        if (y < top[root]) top[root] = y;
        if (y > bottom[root]) bottom[root] = y;
        if (x < left[root]) left[root] = x;
        if (x > right[root]) right[root] = x;
        crosses[root] |= zone;
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
    // The owners of the mark pixel [j] is of, when it is one and has some; -1: none.
    int ownersAt(int j) {
      if (j < 0 || j >= w * h) return -1;
      final lj = label[j];
      return lj >= 0 ? owner[lj] : -1;
    }

    for (var y = 0; y < h; y++) {
      // (Past the columns ink can be someone's in there is no mark, and nothing next to one.)
      for (var x = xFrom, i = y * w + xFrom; x < xTo; x++, i++) {
        if (ink[i] == 0 || out[i] >= 0 || blocked[i] != 0) continue;
        final l = label[i];
        if (l >= 0) {
          final o = owner[l];
          out[i] = o >= 0 ? o : where(x, y);
        } else if (x >= xLeft && x < xRight) {
          // Next to a mark: its owners, so its edge goes with it.
          var o = ownersAt(i - 1);
          if (o < 0) o = ownersAt(i + 1);
          if (o < 0) o = ownersAt(i - w);
          if (o < 0) o = ownersAt(i + w);
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
