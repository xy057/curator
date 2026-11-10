import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:score_engine/score_engine.dart';

import 'ai_providers.dart';

/// The PDF import's Read with AI: each page with systems found shown to an AI model ([model],
/// Settings ▸ General ▸ AI for PDF import) as two pictures, the page and its systems' starts
/// enlarged, each staff found numbered at their right ([PdfAi.labels]); its answer placed on the
/// page's ink ([PdfPages.refine]). The page the instruments were taken from goes first (its answer
/// names them for the others' questions), then the rest a few at a time.
class PdfAiReader {
  PdfAiReader(this.pages, this.model) : _client = AiClient(model.provider, timeout: const Duration(minutes: 8));

  final PdfPages pages;
  final AiModel model;
  final AiClient _client;

  /// Whether [stop] was called.
  bool get stopped => _stopped;
  bool _stopped = false;

  /// How many pages are asked about at once, after the first.
  static const _together = 3;

  /// Stops reading: requests under way are ended, and nothing more is asked.
  void stop() {
    _stopped = true;
    _client.close();
  }

  /// The pages of [layout] that have systems.
  static List<int> pagesOf(PdfScoreLayout layout) => [
        for (var p = 0; p < layout.pages.length; p++)
          if (layout.systems.any((s) => s.page == p)) p,
      ];

  /// Reads [layout]'s pages, [first] first (the page the instruments are named from), then the
  /// rest by page; [onPage] hears how many are done. The pages read, [first] first, and what went
  /// wrong with each of the others. Throws when [first] can't be read (most often the model or its
  /// key: nothing else is asked then); stopped, what was read until then.
  Future<({List<PdfAiPageRead> read, List<Object> errors})> read(PdfScoreLayout layout,
      {required int first, void Function(int done, int of)? onPage}) async {
    final all = pagesOf(layout);
    if (all.isEmpty) return (read: const <PdfAiPageRead>[], errors: const <Object>[]);
    final start = all.contains(first) ? first : all.first;
    final head = await _page(layout, start, layout.instruments, first: true);
    var done = 1;
    onPage?.call(done, all.length);
    // The others are asked with the instruments as the first page named them.
    final named = PdfAi.apply(layout, [head]).instruments;
    final rest = [for (final p in all) if (p != start) p];
    final read = <PdfAiPageRead>[], errors = <Object>[];
    var next = 0;
    Future<void> worker() async {
      while (!_stopped && next < rest.length) {
        final p = rest[next++];
        try {
          read.add(await _page(layout, p, named));
        } on Object catch (e) {
          if (!_stopped) errors.add(e);
        }
        done++;
        if (!_stopped) onPage?.call(done, all.length);
      }
    }

    await Future.wait([for (var k = 0; k < _together; k++) worker()]);
    read.sort((a, b) => a.page.compareTo(b.page));
    return (read: [head, ...read], errors: errors);
  }

  Future<PdfAiPageRead> _page(PdfScoreLayout layout, int page, List<PdfInstrument> instruments, {bool first = false}) async {
    final systems = [for (final s in layout.systems) if (s.page == page) s];
    final images = await pictures(pages, page, systems);
    if (_stopped) throw StateError('stopped');
    final prompt = PdfAi.prompt(instruments: instruments, staves: PdfAi.labels(systems).length, first: first);
    final answer = PdfAiPage.parse(await _client.ask(model.model, prompt, images: images));
    return (page: page, answer: answer, systems: await pages.refine(page, systems, answer));
  }

  /// Longest side of the page's picture, and most of the starts', pixels.
  static const _pageSide = 1600.0, _startsSide = 2400.0;

  /// Page [page] as a model is shown it, as PNG: the page with a column of each of [systems]'
  /// staves' numbers at its right ([PdfAiView]), then the systems' starts ([PdfAi.startsRight])
  /// larger, the numbers at their right too. On white, as printed.
  static Future<List<Uint8List>> pictures(PdfPages pages, int page, List<PdfSystem> systems) async {
    final size = pages.sizes[page], view = PdfAiView(size);
    final picture = await pages.page(page, math.min(4.0, _startsSide / size.height));
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(picture.rgba, picture.width, picture.height, ui.PixelFormat.rgba8888, done.complete);
    final image = await done.future;
    try {
      final labels = PdfAi.labels(systems);
      final px = picture.width / size.width; // the render's pixels a point
      final whole = _pageSide / math.max(view.width, size.height);
      final right = PdfAi.startsRight(systems, size.width);
      final starts = math.min(px, _startsSide / math.max(right + view.column, size.height));
      return [
        await _png(image, ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()), size.width, size.height, view.column,
            whole, labels),
        await _png(image, ui.Rect.fromLTWH(0, 0, right * px, image.height.toDouble()), right, size.height, view.column, starts, labels),
      ];
    } finally {
      image.dispose();
    }
  }

  /// [source]'s part [from] (a [width] × [height] points of the page) at [scale] pixels a point
  /// on white, a [column] points wide at its right with each of [labels] in red, as PNG.
  static Future<Uint8List> _png(ui.Image source, ui.Rect from, double width, double height, double column, double scale,
      List<({int label, double y, double space})> labels) async {
    final w = ((width + column) * scale).round(), h = (height * scale).round();
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)
      ..drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), ui.Paint()..color = const ui.Color(0xFFFFFFFF))
      ..drawImageRect(source, from, ui.Rect.fromLTWH(0, 0, width * scale, height * scale),
          ui.Paint()..filterQuality = ui.FilterQuality.medium);
    final left = width * scale;
    canvas.drawLine(ui.Offset(left, 0), ui.Offset(left, h.toDouble()), ui.Paint()..color = const ui.Color(0xFFBBBBBB));
    for (final l in labels) {
      final size = (math.min(l.space * 2.6, column * 0.4)).clamp(7.0, 14.0) * scale;
      final text = (ui.ParagraphBuilder(ui.ParagraphStyle(
              textAlign: ui.TextAlign.center, fontFamily: 'IBM Plex Sans', fontSize: size, fontWeight: ui.FontWeight.w600))
            ..pushStyle(ui.TextStyle(color: const ui.Color(0xFFE00000)))
            ..addText('${l.label}'))
          .build()
        ..layout(ui.ParagraphConstraints(width: column * scale));
      canvas.drawParagraph(text, ui.Offset(left, l.y * scale - text.height / 2));
      text.dispose();
    }
    final drawn = recorder.endRecording();
    final out = await drawn.toImage(w, h);
    drawn.dispose();
    try {
      final bytes = await out.toByteData(format: ui.ImageByteFormat.png);
      return bytes!.buffer.asUint8List();
    } finally {
      out.dispose();
    }
  }
}
