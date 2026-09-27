// ignore_for_file: non_constant_identifier_names
// Dart view of src/verovio_bridge.h. Keep the struct layouts in sync with the header.
@DefaultAsset('package:score_engine/src/native/bindings.dart')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

final class VBEngraver extends Opaque {}

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

/// 21 × 4-byte fields; see Cmd in engraving.dart for field access by word index. The header's
/// static_asserts pin each field to its word.
final class VBCommand extends Struct {
  @Int32() external int kind;
  @Int32() external int staff;
  @Int32() external int flags;
  @Int32() external int classIndex;
  @Float() external double strokeWidth;
  @Float() external double dash;
  @Float() external double gap;
  @Float() external double x;
  @Float() external double y;
  @Float() external double size;
  @Uint32() external int codepoint;
  @Int32() external int alignment;
  @Int32() external int start;
  @Int32() external int count;
  @Int32() external int fontIndex;
  @Array(4) external Array<Float> bounds;
  @Int32() external int sourceIndex;
  @Float() external double rotation;
}

final class VBPathElement extends Struct {
  @Int32() external int op;
  @Array(6) external Array<Float> p;
}

final class VBStaffInfo extends Struct {
  @Int32() external int n;
  @Float() external double top;
  @Float() external double height;
  @Int32() external int lines;
}

final class VBMeasureInfo extends Struct {
  @Float() external double left;
  @Float() external double right;
  @Double() external double duration;
  @Int32() external int onsetStart;
  @Int32() external int onsetCount;
}

final class VBSignature extends Struct {
  @Int32() external int kind; // VBSignatureKind
  @Int32() external int staff;
  @Float() external double x;
  @Int32() external int shape;
  @Int32() external int line;
  @Int32() external int octave;
  @Int32() external int fifths;
  @Int32() external int commandStart;
  @Int32() external int commandCount;
  @Int32() external int count;
  @Int32() external int unit;
  @Int32() external int symbol;
  @Array(4) external Array<Int32> summands;
  @Int32() external int summandCount;
}

final class VBOnset extends Struct {
  @Double() external double time;
  @Float() external double x;
}

@Native<Int32 Function(Int32)>()
external int vb_struct_size(int which);
@Native<Pointer<VBEngraver> Function(Pointer<Utf8>)>()
external Pointer<VBEngraver> vb_engraver_create(Pointer<Utf8> resourcePath);
@Native<Void Function(Pointer<VBEngraver>)>()
external void vb_engraver_destroy(Pointer<VBEngraver> engraver);
@Native<Bool Function(Pointer<VBEngraver>, Pointer<Utf8>)>()
external bool vb_engraver_set_options(Pointer<VBEngraver> engraver, Pointer<Utf8> json);
@Native<Bool Function(Pointer<VBEngraver>, Pointer<Utf8>)>()
external bool vb_engraver_load_data(Pointer<VBEngraver> engraver, Pointer<Utf8> data);
@Native<Bool Function(Pointer<VBEngraver>)>()
external bool vb_engraver_render(Pointer<VBEngraver> engraver);
@Native<Pointer<Utf8> Function(Pointer<VBEngraver>)>()
external Pointer<Utf8> vb_engraver_log(Pointer<VBEngraver> engraver);
@Native<Pointer<Utf8> Function(Pointer<VBEngraver>)>()
external Pointer<Utf8> vb_engraver_available_options(Pointer<VBEngraver> engraver);

@Native<Float Function(Pointer<VBEngraver>)>()
external double vb_page_width(Pointer<VBEngraver> engraver);
@Native<Float Function(Pointer<VBEngraver>)>()
external double vb_staff_space(Pointer<VBEngraver> engraver);

@Native<Int32 Function(Pointer<VBEngraver>)>()
external int vb_command_count(Pointer<VBEngraver> engraver);
@Native<Pointer<VBCommand> Function(Pointer<VBEngraver>)>()
external Pointer<VBCommand> vb_commands(Pointer<VBEngraver> engraver);
@Native<Int32 Function(Pointer<VBEngraver>)>()
external int vb_path_element_count(Pointer<VBEngraver> engraver);
@Native<Pointer<VBPathElement> Function(Pointer<VBEngraver>)>()
external Pointer<VBPathElement> vb_path_elements(Pointer<VBEngraver> engraver);
@Native<Int32 Function(Pointer<VBEngraver>)>()
external int vb_text_byte_count(Pointer<VBEngraver> engraver);
@Native<Pointer<Uint8> Function(Pointer<VBEngraver>)>()
external Pointer<Uint8> vb_text_bytes(Pointer<VBEngraver> engraver);
@Native<Int32 Function(Pointer<VBEngraver>)>()
external int vb_class_name_count(Pointer<VBEngraver> engraver);
@Native<Pointer<Utf8> Function(Pointer<VBEngraver>, Int32)>()
external Pointer<Utf8> vb_class_name(Pointer<VBEngraver> engraver, int index);
@Native<Int32 Function(Pointer<VBEngraver>)>()
external int vb_font_name_count(Pointer<VBEngraver> engraver);
@Native<Pointer<Utf8> Function(Pointer<VBEngraver>, Int32)>()
external Pointer<Utf8> vb_font_name(Pointer<VBEngraver> engraver, int index);

@Native<Int32 Function(Pointer<VBEngraver>)>()
external int vb_staff_count(Pointer<VBEngraver> engraver);
@Native<Pointer<VBStaffInfo> Function(Pointer<VBEngraver>)>()
external Pointer<VBStaffInfo> vb_staves(Pointer<VBEngraver> engraver);
@Native<Int32 Function(Pointer<VBEngraver>)>()
external int vb_measure_count(Pointer<VBEngraver> engraver);
@Native<Pointer<VBMeasureInfo> Function(Pointer<VBEngraver>)>()
external Pointer<VBMeasureInfo> vb_measures(Pointer<VBEngraver> engraver);
@Native<Int32 Function(Pointer<VBEngraver>)>()
external int vb_onset_count(Pointer<VBEngraver> engraver);
@Native<Pointer<VBOnset> Function(Pointer<VBEngraver>)>()
external Pointer<VBOnset> vb_onsets(Pointer<VBEngraver> engraver);
@Native<Int32 Function(Pointer<VBEngraver>)>()
external int vb_signature_count(Pointer<VBEngraver> engraver);
@Native<Pointer<VBSignature> Function(Pointer<VBEngraver>)>()
external Pointer<VBSignature> vb_signatures(Pointer<VBEngraver> engraver);
@Native<Int32 Function(Pointer<VBEngraver>)>()
external int vb_source_id_count(Pointer<VBEngraver> engraver);
@Native<Pointer<Utf8> Function(Pointer<VBEngraver>, Int32)>()
external Pointer<Utf8> vb_source_id(Pointer<VBEngraver> engraver, int index);
