// Verovio through dart:ffi: what [Engraver] and [FontResources] run natively. The web has
// verovio_web.dart in its place, which can't engrave.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../engraving.dart';
import 'bindings.dart';

String verovioVersion() => vb_version().toDartString();

Map<String, Object?> availableOptions(String resourceDirectory) => using((arena) {
  final engraver = vb_engraver_create(resourceDirectory.toNativeUtf8(allocator: arena));
  if (engraver == nullptr) throw EngraveException('Couldn’t start the engraver.');
  try {
    return jsonDecode(vb_engraver_available_options(engraver).toDartString()) as Map<String, Object?>;
  } finally {
    vb_engraver_destroy(engraver);
  }
});

EngravingData engrave(String musicXML, String resourceDirectory, String optionsJson) {
  _checkLayout();
  if (!File('$resourceDirectory/Bravura.xml').existsSync()) {
    throw EngraveException('Engraving resources not found in $resourceDirectory');
  }
  return using((arena) {
    final engraver = vb_engraver_create(resourceDirectory.toNativeUtf8(allocator: arena));
    if (engraver == nullptr) throw EngraveException('Couldn’t start the engraver.');
    try {
      if (!vb_engraver_set_options(engraver, optionsJson.toNativeUtf8(allocator: arena))) {
        throw EngraveException('The engraving options were refused.\n${vb_engraver_log(engraver).toDartString()}');
      }
      if (!vb_engraver_load_data(engraver, musicXML.toNativeUtf8(allocator: arena))) {
        throw EngraveException('Couldn’t read the score.\n${vb_engraver_log(engraver).toDartString()}');
      }
      if (!vb_engraver_render(engraver)) {
        throw EngraveException('Couldn’t engrave the score.\n${vb_engraver_log(engraver).toDartString()}');
      }
      return _copy(engraver, warnings: Engraver.logMessages(vb_engraver_log(engraver).toDartString()));
    } finally {
      vb_engraver_destroy(engraver);
    }
  });
}

/// Fails loudly when the library was built from a different header than these bindings,
/// instead of reading garbage.
void _checkLayout() {
  final expected = {
    VBStruct.command: (sizeOf<VBCommand>(), Cmd.words * 4),
    VBStruct.pathElement: (sizeOf<VBPathElement>(), 7 * 4),
    VBStruct.staffInfo: (sizeOf<VBStaffInfo>(), null),
    VBStruct.measureInfo: (sizeOf<VBMeasureInfo>(), null),
    VBStruct.onset: (sizeOf<VBOnset>(), null),
    VBStruct.signature: (sizeOf<VBSignature>(), null),
  };
  for (final MapEntry(key: which, value: (dart, words)) in expected.entries) {
    final native = vb_struct_size(which);
    if (native != dart || (words != null && words != dart)) {
      throw StateError(
        'The native engine does not match its Dart bindings (struct $which: '
        'native $native bytes, Dart $dart${words == null ? '' : ', words $words'}). Rebuild it.',
      );
    }
  }
}

EngravingData _copy(Pointer<VBEngraver> e, {required List<String> warnings}) {
  Uint8List bytes(Pointer<NativeType> pointer, int count, int size) =>
      count == 0 ? Uint8List(0) : Uint8List.fromList(pointer.cast<Uint8>().asTypedList(count * size));

  final onsets = vb_onsets(e);
  final measures = <MeasureLayout>[];
  final measurePointer = vb_measures(e);
  for (var i = 0; i < vb_measure_count(e); i++) {
    final m = measurePointer[i];
    final times = Float64List(m.onsetCount), xs = Float64List(m.onsetCount);
    for (var j = 0; j < m.onsetCount; j++) {
      times[j] = onsets[m.onsetStart + j].time;
      xs[j] = onsets[m.onsetStart + j].x;
    }
    measures.add(MeasureLayout(left: m.left, right: m.right, duration: m.duration, onsetTimes: times, onsetXs: xs));
  }
  final stavePointer = vb_staves(e);
  final staves = [
    for (var i = 0; i < vb_staff_count(e); i++)
      StaffInfo(n: stavePointer[i].n, top: stavePointer[i].top, height: stavePointer[i].height, lines: stavePointer[i].lines),
  ]..sort((a, b) => a.n.compareTo(b.n));

  return EngravingData(
    width: vb_page_width(e),
    staffSpace: vb_staff_space(e),
    staves: staves,
    measures: measures,
    commandBytes: bytes(vb_commands(e), vb_command_count(e), sizeOf<VBCommand>()),
    pathBytes: bytes(vb_path_elements(e), vb_path_element_count(e), sizeOf<VBPathElement>()),
    text: bytes(vb_text_bytes(e), vb_text_byte_count(e), 1),
    classNames: [for (var i = 0; i < vb_class_name_count(e); i++) vb_class_name(e, i).toDartString()],
    fontNames: [for (var i = 0; i < vb_font_name_count(e); i++) vb_font_name(e, i).toDartString()],
    sourceIds: [for (var i = 0; i < vb_source_id_count(e); i++) vb_source_id(e, i).toDartString()],
    warnings: List.unmodifiable(warnings),
    signatures: [
      for (var i = 0; i < vb_signature_count(e); i++)
        switch (vb_signatures(e)[i]) {
          final s when s.kind == VBSignatureKind.clef => ClefSignature(
            staff: s.staff,
            x: s.x,
            commandStart: s.commandStart,
            commandCount: s.commandCount,
            shape: ClefShape.values[s.shape.clamp(0, ClefShape.values.length - 1)],
            line: s.line,
            octave: s.octave,
          ),
          final s when s.kind == VBSignatureKind.meter => TimeSignature(
            staff: s.staff,
            x: s.x,
            commandStart: s.commandStart,
            commandCount: s.commandCount,
            count: s.count,
            unit: s.unit,
            symbol: s.symbol == 0 ? null : s.symbol,
            summands: [for (var j = 0; j < s.summandCount.clamp(0, 4); j++) s.summands[j]],
          ),
          final s => KeySignature(
            staff: s.staff,
            x: s.x,
            commandStart: s.commandStart,
            commandCount: s.commandCount,
            fifths: s.fifths,
          ),
        },
    ],
  );
}

/// A font file's face [face]: its units per em and each of [codes]' box and advance (null where it has
/// no glyph); null when it can't be read.
({int upm, List<({double x, double y, double w, double h, double advance})?> glyphs})? measureFont(
  String path,
  int face, {
  required List<int> codes,
}) => using((arena) {
  final codePointer = arena<Uint32>(codes.length);
  for (final (i, c) in codes.indexed) {
    codePointer[i] = c;
  }
  final out = arena<Float>(codes.length * 5);
  final upm = vb_measure_font(path.toNativeUtf8(allocator: arena), face, codePointer, codes.length, out);
  if (upm <= 0) return null;
  return (
    upm: upm,
    glyphs: [
      for (var i = 0; i < codes.length; i++)
        out[i * 5 + 4] < 0 || codes[i] == 0
            ? null
            : (x: out[i * 5], y: out[i * 5 + 1], w: out[i * 5 + 2], h: out[i * 5 + 3], advance: out[i * 5 + 4]),
    ],
  );
});
