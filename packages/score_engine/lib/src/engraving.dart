import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'engraving_options.dart';
import 'native/bindings.dart';
import 'score_fonts.dart';

class EngraveException implements Exception {
  EngraveException(this.message);
  final String message;
  @override
  String toString() => message;
}

class StaffInfo {
  const StaffInfo({required this.n, required this.top, required this.height, required this.lines});

  /// Staff number (@n), 1-based in score order.
  final int n;

  /// y of the top staff line and distance to the bottom line, in device units.
  final double top;
  final double height;
  final int lines;
}

class MeasureLayout {
  const MeasureLayout({
    required this.left,
    required this.right,
    required this.duration,
    required this.onsetTimes,
    required this.onsetXs,
  });

  /// x of the left and right barlines.
  final double left;
  final double right;

  /// Length in quarter notes.
  final double duration;

  /// Every distinct onset in the measure (any staff): quarter notes from the measure
  /// start, and the x where those notes are aligned. Ascending.
  final Float64List onsetTimes;
  final Float64List onsetXs;
}

enum ClefShape { none, g, gg, f, c, percussion, tab }

/// A clef, key or time signature in the engraving, as music rather than glyphs.
sealed class Signature {
  const Signature({required this.staff, required this.x, required this.commandStart, required this.commandCount});

  /// Staff number (@n).
  final int staff;

  /// x of its leftmost glyph, device units.
  final double x;

  /// The recorded glyph commands that draw it.
  final int commandStart;
  final int commandCount;
}

class ClefSignature extends Signature {
  const ClefSignature({
    required super.staff,
    required super.x,
    required super.commandStart,
    required super.commandCount,
    required this.shape,
    required this.line,
    required this.octave,
  });
  final ClefShape shape;

  /// Staff line the clef sits on, 1 = bottom.
  final int line;

  /// Octave shift: -1 for "8 below" (e.g. tenor voice), +1 for "8 above".
  final int octave;
}

class KeySignature extends Signature {
  const KeySignature({
    required super.staff,
    required super.x,
    required super.commandStart,
    required super.commandCount,
    required this.fifths,
  });

  /// Sharps if positive, flats if negative.
  final int fifths;
}

class TimeSignature extends Signature {
  const TimeSignature({
    required super.staff,
    required super.x,
    required super.commandStart,
    required super.commandCount,
    required this.count,
    required this.unit,
    this.symbol,
    List<int>? summands,
  }) : summands = summands ?? const [];

  /// Beats per bar (additive counts summed) and the beat unit (4 = crotchet).
  final int count;
  final int unit;

  /// The numerator as written: [2, 2, 3] for 2+2+3/8, [6] for 6/8.
  final List<int> summands;

  /// SMuFL codepoint of common or cut time, when drawn as a symbol.
  final int? symbol;
}

/// Field positions (in 4-byte words) inside one recorded command; mirrors VBCommand (the
/// bridge's static_asserts pin the same indices on the C side).
abstract final class Cmd {
  static const words = 21;
  static const kind = 0, staff = 1, flags = 2, classIndex = 3;
  static const strokeWidth = 4, dash = 5, gap = 6, x = 7, y = 8, size = 9;
  static const codepoint = 10, alignment = 11, start = 12, count = 13, fontIndex = 14;
  static const bounds = 15; // x, y, w, h
  static const source = 19; // index into sourceIds, or -1
  static const rotation = 20; // glyph: degrees clockwise about its origin
}

/// Everything Verovio produced for one score, as plain data that can cross isolates.
/// All geometry is in Verovio device units with y pointing down.
class EngravingData {
  EngravingData._({
    required this.width,
    required this.staffSpace,
    required this.staves,
    required this.measures,
    required Uint8List commandBytes,
    required Uint8List pathBytes,
    required this.text,
    required this.classNames,
    required this.fontNames,
    required this.signatures,
    required this.sourceIds,
    required this.warnings,
  })  : commandInts = commandBytes.buffer.asInt32List(commandBytes.offsetInBytes, commandBytes.length ~/ 4),
        commandFloats = commandBytes.buffer.asFloat32List(commandBytes.offsetInBytes, commandBytes.length ~/ 4),
        pathInts = pathBytes.buffer.asInt32List(pathBytes.offsetInBytes, pathBytes.length ~/ 4),
        pathFloats = pathBytes.buffer.asFloat32List(pathBytes.offsetInBytes, pathBytes.length ~/ 4);

  final double width;

  /// Device units per staff space (distance between two staff lines).
  final double staffSpace;
  final List<StaffInfo> staves;
  final List<MeasureLayout> measures;

  /// The recorded commands, viewed as ints and floats over the same memory (see [Cmd]).
  final Int32List commandInts;
  final Float32List commandFloats;

  /// Path elements: 7 words each, an op (int) followed by 6 floats.
  final Int32List pathInts;
  final Float32List pathFloats;
  final Uint8List text;
  final List<String> classNames;
  final List<String> fontNames;

  /// Every clef, key and time signature, in drawing order.
  final List<Signature> signatures;

  /// Ids of the MusicXML elements text commands come from (see ScoreText).
  final List<String> sourceIds;

  /// What Verovio left out or doesn't support in the score ("Unsupported direction-type
  /// 'harp-pedals'"), each once, in the order it met them; empty when it read everything.
  final List<String> warnings;

  int get commandCount => commandInts.length ~/ Cmd.words;
}

abstract final class Engraver {
  /// Engraves MusicXML into one endless system. Runs on a background isolate.
  /// [resourceDirectory] must contain Verovio's font metrics (`Bravura.xml`, `text/`…).
  static Future<EngravingData> engrave(
    String musicXML, {
    required String resourceDirectory,
    MusicFont font = MusicFont.bravura,
    EngravingOptions options = const EngravingOptions(),
  }) {
    final json = options.verovioJson(font);
    return Isolate.run(() => _engrave(musicXML, resourceDirectory, json));
  }

  /// Every option Verovio knows, with its type, default and range: what [EngraveOption]s are
  /// checked against.
  static Map<String, Object?> availableOptions({required String resourceDirectory}) => using((arena) {
        final engraver = vb_engraver_create(resourceDirectory.toNativeUtf8(allocator: arena));
        if (engraver == nullptr) throw EngraveException('Could not start the engraver.');
        try {
          return jsonDecode(vb_engraver_available_options(engraver).toDartString()) as Map<String, Object?>;
        } finally {
          vb_engraver_destroy(engraver);
        }
      });

  static EngravingData _engrave(String musicXML, String resourceDirectory, String optionsJson) {
    _checkLayout();
    if (!File('$resourceDirectory/Bravura.xml').existsSync()) {
      throw EngraveException('Engraving resources not found in $resourceDirectory');
    }
    return using((arena) {
      final engraver = vb_engraver_create(resourceDirectory.toNativeUtf8(allocator: arena));
      if (engraver == nullptr) throw EngraveException('Could not start the engraver.');
      try {
        if (!vb_engraver_set_options(engraver, optionsJson.toNativeUtf8(allocator: arena))) {
          throw EngraveException('The engraving options were refused.\n${vb_engraver_log(engraver).toDartString()}');
        }
        if (!vb_engraver_load_data(engraver, musicXML.toNativeUtf8(allocator: arena))) {
          throw EngraveException('The score could not be read.\n${vb_engraver_log(engraver).toDartString()}');
        }
        if (!vb_engraver_render(engraver)) {
          throw EngraveException('The score could not be engraved.\n${vb_engraver_log(engraver).toDartString()}');
        }
        return _copy(engraver, warnings: logMessages(vb_engraver_log(engraver).toDartString()));
      } finally {
        vb_engraver_destroy(engraver);
      }
    });
  }

  /// Fails loudly when the library was built from a different header than these bindings,
  /// instead of reading garbage.
  static void _checkLayout() {
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
        throw StateError('The native engine does not match its Dart bindings (struct $which: '
            'native $native bytes, Dart $dart${words == null ? '' : ', words $words'}). Rebuild it.');
      }
    }
  }

  /// Verovio's log as one message a line, without its "[Warning] " and "MusicXML import: "
  /// prefixes.
  static List<String> logMessages(String log) => [
        for (final line in const LineSplitter().convert(log))
          if (line.replaceFirst(RegExp(r'^\[(Warning|Error)\]\s*'), '').replaceFirst(RegExp(r'^MusicXML import:\s*'), '').trim()
              case final message when message.isNotEmpty)
            message,
      ];

  static EngravingData _copy(Pointer<VBEngraver> e, {required List<String> warnings}) {
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

    return EngravingData._(
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
}
