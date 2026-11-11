// ignore_for_file: non_constant_identifier_names
// PDFium through dart:ffi: the few calls that render a PDF's pages (hook/build.dart bundles the
// library). PDFium isn't thread-safe, so only PdfWorker's isolate calls these. The web has
// pdfium_web.dart in its place, which can't open a PDF.
@DefaultAsset('package:score_engine/src/native/pdfium.dart')
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

@Native<Void Function()>()
external void FPDF_InitLibrary();

@Native<Pointer<Void> Function(Pointer<Void>, Int, Pointer<Char>)>()
external Pointer<Void> FPDF_LoadMemDocument(Pointer<Void> data, int size, Pointer<Char> password);

@Native<UnsignedLong Function()>()
external int FPDF_GetLastError();

@Native<Int Function(Pointer<Void>)>()
external int FPDF_GetPageCount(Pointer<Void> document);

@Native<Pointer<Void> Function(Pointer<Void>, Int)>()
external Pointer<Void> FPDF_LoadPage(Pointer<Void> document, int index);

@Native<Float Function(Pointer<Void>)>()
external double FPDF_GetPageWidthF(Pointer<Void> page);

@Native<Float Function(Pointer<Void>)>()
external double FPDF_GetPageHeightF(Pointer<Void> page);

@Native<Pointer<Void> Function(Int, Int, Int, Pointer<Void>, Int)>()
external Pointer<Void> FPDFBitmap_CreateEx(int width, int height, int format, Pointer<Void> firstScan, int stride);

@Native<Int Function(Pointer<Void>, Int, Int, Int, Int, UnsignedLong)>()
external int FPDFBitmap_FillRect(Pointer<Void> bitmap, int left, int top, int width, int height, int color);

@Native<Void Function(Pointer<Void>, Pointer<Void>, Int, Int, Int, Int, Int, Int)>()
external void FPDF_RenderPageBitmap(
    Pointer<Void> bitmap, Pointer<Void> page, int startX, int startY, int sizeX, int sizeY, int rotate, int flags);

@Native<Void Function(Pointer<Void>)>()
external void FPDFBitmap_Destroy(Pointer<Void> bitmap);

@Native<Void Function(Pointer<Void>)>()
external void FPDF_ClosePage(Pointer<Void> page);

@Native<Void Function(Pointer<Void>)>()
external void FPDF_CloseDocument(Pointer<Void> document);

@Native<Pointer<Void> Function(Pointer<Void>)>()
external Pointer<Void> FPDFText_LoadPage(Pointer<Void> page);

@Native<Void Function(Pointer<Void>)>()
external void FPDFText_ClosePage(Pointer<Void> textPage);

@Native<Int Function(Pointer<Void>, Double, Double, Double, Double, Pointer<Uint16>, Int)>()
external int FPDFText_GetBoundedText(
    Pointer<Void> textPage, double left, double top, double right, double bottom, Pointer<Uint16> buffer, int length);

@Native<Int Function(Pointer<Void>, Int, Int)>()
external int FPDFText_CountRects(Pointer<Void> textPage, int start, int count);

@Native<Int Function(Pointer<Void>, Int, Pointer<Double>, Pointer<Double>, Pointer<Double>, Pointer<Double>)>()
external int FPDFText_GetRect(
    Pointer<Void> textPage, int index, Pointer<Double> left, Pointer<Double> top, Pointer<Double> right, Pointer<Double> bottom);

@Native<Int Function(Pointer<Void>, Int, Int, Int, Int, Int, Double, Double, Pointer<Int>, Pointer<Int>)>()
external int FPDF_PageToDevice(Pointer<Void> page, int startX, int startY, int sizeX, int sizeY, int rotate, double pageX,
    double pageY, Pointer<Int> deviceX, Pointer<Int> deviceY);

@Native<Int Function(Pointer<Void>, Int, Int, Int, Int, Int, Int, Int, Pointer<Double>, Pointer<Double>)>()
external int FPDF_DeviceToPage(Pointer<Void> page, int startX, int startY, int sizeX, int sizeY, int rotate, int deviceX,
    int deviceY, Pointer<Double> pageX, Pointer<Double> pageY);

const _bgrx = 3, _bgra = 4, _annotations = 0x01, _printing = 0x800, _rgbaOrder = 0x10;

bool _started = false;

/// An open document: its bytes stay in native memory while it is open (PDFium reads them as
/// it goes).
final class PdfiumDocument {
  PdfiumDocument._(this._handle, this._data, this.pageSizes);

  final Pointer<Void> _handle;
  final Pointer<Uint8> _data;

  /// Each page's width and height, points, as shown (its rotation applied).
  final List<(double, double)> pageSizes;

  // The page asked of last stays loaded, with its text once that is asked for: PDFium keeps what
  // it worked out of a page (a scan's picture decoded: most of a render's time) only while the
  // page is loaded, and a page is asked of many times in a row (each staff's name, each system's
  // ink and picture).
  int _loaded = -1;
  Pointer<Void> _page = nullptr, _text = nullptr;

  /// Page [index], loaded (the one loaded before it let go); nullptr if it can't be.
  Pointer<Void> _load(int index) {
    if (index == _loaded) return _page;
    release();
    final page = FPDF_LoadPage(_handle, index);
    if (page != nullptr) {
      _loaded = index;
      _page = page;
    }
    return page;
  }

  /// The text of the page loaded ([_load]); nullptr if it has none to give.
  Pointer<Void> get _loadedText => _text != nullptr ? _text : _text = FPDFText_LoadPage(_page);

  /// Lets go of the page kept loaded, and the memory PDFium holds for it: the next call loads its
  /// page afresh.
  void release() {
    if (_text != nullptr) FPDFText_ClosePage(_text);
    if (_page != nullptr) FPDF_ClosePage(_page);
    _text = _page = nullptr;
    _loaded = -1;
  }

  /// Opens [bytes]; throws a [FormatException] saying why it can't.
  static PdfiumDocument open(Uint8List bytes) {
    if (!_started) {
      FPDF_InitLibrary();
      _started = true;
    }
    final data = malloc<Uint8>(bytes.length);
    data.asTypedList(bytes.length).setAll(0, bytes);
    final handle = FPDF_LoadMemDocument(data.cast(), bytes.length, nullptr);
    if (handle == nullptr) {
      final error = FPDF_GetLastError();
      malloc.free(data);
      throw FormatException(switch (error) {
        4 => 'This PDF has a password.',
        3 => 'That doesn’t look like a PDF.',
        _ => 'Couldn’t read the PDF (PDFium error $error).',
      });
    }
    final sizes = <(double, double)>[];
    for (var i = 0; i < FPDF_GetPageCount(handle); i++) {
      final page = FPDF_LoadPage(handle, i);
      if (page == nullptr) {
        sizes.add((0, 0));
        continue;
      }
      sizes.add((FPDF_GetPageWidthF(page), FPDF_GetPageHeightF(page)));
      FPDF_ClosePage(page);
    }
    return PdfiumDocument._(handle, data, sizes);
  }

  /// The part [left], [top], [width] × [height] (points, from the page's top left) of page
  /// [index] at [scale] pixels a point, as ink: a byte a pixel, 0 for paper, 255 for black.
  /// [width] × [height] pixels come back, the region's size times [scale] rounded up.
  ({Uint8List ink, int width, int height}) render(int index, double left, double top, double width, double height, double scale) {
    final w = (width * scale).ceil().clamp(1, 1 << 15), h = (height * scale).ceil().clamp(1, 1 << 15);
    final page = _load(index);
    if (page == nullptr) return (ink: Uint8List(w * h), width: w, height: h);
    final stride = w * 4;
    final pixels = malloc<Uint8>(stride * h);
    final bitmap = FPDFBitmap_CreateEx(w, h, _bgrx, pixels.cast(), stride);
    try {
      FPDFBitmap_FillRect(bitmap, 0, 0, w, h, 0xFFFFFFFF);
      final (pageWidth, pageHeight) = pageSizes[index];
      FPDF_RenderPageBitmap(bitmap, page, (-left * scale).round(), (-top * scale).round(), (pageWidth * scale).round(),
          (pageHeight * scale).round(), 0, _annotations | _printing);
      final bgrx = pixels.asTypedList(stride * h), ink = Uint8List(w * h);
      for (var i = 0, p = 0; i < ink.length; i++, p += 4) {
        // Darkness, as luma: coloured ink (a red rehearsal mark) still reads as ink.
        ink[i] = 255 - ((bgrx[p] * 29 + bgrx[p + 1] * 150 + bgrx[p + 2] * 77) >> 8);
      }
      return (ink: ink, width: w, height: h);
    } finally {
      FPDFBitmap_Destroy(bitmap);
      malloc.free(pixels);
    }
  }

  /// The part [left], [top], [width] × [height] (points) of page [index] at [scale] pixels a
  /// point as PDFium draws it, colours and all, on nothing (transparent where the page draws
  /// nothing): RGBA bytes, straight alpha.
  ({Uint8List rgba, int width, int height}) picture(int index, double left, double top, double width, double height, double scale) {
    final w = (width * scale).ceil().clamp(1, 1 << 15), h = (height * scale).ceil().clamp(1, 1 << 15);
    final page = _load(index);
    if (page == nullptr) return (rgba: Uint8List(w * h * 4), width: w, height: h);
    final stride = w * 4;
    final pixels = malloc<Uint8>(stride * h);
    final bitmap = FPDFBitmap_CreateEx(w, h, _bgra, pixels.cast(), stride);
    try {
      FPDFBitmap_FillRect(bitmap, 0, 0, w, h, 0x00000000);
      final (pageWidth, pageHeight) = pageSizes[index];
      FPDF_RenderPageBitmap(bitmap, page, (-left * scale).round(), (-top * scale).round(), (pageWidth * scale).round(),
          (pageHeight * scale).round(), 0, _annotations | _printing | _rgbaOrder);
      return (rgba: Uint8List.fromList(pixels.asTypedList(stride * h)), width: w, height: h);
    } finally {
      FPDFBitmap_Destroy(bitmap);
      malloc.free(pixels);
    }
  }

  /// The text PDF has in [rect] of page [index] (points, from the page's top left): '' for a
  /// scan, which has none.
  String text(int index, double left, double top, double right, double bottom) {
    final page = _load(index);
    if (page == nullptr) return '';
    final textPage = _loadedText;
    if (textPage == nullptr) return '';
    final at = malloc<Double>(4);
    try {
      // Points from the top left to PDF's own (from the bottom left, the page's rotation and box
      // taken into account), a hundredth of a point at a time.
      final (w, h) = pageSizes[index];
      FPDF_DeviceToPage(page, 0, 0, (w * 100).round(), (h * 100).round(), 0, (left * 100).round(), (top * 100).round(), at, at + 1);
      FPDF_DeviceToPage(
          page, 0, 0, (w * 100).round(), (h * 100).round(), 0, (right * 100).round(), (bottom * 100).round(), at + 2, at + 3);
      final l = at[0] < at[2] ? at[0] : at[2], r = at[0] < at[2] ? at[2] : at[0];
      final t = at[1] > at[3] ? at[1] : at[3], b = at[1] > at[3] ? at[3] : at[1];
      final length = FPDFText_GetBoundedText(textPage, l, t, r, b, nullptr, 0);
      if (length <= 0) return '';
      final buffer = malloc<Uint16>(length + 1);
      try {
        final n = FPDFText_GetBoundedText(textPage, l, t, r, b, buffer, length + 1);
        return String.fromCharCodes(buffer.asTypedList(n.clamp(0, length + 1))).replaceAll('\u0000', '');
      } finally {
        malloc.free(buffer);
      }
    } finally {
      malloc.free(at);
    }
  }

  /// Page [index]'s text as the PDF lays it out: each run (a stretch of a line, as PDFium groups
  /// it) with its box (points, from the page's top left). None for a scan.
  List<(String, double, double, double, double)> runs(int index) {
    final page = _load(index);
    if (page == nullptr) return const [];
    final textPage = _loadedText;
    if (textPage == nullptr) return const [];
    final box = malloc<Double>(4);
    final device = malloc<Int>(2);
    try {
      final (w, h) = pageSizes[index];
      final (sw, sh) = ((w * 100).round(), (h * 100).round());
      (double, double) toTopLeft(double x, double y) {
        FPDF_PageToDevice(page, 0, 0, sw, sh, 0, x, y, device, device + 1);
        return (device[0] / 100, device[1] / 100);
      }

      final out = <(String, double, double, double, double)>[];
      final count = FPDFText_CountRects(textPage, 0, -1);
      for (var i = 0; i < count; i++) {
        if (FPDFText_GetRect(textPage, i, box, box + 1, box + 2, box + 3) == 0) continue;
        final (l, t, r, b) = (box[0], box[1], box[2], box[3]);
        final length = FPDFText_GetBoundedText(textPage, l, t, r, b, nullptr, 0);
        if (length <= 0) continue;
        final buffer = malloc<Uint16>(length + 1);
        final String text;
        try {
          final n = FPDFText_GetBoundedText(textPage, l, t, r, b, buffer, length + 1);
          text = String.fromCharCodes(buffer.asTypedList(n.clamp(0, length + 1))).replaceAll('\u0000', '');
        } finally {
          malloc.free(buffer);
        }
        final (x0, y0) = toTopLeft(l, t);
        final (x1, y1) = toTopLeft(r, b);
        out.add((text, x0 < x1 ? x0 : x1, y0 < y1 ? y0 : y1, x0 < x1 ? x1 : x0, y0 < y1 ? y1 : y0));
      }
      return out;
    } finally {
      malloc.free(box);
      malloc.free(device);
    }
  }

  void close() {
    release();
    FPDF_CloseDocument(_handle);
    malloc.free(_data);
  }
}
