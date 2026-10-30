// The constants of src/verovio_bridge.h the recorded commands are read with: no dart:ffi, so
// the web reads a saved engraving with them too. Keep them in sync with the header.

abstract final class VBKind {
  static const path = 0, glyph = 1, text = 2;
}

abstract final class VBSignatureKind {
  static const clef = 0, key = 1, meter = 2;
}

/// The structs [vb_struct_size] reports on (VBStruct in the header).
abstract final class VBStruct {
  static const command = 0, pathElement = 1, staffInfo = 2, measureInfo = 3, onset = 4, signature = 5;
}

abstract final class VBPathOp {
  static const move = 0, line = 1, quad = 2, cubic = 3, close = 4, ellipse = 5;
}

abstract final class VBFlag {
  static const fill = 1 << 0,
      stroke = 1 << 1,
      roundCap = 1 << 2,
      squareCap = 1 << 3,
      roundJoin = 1 << 4,
      bevelJoin = 1 << 5,
      italic = 1 << 6,
      bold = 1 << 7,
      smuflText = 1 << 8,
      newTextBlock = 1 << 9;
}
