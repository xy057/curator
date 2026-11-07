import 'dart:math' as math;
import 'dart:ui' as ui;

import 'pdf_layout.dart';

/// A stretch of text on a page and its box (points, from the page's top left): from the PDF's
/// own text ([PdfPages.textRuns]) or read off the page's picture (the app's OCR).
class PdfTextRun {
  const PdfTextRun(this.text, this.rect);
  final String text;
  final ui.Rect rect;

  @override
  String toString() => '"$text" $rect';
}

/// What the words printed on a PDF score say about it: each instrument's name beside its
/// staves, and the tempo marks above the systems. Geometry only, so it reads the PDF's own text
/// and text recognised in a scan alike.
abstract final class PdfText {
  /// Each instrument's name, by id, from the words left of its staves: the first system it is
  /// named in gives its name, a later one naming it otherwise its abbreviation. [runs] are by
  /// page; pages without any are passed over. Blank lanes, and staves no one's, are left out.
  static Map<String, ({String name, String? abbreviation})> names(PdfScoreLayout layout, Map<int, List<PdfTextRun>> runs) {
    final names = <String, String>{}, abbreviations = <String, String>{};
    for (final s in layout.systems) {
      final onPage = runs[s.page];
      if (onPage == null || onPage.isEmpty) continue;
      // The instruments' staves in the system, each run of staves of one in one band.
      for (var k = 0; k < s.staves.length;) {
        final part = s.staves[k].part;
        var end = k + 1;
        while (part != null && end < s.staves.length && s.staves[end].part == part && s.staves[end].staff > s.staves[end - 1].staff) {
          end++;
        }
        final instrument = layout.instrument(part);
        if (instrument != null && !instrument.blank) {
          // Level with its staves, give or take a space and a half: not a line of text above the
          // system (an epigraph) that its band reaches up to.
          final top = math.max(s.bandOf(k).$1, s.staves[k].top - s.space * 1.5);
          final bottom = math.min(s.bandOf(end - 1).$2, s.staves[end - 1].bottom + s.space * 1.5);
          var name = _beside(onPage, top, bottom, s.left - s.space * 0.3);
          // A system's first bar number may stand above its first staff, read with the name.
          if (k == 0) name = name.replaceFirst(RegExp(r'^(?:\d+\s+)+(?=\D)'), '');
          if (name.isNotEmpty && !RegExp(r'^\d+$').hasMatch(name)) {
            if (!names.containsKey(instrument.id)) {
              names[instrument.id] = name;
            } else if (name != names[instrument.id]) {
              abbreviations.putIfAbsent(instrument.id, () => name);
            }
          }
        }
        k = end;
      }
    }
    return {for (final MapEntry(:key, :value) in names.entries) key: (name: value, abbreviation: abbreviations[key])};
  }

  /// The words whose middle is between [top] and [bottom] and left of [right], top to bottom.
  static String _beside(List<PdfTextRun> runs, double top, double bottom, double right) {
    final found = [
      for (final r in runs)
        if (r.rect.center.dy >= top && r.rect.center.dy < bottom && r.rect.center.dx < right) r,
    ]..sort((a, b) => (a.rect.top - b.rect.top).abs() < math.min(a.rect.height, b.rect.height) / 2
        ? a.rect.left.compareTo(b.rect.left)
        : a.rect.top.compareTo(b.rect.top));
    return clean(found.map((r) => r.text).join(' '));
  }

  /// Text as words: spaces, control characters and a music font's glyphs gone.
  static String clean(String text) => text.replaceAll(RegExp(r'[\s\u0000-\u001f\u00a0\u00ad\ue000-\uf8ff\ufffd-\uffff]+'), ' ').trim();

  /// The tempo marks printed above each system's first staff, by bar: its words (a tempo's or
  /// a change's, [isTempo]) and the speed a metronome mark gives (quarters a minute). A mark is
  /// the bar's it starts over; several in one bar are one.
  static Map<int, PdfTempo> tempos(PdfScoreLayout layout, Map<int, List<PdfTextRun>> runs) {
    final found = <int, List<PdfTextRun>>{};
    for (final (i, s) in layout.systems.indexed) {
      final onPage = runs[s.page];
      if (onPage == null || s.staves.isEmpty) continue;
      final segments = s.segments, bars = layout.barOfSegment[i];
      if (bars.isEmpty) continue;
      final first = s.staves.first.top;
      for (final r in onPage) {
        final y = r.rect.center.dy;
        if (y >= first || y < first - s.space * 12 || r.rect.left < s.left - s.space * 4 || r.rect.left > s.right) continue;
        var segment = 0;
        for (final (k, (l, _)) in segments.indexed) {
          if (r.rect.left >= l - s.space) segment = k;
        }
        found.putIfAbsent(bars[math.min(segment, bars.length - 1)], () => []).add(r);
      }
    }
    final out = <int, PdfTempo>{};
    for (final MapEntry(key: bar, value: list) in found.entries) {
      list.sort((a, b) => a.rect.left.compareTo(b.rect.left));
      final words = <String>[];
      double? bpm;
      // A metronome mark's line: the words before it are the tempo's, whatever they say.
      final metronome = list.where((r) => tempoOf(r.text)?.bpm != null).firstOrNull;
      bool onItsLine(PdfTextRun r) =>
          metronome != null && r.rect.left <= metronome.rect.left && (r.rect.center.dy - metronome.rect.center.dy).abs() < metronome.rect.height / 2;
      for (final r in list) {
        final mark = tempoOf(r.text, named: onItsLine(r));
        if (mark == null) continue;
        if (mark.words.isNotEmpty) words.add(mark.words);
        bpm ??= mark.bpm;
      }
      if (words.isNotEmpty || bpm != null) out[bar] = PdfTempo(words.join(' '), bpm);
    }
    return out;
  }

  /// [text] as a tempo mark: its words when they name a tempo or a change of one ([isTempo]),
  /// and a metronome mark's speed ("♩ = 120", "q = c. 96"); null when it is neither.
  /// With [named], the words are a tempo's whatever they say.
  static PdfTempo? tempoOf(String text, {bool named = false}) {
    final plain = clean(text);
    final metronome = RegExp(r'(\S{0,2})\s*=\s*(?:c(?:a|irca)?\.?\s*)?(\d{2,3})(?!\d)').firstMatch(plain);
    final speed = switch (metronome) { final m? => double.parse(m[2]!), null => null };
    final bpm = speed != null && speed >= 20 && speed <= 400 ? speed : null;
    var words = metronome == null ? plain : plain.substring(0, metronome.start);
    // What is left of a note glyph read as a letter, and brackets around the metronome mark.
    words = words.replaceAll(RegExp(r'\s*[(\[]\s*\S{0,2}$'), '').replaceAll(RegExp(r'^[\s(\[]+'), '').trim();
    final tempo = words.contains(RegExp(r'[^\W\d_]', unicode: true)) && (named || isTempo(words));
    if (!tempo && bpm == null) return null;
    return PdfTempo(tempo ? words : '', bpm);
  }

  /// Whether [words] name a tempo or a change of one (Allegro, rit., a tempo, Langsam…).
  static bool isTempo(String words) =>
      RegExp(r"[a-zà-ÿ]+", caseSensitive: false).allMatches(words.toLowerCase()).any((m) => _tempoWords.contains(m[0]));

  static const _tempoWords = {
    'adagietto', 'adagio', 'allegretto', 'allegro', 'andante', 'andantino', 'grave', 'largo', 'larghetto', 'lento', //
    'moderato', 'presto', 'prestissimo', 'vivace', 'vivacissimo', 'vivo', 'maestoso', 'sostenuto', 'comodo', 'tempo',
    'mosso', 'moto', 'rubato', 'rit', 'ritard', 'ritardando', 'riten', 'ritenuto', 'rall', 'rallentando', 'accel',
    'accelerando', 'allargando', 'stringendo', 'calando', 'morendo', 'smorzando', 'stretto', 'tranquillo', 'langsam',
    'schnell', 'lebhaft', 'mässig', 'massig', 'ruhig', 'bewegt', 'zeitmass', 'zeitmaß', 'lent', 'lentement', 'vif',
    'modéré', 'modere', 'animé', 'anime', 'cédez', 'cedez', 'retenu', 'serrez', 'mouvement', 'slow', 'slowly', 'fast',
    'moderately', 'brisk', 'briskly', 'lively',
  };
}
