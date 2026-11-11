// pdfium.dart's place on the web, where there is no PDFium: a page shows a PDF score from the
// pictures its export wrote (see PdfPages), so nothing here is called.
import 'dart:typed_data';

final class PdfiumDocument {
  PdfiumDocument._();

  List<(double, double)> get pageSizes => const [];

  static PdfiumDocument open(Uint8List bytes) => throw UnsupportedError('No PDFium on the web');

  ({Uint8List ink, int width, int height}) render(int index, double left, double top, double width, double height, double scale) =>
      throw UnsupportedError('No PDFium on the web');

  ({Uint8List rgba, int width, int height}) picture(int index, double left, double top, double width, double height, double scale) =>
      throw UnsupportedError('No PDFium on the web');

  String text(int index, double left, double top, double right, double bottom) => '';

  List<(String, double, double, double, double)> runs(int index) => const [];

  void release() {}

  void close() {}
}
