import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'pdf_ai.dart';
import 'pdf_layout.dart';

/// One staff of an exam page ([PdfAiExamPage]): its top and bottom lines (points from the page's
/// top), its instrument's name as printed where it first appears, what is printed beside it on
/// this page, and its clef and key signature (sharps up from 0, flats down).
typedef PdfAiExamStaff = ({double top, double bottom, String name, String printed, PdfClef clef, int key});

/// One page of the exam ([PdfAiExam]) and what a model should read of it: one system, its staves
/// the score's instruments in order (`P1`…). Points from the page's top left.
class PdfAiExamPage {
  const PdfAiExamPage({
    required this.index,
    required this.left,
    required this.right,
    required this.top,
    required this.bottom,
    required this.staves,
    required this.barlines,
    this.time,
    this.tempo,
    this.first = false,
  });

  /// Its page of the exam's PDF, from 0.
  final int index;

  /// Where the system's music starts (past its clefs, keys and time signatures) and ends.
  final double left, right;

  /// Where the system's top may be, and its bottom: between the ink above it (a title) and its own
  /// (a tempo mark), and between its own (a dynamic) and the ink below it (a page number).
  final (double, double) top, bottom;
  final List<PdfAiExamStaff> staves;

  /// Every barline past its start, all single, the one at its end included.
  final List<double> barlines;

  /// The time signature at its start; null: none printed there.
  final PdfMeter? time;

  /// The tempo mark over its first bar, the only one it has; null: none.
  final PdfTempo? tempo;

  /// Whether it is the page the instruments are named from, its staves theirs in order
  /// ([PdfAi.prompt]'s first).
  final bool first;

  /// Its system as the question shows it: each staff numbered ([PdfAi.labels]).
  PdfSystem get system => PdfSystem.cut(
        page: index,
        top: top.$1,
        bottom: bottom.$2,
        left: left,
        right: right,
        staves: [for (final s in staves) PdfStaff(top: s.top, space: (s.bottom - s.top) / 4)],
        barlines: [for (final x in barlines) PdfBarline(x)],
      );

  /// Its staves' middle staff space, points.
  double get space {
    final spaces = [for (final s in staves) (s.bottom - s.top) / 4]..sort();
    return spaces[spaces.length ~/ 2];
  }
}

/// What the exam measures, each the share of its items a model got right: the user's six
/// questions about a page.
enum PdfAiExamPart {
  /// The system's staves kept together, its top and bottom, and a border between each two staves.
  horizontal,

  /// The barlines (vertical borders): where each is, and that it is a plain one.
  barlines,

  /// Whose each staff is, the names printed on the first page and beside each staff on the next.
  names,
  clefs,
  keys,

  /// The tempo mark and its metronome mark, the time signature, and none where there is none.
  tempo,
}

/// How a model did in the exam ([PdfAiExam.score]): each part's share right, 0–1.
class PdfAiExamResult {
  const PdfAiExamResult(this.parts);
  final Map<PdfAiExamPart, double> parts;

  /// The parts' average, 0–1: each counts the same.
  double get accuracy => parts.isEmpty ? 0 : parts.values.fold(0.0, (a, b) => a + b) / parts.length;

  /// As kept in the app's settings, with the exam's [PdfAiExam.version].
  Map<String, Object> toJson() => {
        'version': PdfAiExam.version,
        'parts': {for (final e in parts.entries) e.key.name: (e.value * 1000).round() / 1000},
      };

  /// Null for anything else, or a result of an exam other than this one ([PdfAiExam.version]).
  static PdfAiExamResult? fromJson(Object? json) {
    if (json case {'version': final int v, 'parts': final Map parts} when v == PdfAiExam.version) {
      final out = <PdfAiExamPart, double>{};
      for (final p in PdfAiExamPart.values) {
        if (parts[p.name] case final num n when n >= 0 && n <= 1) {
          out[p] = n.toDouble();
        } else {
          return null;
        }
      }
      return PdfAiExamResult(out);
    }
    return null;
  }

  @override
  String toString() => jsonEncode(toJson());
}

/// The exam a model takes before the PDF import's Read with AI asks it anything: the first two
/// pages of an orchestral score (Beethoven's Ninth, a scan), each asked as Read with AI asks
/// ([PdfAi.prompt], the pictures with the staves numbered), and its answers marked against what
/// the pages print ([score]). Places are measured as Read with AI takes them: through the line its
/// staff places make against the staves' ([PdfAi.fit]), barlines all moved as far as most are
/// off; none counts where Read with AI would take none.
abstract final class PdfAiExam {
  /// Which exam this is: a result of another ([PdfAiExamResult.fromJson]) isn't this one's.
  static const version = 1;

  /// The exam's PDF, in the app's assets.
  static const asset = 'assets/exam/pdf-ai-exam.pdf';

  static const pages = [_first, _second];

  /// The pages' size, points.
  static const size = ui.Size(651, 866.52);

  /// The score's instruments as the question about [page] lists them: unnamed on the page they
  /// are named from (as when a PDF has no text), and as that page names them on the next.
  static List<PdfInstrument> instruments(PdfAiExamPage page) => [
        for (final (k, s) in _first.staves.indexed) PdfInstrument(id: 'P${k + 1}', name: page.first ? 'Staff ${k + 1}' : s.name),
      ];

  /// The question about [page], as Read with AI asks it.
  static String prompt(PdfAiExamPage page) =>
      PdfAi.prompt(instruments: instruments(page), staves: page.staves.length, first: page.first);

  /// [answers] marked, one for each of [pages] (null: one that isn't the JSON asked for, wrong
  /// throughout).
  static PdfAiExamResult score(List<PdfAiPage?> answers) {
    final right = {for (final p in PdfAiExamPart.values) p: 0.0}, of = {for (final p in PdfAiExamPart.values) p: 0.0};
    void mark(PdfAiExamPart part, bool ok) {
      of[part] = of[part]! + 1;
      if (ok) right[part] = right[part]! + 1;
    }

    for (final (i, page) in pages.indexed) {
      final answer = i < answers.length ? answers[i] : null;
      _page(page, answer ?? const PdfAiPage([]), mark, (r, o) {
        right[PdfAiExamPart.barlines] = right[PdfAiExamPart.barlines]! + r;
        of[PdfAiExamPart.barlines] = of[PdfAiExamPart.barlines]! + o;
      });
    }
    return PdfAiExamResult({for (final p in PdfAiExamPart.values) p: of[p]! == 0 ? 0 : right[p]! / of[p]!});
  }

  static void _page(PdfAiExamPage page, PdfAiPage answer, void Function(PdfAiExamPart, bool) mark,
      void Function(double right, double of) barlines) {
    final view = PdfAiView(size), n = page.staves.length, space = page.space;
    final staves = [for (var k = 1; k <= n; k++) answer.staff(k)];
    // The system that has its staves, the most of them.
    final systems = answer.systems.where((s) => s.staves.isNotEmpty).toList();
    final main = systems.fold<PdfAiSystem?>(
        null, (best, s) => best == null || s.staves.length > best.staves.length ? s : best);

    // Horizontal borders: one system, all of it; its edges and borders as Read with AI places
    // them, none where its staff places are no good.
    final labels = {for (final s in systems) for (final t in s.staves) t.label};
    mark(PdfAiExamPart.horizontal, systems.length == 1 && [for (var k = 1; k <= n; k++) k].every(labels.contains));
    final fit = PdfAi.fit([
      for (final (k, t) in staves.indexed)
        if (t?.y case final y?) (view.y(y), (page.staves[k].top + page.staves[k].bottom) / 2),
    ], n, space);
    double? down(double? thousandths) => thousandths == null || !fit.sure ? null : view.y(thousandths) * fit.scale + fit.shift;
    bool within(double? y, double from, double to) => y != null && y >= from && y <= to;
    final margin = space * 0.5;
    mark(PdfAiExamPart.horizontal, within(down(systems.firstOrNull?.top), page.top.$1 - margin, page.top.$2 + margin));
    mark(PdfAiExamPart.horizontal, within(down(systems.lastOrNull?.bottom), page.bottom.$1 - margin, page.bottom.$2 + margin));
    for (var k = 1; k < n; k++) {
      final border = [for (final s in systems) ...s.borders].where((b) => b.below == k).firstOrNull;
      final ys = [
        ?border?.y,
        if (border?.gap case (final a, final b)) ...[a, b],
      ];
      final from = page.staves[k - 1].bottom, to = page.staves[k].top;
      mark(PdfAiExamPart.horizontal, ys.isNotEmpty && ys.every((y) => within(down(y), from, to)));
    }

    // Barlines: in order, all moved as far as most are off.
    final given = [for (final b in main?.barlines ?? const <({double x, PdfBarlineKind? kind})>[]) (x: view.x(b.x), kind: b.kind)]
      ..sort((a, b) => a.x.compareTo(b.x));
    final matched = _barlines(page.barlines, given, reach: math.max(space * 6, (page.right - page.left) * 0.06), near: space * 2);
    barlines(matched * 2.0, (page.barlines.length + given.length).toDouble());

    // Names, clefs and keys, staff by staff; a change where there is none is wrong.
    for (final (k, expected) in page.staves.indexed) {
      final t = staves[k];
      mark(PdfAiExamPart.names, t != null && t.instrument?.toUpperCase() == 'P${k + 1}' && t.staff == 1);
      mark(PdfAiExamPart.names, t != null && (page.first ? _same(t.name, expected.name) : _same(t.printed, expected.printed)));
      mark(PdfAiExamPart.clefs, t != null && t.clef == expected.clef && t.changes.every((c) => c.clef == null));
      mark(PdfAiExamPart.keys, t != null && t.key == expected.key && t.changes.every((c) => c.key == null));
    }

    // Tempo and time: what is printed, and nothing where nothing is.
    final tempos = [for (final s in systems) ...s.tempos];
    final time = systems.firstOrNull?.time, times = [for (final s in systems) ...s.times];
    if (page.tempo case final expected?) {
      mark(PdfAiExamPart.tempo, tempos.isNotEmpty && tempos.every((t) => t.bar == 1 && _same(t.tempo.words, expected.words, slack: 0.2)));
      mark(PdfAiExamPart.tempo, tempos.any((t) => t.bar == 1 && t.tempo.bpm != null && (t.tempo.bpm! - expected.bpm!).abs() < 1));
    } else {
      mark(PdfAiExamPart.tempo, systems.isNotEmpty && tempos.isEmpty);
    }
    mark(PdfAiExamPart.tempo, systems.isNotEmpty && time == page.time && times.isEmpty);
  }

  /// How many of [expected] (x, points) are paired, in order, with one [given] of the plain kind
  /// within [near] of it, the given all moved as far as most pairs say (no further than [reach]).
  static int _barlines(List<double> expected, List<({double x, PdfBarlineKind? kind})> given,
      {required double reach, required double near}) {
    int pairs(double shift) {
      var count = 0, j = 0;
      for (final x in expected) {
        while (j < given.length && given[j].x + shift < x - near) {
          j++;
        }
        if (j < given.length && (given[j].x + shift - x).abs() <= near) {
          if (given[j].kind == null || given[j].kind == PdfBarlineKind.normal) count++;
          j++;
        }
      }
      return count;
    }

    var best = pairs(0);
    for (final x in expected) {
      for (final g in given) {
        final shift = x - g.x;
        if (shift.abs() <= reach) best = math.max(best, pairs(shift));
      }
    }
    return best;
  }

  /// Whether [said] is [printed] as compared: letters and digits, any case, ♭ and ♯ as b and #,
  /// a slip in every few letters forgiven ([slack] of them, rounded down).
  static bool _same(String said, String printed, {double slack = 0.15}) {
    String plain(String s) =>
        s.toLowerCase().replaceAll('♭', 'b').replaceAll('♯', '#').replaceAll(RegExp(r'[^\p{L}\p{N}#]', unicode: true), '');
    final a = plain(said), b = plain(printed);
    return _distance(a, b) <= (b.length * slack).floor();
  }

  /// The fewest letters put in, taken out or changed to make [a] [b].
  static int _distance(String a, String b) {
    var row = [for (var j = 0; j <= b.length; j++) j];
    for (var i = 1; i <= a.length; i++) {
      final next = [i, ...List.filled(b.length, 0)];
      for (var j = 1; j <= b.length; j++) {
        next[j] = math.min(math.min(next[j - 1] + 1, row[j] + 1), row[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));
      }
      row = next;
    }
    return row[b.length];
  }

  // The pages, as measured on a 300 dpi render of the scan (each staff's five lines; barlines
  // through all thirteen staves, at the system's middle: the scan leans a few points).

  static const _first = PdfAiExamPage(
    index: 0,
    first: true,
    left: 163,
    right: 598.6,
    top: (176, 287), // the title's foot, the tempo mark's head
    bottom: (795.6, 810.7), // the bracket's foot, the page number's head
    staves: [
      (top: 310.2, bottom: 324.8, name: 'Flauti', printed: 'Flauti.', clef: PdfClef.treble, key: -1),
      (top: 345.2, bottom: 360.1, name: 'Oboi', printed: 'Oboi.', clef: PdfClef.treble, key: -1),
      (top: 380.4, bottom: 395.0, name: 'Clarinetti in B', printed: 'Clarinetti in B.', clef: PdfClef.treble, key: 1),
      (top: 415.1, bottom: 429.8, name: 'Fagotti', printed: 'Fagotti.', clef: PdfClef.bass, key: -1),
      (top: 456.4, bottom: 471.1, name: 'Corni in D', printed: 'Corni in D.', clef: PdfClef.treble, key: 0),
      (top: 491.3, bottom: 505.9, name: 'Corni in B basso', printed: 'Corni in B basso', clef: PdfClef.treble, key: 0),
      (top: 526.2, bottom: 540.8, name: 'Trombe in D', printed: 'Trombe in D.', clef: PdfClef.treble, key: 0),
      (top: 561.0, bottom: 575.3, name: 'Timpani in D.A.', printed: 'Timpani in D.A.', clef: PdfClef.bass, key: 0),
      (top: 611.4, bottom: 625.9, name: 'Violino I', printed: 'Violino I.', clef: PdfClef.treble, key: -1),
      (top: 649.1, bottom: 664.1, name: 'Violino II', printed: 'Violino II.', clef: PdfClef.treble, key: -1),
      (top: 688.1, bottom: 702.7, name: 'Viola', printed: 'Viola.', clef: PdfClef.alto, key: -1),
      (top: 726.8, bottom: 741.5, name: 'Violoncello', printed: 'Violoncello.', clef: PdfClef.bass, key: -1),
      (top: 764.8, bottom: 779.7, name: 'Basso', printed: 'Basso.', clef: PdfClef.bass, key: -1),
    ],
    barlines: [228.0, 274.2, 325.2, 373.6, 411.7, 466.2, 517.0, 563.7, 598.6],
    time: PdfMeter('2', 4),
    tempo: PdfTempo('Allegro ma non troppo, un poco maestoso.', 88),
  );

  static const _second = PdfAiExamPage(
    index: 1,
    left: 106,
    right: 598.2,
    top: (0, 32.4), // the page's head, the highest note's
    bottom: (795.4, 816.5), // the bracket's foot, the running foot's head
    staves: [
      (top: 57.7, bottom: 72.2, name: 'Flauti', printed: 'Fl.', clef: PdfClef.treble, key: -1),
      (top: 111.5, bottom: 126.0, name: 'Oboi', printed: 'Ob.', clef: PdfClef.treble, key: -1),
      (top: 164.9, bottom: 179.6, name: 'Clarinetti in B', printed: 'Cl.', clef: PdfClef.treble, key: 1),
      (top: 218.4, bottom: 233.2, name: 'Fagotti', printed: 'Fag.', clef: PdfClef.bass, key: -1),
      (top: 287.6, bottom: 302.5, name: 'Corni in D', printed: 'Cor. D.', clef: PdfClef.treble, key: 0),
      (top: 345.1, bottom: 359.8, name: 'Corni in B basso', printed: 'Cor. B.', clef: PdfClef.treble, key: 0),
      (top: 402.4, bottom: 417.2, name: 'Trombe in D', printed: 'Tr.', clef: PdfClef.treble, key: 0),
      (top: 460.0, bottom: 474.6, name: 'Timpani in D.A.', printed: 'Tp.', clef: PdfClef.bass, key: 0),
      (top: 537.2, bottom: 552.0, name: 'Violino I', printed: '', clef: PdfClef.treble, key: -1),
      (top: 595.0, bottom: 609.2, name: 'Violino II', printed: '', clef: PdfClef.treble, key: -1),
      (top: 651.5, bottom: 666.1, name: 'Viola', printed: '', clef: PdfClef.alto, key: -1),
      (top: 708.7, bottom: 723.7, name: 'Violoncello', printed: '', clef: PdfClef.bass, key: -1),
      (top: 767.2, bottom: 782.2, name: 'Basso', printed: '', clef: PdfClef.bass, key: -1),
    ],
    barlines: [128.1, 187.9, 249.1, 303.4, 371.0, 426.8, 506.2, 538.2, 598.2],
  );
}
