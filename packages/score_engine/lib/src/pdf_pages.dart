import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'native/pdfium.dart' if (dart.library.js_interop) 'native/pdfium_web.dart';
import 'pdf_ai.dart';
import 'pdf_detect.dart';
import 'pdf_layout.dart';
import 'pdf_text.dart';
import 'spacers.dart' show SpacerKey;

/// A staff of a system found on a page, alone or the first of two a brace joins ([count]), with
/// the text beside it and what each staff's start looks like ([PdfDetect.signature]).
typedef PdfSlot = ({int first, int count, String name, List<List<double>> looks});

/// Part of a page as PDFium draws it: RGBA bytes, [width] × [height] pixels, covering [area]
/// (points) of its page.
typedef PdfPicture = ({Uint8List rgba, int width, int height, ui.Rect area});

/// A PDF's pages, read by PDFium. Every document of the app is open on one worker isolate of its
/// own (PDFium can't be called from two threads at once), so reading and finding never hold up a
/// frame.
class PdfPages {
  PdfPages._(this._id, this.sizes);

  final int _id;

  /// Each page's size, points.
  final List<ui.Size> sizes;
  bool _closed = false;

  /// Opens [bytes]; throws a [FormatException] saying why it can't.
  static Future<PdfPages> open(Uint8List bytes) async {
    final id = ++_lastId;
    final sizes = await _Worker.run((docs) {
      final doc = PdfiumDocument.open(bytes);
      docs[id] = doc;
      return [for (final (w, h) in doc.pageSizes) (w, h)];
    });
    return PdfPages._(id, [for (final (w, h) in sizes) ui.Size(w, h)]);
  }

  static int _lastId = 0;

  int get length => sizes.length;

  /// The most pixels one render makes: several times a system at a 4K frame's size, or a page
  /// zoomed in as far as the import goes. Past it the scale is lowered ([fittedScale]).
  static const maxPixels = 64000000;

  /// [scale], or the largest at which [width] × [height] points make no more than [maxPixels]
  /// (and 32767 a side, PDFium's most): a page of poster size, or one that says it is, is read
  /// whole at a coarser grain, never cut off at the side's limit nor gigabytes of pixels.
  static double fittedScale(double width, double height, double scale) {
    if (!(width > 0 && height > 0)) return scale;
    return math.min(scale, math.min(math.sqrt(maxPixels / (width * height)), 32767 / math.max(width, height)));
  }

  /// [region] (points) of page [page] as ink at [scale] pixels a point ([fittedScale]: the
  /// raster says the scale it is at).
  Future<PdfRaster> render(int page, ui.Rect region, double scale) {
    final id = _id;
    return _Worker.run((docs) => _render(docs[id]!, page, region, scale));
  }

  static PdfRaster _render(PdfiumDocument doc, int page, ui.Rect region, double scale) {
    scale = fittedScale(region.width, region.height, scale);
    final r = doc.render(page, region.left, region.top, region.width, region.height, scale);
    return PdfRaster(r.ink, r.width, r.height, scale: scale, left: region.left, top: region.top);
  }

  /// What page [page] holds, found ([PdfDetect.page]): its systems, each staff no one's yet, in
  /// slots: a staff alone or two a brace joins (an instrument's), with what its start looks like
  /// ([PdfDetect.signature]) and the text left of it (its instrument's name, when the PDF has
  /// text).
  Future<List<({PdfSystem system, List<PdfSlot> slots})>> detect(int page) {
    final id = _id;
    return _Worker.run((docs) {
      final doc = docs[id]!;
      final (w, h) = doc.pageSizes[page];
      final raster = _render(doc, page, ui.Rect.fromLTWH(0, 0, w, h), PdfDetect.scale);
      return [
        for (final system in PdfDetect.page(raster, page))
          () {
            final staves = system.staves, lefts = [for (final s in staves) _staffLeft(raster, s)];
            final slots = <PdfSlot>[];
            for (var i = 0; i < staves.length; i++) {
              final pair = i + 1 < staves.length && PdfDetect.braced(raster, staves[i], staves[i + 1], math.min(lefts[i], lefts[i + 1]));
              final first = staves[i], last = staves[pair ? i + 1 : i], left = math.min(lefts[i], lefts[pair ? i + 1 : i]);
              // A braced pair's name stands between its staves, left of the brace.
              final name = _clean(doc.text(page, 0, first.top - (i > 0 ? 1.0 : 2.0) * first.space,
                  math.max(0, left - first.space * (pair ? 1.6 : 0.3)), last.bottom + 1.0 * last.space));
              slots.add((
                first: i,
                count: pair ? 2 : 1,
                name: name,
                looks: [for (var k = i; k <= (pair ? i + 1 : i); k++) PdfDetect.signature(raster, staves[k], lefts[k])],
              ));
              if (pair) i++;
            }
            // Divisi: staves numbered 1, 2… beside them, the section's name between them.
            for (var k = 0; k < slots.length; k++) {
              if (slots[k].name != '1' || slots[k].count > 1) continue;
              var end = k + 1;
              while (end < slots.length && slots[end].count == 1 && slots[end].name == '${end - k + 1}') {
                end++;
              }
              if (end - k < 2) continue;
              final first = staves[slots[k].first], last = staves[slots[end - 1].first];
              final name = _clean(doc.text(page, 0, first.top, math.max(0, lefts[slots[k].first] - first.space * 0.3), last.bottom))
                  .replaceAll(RegExp(r'(^|\s)\d(?=\s|$)'), ' ')
                  .trim();
              if (name.isEmpty) continue;
              for (var j = k; j < end; j++) {
                slots[j] = (first: slots[j].first, count: 1, name: '$name ${j - k + 1}', looks: slots[j].looks);
              }
              k = end - 1;
            }
            return (system: system, slots: slots);
          }(),
      ];
    });
  }

  static double _staffLeft(PdfRaster raster, PdfStaff s) => PdfDetect.staffLeft(raster, s);

  /// Text as a name: spaces, control characters and a music font's glyphs (a brace drawn as
  /// text) gone.
  static String _clean(String text) =>
      text.replaceAll(RegExp(r'[\s\u0000-\u001f\u00a0\u00ad\ue000-\uf8ff\ufffd-\uffff]+'), ' ').trim();

  /// How far each staff's ink reaches in each bar of [system], and whether it plays there
  /// ([PdfDetect.ink]), [masks] left out, and each staff's [staffMasks] (by index) out of it.
  Future<List<List<PdfInk>>> measure(PdfSystem system, List<ui.Rect> masks, {Map<int, List<ui.Rect>> staffMasks = const {}}) {
    final id = _id;
    return _Worker.run((docs) {
      final raster = _render(docs[id]!, system.page, regionOf(system), PdfDetect.scale);
      return PdfDetect.ink(raster, system, masks, staffMasks: staffMasks);
    });
  }

  /// [system] as printed, at [pixelsPerSpace] pixels a staff space: the PDF drawn as it is,
  /// nothing taken out or changed (cropping it is the scene's: [PdfScoreArt]).
  Future<PdfPicture> picture(PdfSystem system, {double pixelsPerSpace = 24}) {
    final id = _id;
    return _Worker.run((docs) {
      final area = regionOf(system);
      final scale = fittedScale(area.width, area.height, (pixelsPerSpace / system.space).clamp(0.5, 12.0));
      final p = docs[id]!.picture(system.page, area.left, area.top, area.width, area.height, scale);
      return (rgba: p.rgba, width: p.width, height: p.height, area: area);
    });
  }

  /// Page [page] as printed, at [scale] pixels a point.
  Future<PdfPicture> page(int page, double scale) {
    final id = _id;
    return _Worker.run((docs) {
      final doc = docs[id]!;
      final (w, h) = doc.pageSizes[page];
      final p = doc.picture(page, 0, 0, w, h, fittedScale(w, h, scale));
      return (rgba: p.rgba, width: p.width, height: p.height, area: ui.Rect.fromLTWH(0, 0, w, h));
    });
  }

  /// Page [page]'s own text, each run with its box ([PdfTextRun]): none for a scan, whose words
  /// only a picture of it shows.
  Future<List<PdfTextRun>> textRuns(int page) {
    final id = _id;
    return _Worker.run((docs) => [
          for (final (text, l, t, r, b) in docs[id]!.runs(page))
            if (PdfText.clean(text).isNotEmpty || text.contains('=')) (text: text, rect: ui.Rect.fromLTRB(l, t, r, b)),
        ]).then((runs) => [for (final r in runs) PdfTextRun(r.text, r.rect)]);
  }

  /// Page [page] found again ([detect]), its staves given to [instruments] by the names beside
  /// them where they all read as theirs, else no one's.
  Future<List<PdfSystem>> detectAgain(int page, List<PdfInstrument> instruments) async {
    final found = await detect(page);
    return [
      for (final f in found)
        () {
          final matched = _byName(f.slots, instruments, [for (final _ in instruments) const <List<double>>[]]);
          final staves = [...f.system.staves];
          for (final (k, slot) in f.slots.indexed) {
            final m = matched?[k];
            for (var j = 0; j < slot.count; j++) {
              staves[slot.first + j] =
                  staves[slot.first + j].copyWith(part: () => m == null ? null : instruments[m.$1].id, staff: (m?.$2 ?? 0) + j + 1);
            }
          }
          return f.system.copyWith(staves: staves);
        }(),
    ];
  }

  /// Page [page]'s [systems] as an AI model's [answer] about them sets them ([PdfAi.refine]): their
  /// staves' regions and barlines placed on the page's own ink.
  Future<List<PdfAiSystemRead>> refine(int page, List<PdfSystem> systems, PdfAiPage answer) {
    final id = _id;
    final view = PdfAiView(sizes[page]);
    return _Worker.run((docs) {
      final doc = docs[id]!;
      final (w, h) = doc.pageSizes[page];
      return PdfAi.refine(_render(doc, page, ui.Rect.fromLTWH(0, 0, w, h), PdfDetect.scale), systems, answer, view);
    });
  }

  /// The staff whose lines lie in [rect] (points) of page [page], found across the page's width
  /// ([PdfDetect.staves]): of those, the one reaching into [rect] whose middle is nearest its
  /// middle. Null: none is there.
  Future<({double top, double space})?> staffIn(int page, ui.Rect rect) {
    final id = _id;
    return _Worker.run((docs) {
      final doc = docs[id]!;
      final (w, h) = doc.pageSizes[page];
      final area = ui.Rect.fromLTRB(0, math.max(0.0, rect.top), w, math.min(h, rect.bottom));
      if (area.height < 1) return null;
      ({double top, double space})? best;
      var off = double.infinity;
      for (final f in PdfDetect.staves(_render(doc, page, area, PdfDetect.scale))) {
        final middle = f.top + 2 * f.space;
        if (f.top < rect.top || f.top + 4 * f.space > rect.bottom || f.right < rect.left || f.left > rect.right) continue;
        if ((middle - rect.center.dy).abs() < off) {
          off = (middle - rect.center.dy).abs();
          best = (top: f.top, space: f.space);
        }
      }
      return best;
    });
  }

  /// Everything of a system that can be someone's ([picture]'s area): its music and a little either side.
  static ui.Rect regionOf(PdfSystem system) =>
      ui.Rect.fromLTRB(system.left - system.space, system.top, system.right + system.space, system.bottom);

  /// Closes the document. Nothing may be asked of it after.
  void close() {
    if (_closed) return;
    _closed = true;
    final id = _id;
    _Worker.run((docs) {
      docs.remove(id)?.close();
      return null;
    });
  }

  /// A first reading of a whole PDF: every page's systems ([detect]), each staff given to an
  /// instrument. The instruments are the first system's with the most staves, named by the text
  /// beside them (or "Staff 1"…), their clefs guessed from their names; every other system's
  /// staves go to the instruments they look most like, in order ([PdfDetect.match]).
  /// [onPage] hears how far it has got.
  Future<PdfScoreLayout> read({String title = '', void Function(int done, int of)? onPage}) async {
    final found = <({PdfSystem system, List<PdfSlot> slots})>[];
    for (var p = 0; p < length; p++) {
      found.addAll(await detect(p));
      onPage?.call(p + 1, length);
    }
    final reference = found.fold<({PdfSystem system, List<PdfSlot> slots})?>(
        null, (best, f) => best == null || f.system.staves.length > best.system.staves.length ? f : best);
    if (reference == null) return PdfScoreLayout(title: title, pages: sizes);
    final instruments = <PdfInstrument>[
      for (final (i, slot) in reference.slots.indexed)
        () {
          final named = slot.name.isEmpty ? 'Staff ${i + 1}' : slot.name;
          return PdfInstrument(
              id: 'P${i + 1}', name: named, clef: PdfClef.forName(named), staves: slot.count, key: _keyOf(named));
        }(),
    ];
    // Abbreviations: the text a later system has beside an instrument's staff.
    final abbreviations = <String, String>{};
    final systems = <PdfSystem>[];
    final looks = [for (final slot in reference.slots) slot.looks];
    final divisi = <String, int>{};
    for (final f in found) {
      final matched = identical(f, reference)
          ? [for (final k in reference.slots.indexed) (k.$1, 0)]
          : _byName(f.slots, instruments, looks) ?? PdfDetect.match([for (final slot in f.slots) slot.looks], looks);
      final staves = [...f.system.staves];
      var division = 1;
      for (final (k, slot) in f.slots.indexed) {
        final m = matched[k];
        // A lone staff whose instrument the staff above is too: its next divisi.
        division = m != null && k > 0 && matched[k - 1] == m && slot.count == 1 && instruments[m.$1].staves == 1 ? division + 1 : 1;
        if (division > 1 && division <= 4) divisi.update(instruments[m!.$1].id, (d) => math.max(d, division), ifAbsent: () => division);
        for (var j = 0; j < slot.count; j++) {
          staves[slot.first + j] = staves[slot.first + j].copyWith(
              part: () => m == null || division > 4 ? null : instruments[m.$1].id, staff: division > 1 ? division : (m?.$2 ?? 0) + j + 1);
        }
        // Above a system's first staff, its first bar's number may be read with the name.
        final name = slot.first == 0 ? slot.name.replaceFirst(RegExp(r'^\d+\s+(?=\D)'), '') : slot.name;
        if (m != null && name.isNotEmpty && !identical(f, reference)) abbreviations.putIfAbsent(instruments[m.$1].id, () => name);
      }
      systems.add(f.system.copyWith(staves: staves));
    }
    return PdfScoreLayout(
      title: title,
      pages: sizes,
      instruments: [
        for (final i in instruments)
          i.copyWith(abbreviation: abbreviations[i.id] != i.name ? abbreviations[i.id] : null, divisi: divisi[i.id] ?? 1),
      ],
      systems: systems,
    );
  }

  /// [slots] matched to [instruments] by their names ([PdfDetect.match]'s answer): a lone staff
  /// of a two-staff instrument is the one of its staves it looks most like ([looks]). Null unless
  /// every slot's name reads as one of them, in order.
  static List<(int, int)?>? _byName(List<PdfSlot> slots, List<PdfInstrument> instruments, List<List<List<double>>> looks) {
    if (slots.any((s) => s.name.isEmpty)) return null;
    String plain(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final out = <(int, int)?>[];
    var from = 0;
    for (final slot in slots) {
      final n = plain(slot.name);
      // "Vc. 2": a section's second staff (divisi), when no instrument is named so.
      final division = RegExp(r'^(.*\D)([1-4])$').firstMatch(n);
      var found = -1;
      for (final name in [n, ?division?[1]]) {
        // The instrument before again: a section divided onto another staff (divisi).
        for (var j = math.max(0, from - 1); j < instruments.length && found < 0; j++) {
          final full = plain(instruments[j].name);
          if (j == from - 1 && (slot.count > 1 || instruments[j].staves > 1 || name == n)) continue;
          // "Vl.I" for "Violino I.": its letters in the name's order, the first one first.
          if (full == name || (name.isNotEmpty && full.startsWith(name[0]) && _inOrder(name, full) && _sameEnding(name, full))) {
            found = j;
          }
        }
        if (found >= 0) break;
      }
      if (found < 0 || (slot.count > 1 && instruments[found].staves != slot.count)) return null;
      var staff = 0;
      if (slot.count == 1) {
        for (var j = 1; j < looks[found].length; j++) {
          if (PdfDetect.similarity(slot.looks[0], looks[found][j]) > PdfDetect.similarity(slot.looks[0], looks[found][staff])) staff = j;
        }
      }
      out.add((found, staff));
      from = found + 1;
    }
    return out;
  }

  static bool _inOrder(String short, String full) {
    var i = 0;
    for (final c in full.split('')) {
      if (i < short.length && short[i] == c) i++;
    }
    return i == short.length;
  }

  /// Numbers or roman numerals at the end agree ("Vl. II" isn't "Violino I").
  static bool _sameEnding(String short, String full) {
    String ending(String s) => RegExp(r'(\d+|i{1,3}|iv|v)$').stringMatch(s) ?? '';
    return ending(short) == ending(full);
  }

  static SpacerKey _keyOf(String name) => PdfInstrument.keyForName(name);

}

/// The isolate every PDF is read on.
abstract final class _Worker {
  static SendPort? _port;
  static Future<SendPort>? _starting;

  static Future<T> run<T>(T Function(Map<int, PdfiumDocument> docs) job) async {
    final port = _port ?? await (_starting ??= _start());
    final reply = ReceivePort();
    port.send((job, reply.sendPort));
    final answer = await reply.first;
    reply.close();
    if (answer is _Answer) return answer.value as T;
    final (error, stack) = answer as (Object, StackTrace);
    Error.throwWithStackTrace(error, stack);
  }

  static Future<SendPort> _start() async {
    final ready = ReceivePort();
    await Isolate.spawn(_main, ready.sendPort, debugName: 'PDF');
    final port = await ready.first as SendPort;
    ready.close();
    return _port = port;
  }

  /// How long after the last job each document's page stays loaded ([PdfiumDocument.release]):
  /// the next job on that page meanwhile (a system's ink or picture after another's, a page shown
  /// again closer) needn't have PDFium read it again.
  static const _kept = Duration(seconds: 20);

  static void _main(SendPort ready) {
    final docs = <int, PdfiumDocument>{};
    final inbox = ReceivePort();
    ready.send(inbox.sendPort);
    Timer? idle;
    inbox.listen((message) {
      final (job, reply) = message as (Object? Function(Map<int, PdfiumDocument>), SendPort);
      idle?.cancel();
      idle = Timer(_kept, () {
        for (final doc in docs.values) {
          doc.release();
        }
      });
      try {
        reply.send(_Answer(job(docs)));
      } catch (e, stack) {
        try {
          reply.send((e, stack));
        } catch (_) {
          // An error that can't be sent, as words.
          reply.send((StateError('$e'), StackTrace.fromString('$stack')));
        }
      }
    });
  }
}

/// A job's answer, kept apart from an error's (an answer could be a record of two).
class _Answer {
  _Answer(this.value);
  final Object? value;
}
