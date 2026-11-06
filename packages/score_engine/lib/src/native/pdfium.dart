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
    final page = FPDF_LoadPage(_handle, index);
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
      FPDF_ClosePage(page);
    }
  }

  /// The part [left], [top], [width] × [height] (points) of page [index] at [scale] pixels a
  /// point as PDFium draws it, colours and all, on nothing (transparent where the page draws
  /// nothing): RGBA bytes, straight alpha.
  ({Uint8List rgba, int width, int height}) picture(int index, double left, double top, double width, double height, double scale) {
    final w = (width * scale).ceil().clamp(1, 1 << 15), h = (height * scale).ceil().clamp(1, 1 << 15);
    final page = FPDF_LoadPage(_handle, index);
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
      FPDF_ClosePage(page);
    }
  }

  /// The text PDF has in [rect] of page [index] (points, from the page's top left): '' for a
  /// scan, which has none.
  String text(int index, double left, double top, double right, double bottom) {
    final page = FPDF_LoadPage(_handle, index);
    if (page == nullptr) return '';
    final textPage = FPDFText_LoadPage(page);
    final at = malloc<Double>(4);
    try {
      if (textPage == nullptr) return '';
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
      if (textPage != nullptr) FPDFText_ClosePage(textPage);
      FPDF_ClosePage(page);
    }
  }

  void close() {
    FPDF_CloseDocument(_handle);
    malloc.free(_data);
  }
}
