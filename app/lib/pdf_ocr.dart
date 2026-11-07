import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

/// A PDF page's words, each with its box ([PdfTextRun]): the PDF's own text where it has any,
/// else read off a picture of the page (OCR, by Vision on a Mac; a scan has no text of its own).
abstract final class PdfOcr {
  static const _channel = MethodChannel('curated_score/ocr');

  /// Whether a page without text of its own can be read here.
  static bool get canRead => !kIsWeb && Platform.isMacOS;

  /// Pixels a point a page is read at: small names stay legible.
  static const _scale = 3.0;

  /// Page [page]'s words; none when it has no text and can't be read here.
  static Future<List<PdfTextRun>> runsOf(PdfPages pages, int page) async {
    final own = await pages.textRuns(page);
    if (own.isNotEmpty || !canRead) return own;
    final picture = await pages.page(page, _scale);
    final lines = await _channel.invokeListMethod<Object?>('read', {
      'rgba': picture.rgba,
      'width': picture.width,
      'height': picture.height,
    });
    final area = picture.area;
    return [
      for (final line in lines ?? const [])
        if (line case [final String text, final num x, final num y, final num w, final num h])
          PdfTextRun(text,
              ui.Rect.fromLTWH(area.left + x * area.width, area.top + y * area.height, w * area.width, h * area.height)),
    ];
  }
}
