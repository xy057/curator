import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'engraving_options.dart';
import 'native/verovio.dart' if (dart.library.js_interop) 'native/verovio_web.dart' as native;
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
  static const words = 22;
  static const kind = 0, staff = 1, flags = 2, classIndex = 3;
  static const strokeWidth = 4, dash = 5, gap = 6, x = 7, y = 8, size = 9;
  static const codepoint = 10, alignment = 11, start = 12, count = 13, fontIndex = 14;
  static const bounds = 15; // x, y, w, h
  static const source = 19; // index into sourceIds, or -1
  static const rotation = 20; // glyph: degrees clockwise about its origin
  static const letterSpacing = 21; // text: added between its characters
}

/// A music font glyph's ink box and advance, in staff spaces: [x] and [y] its lower left
/// corner from the origin (y up, as SMuFL has it).
typedef GlyphBox = ({double x, double y, double width, double height, double advance});

/// Everything Verovio produced for one score, as plain data that can cross isolates.
/// All geometry is in Verovio device units with y pointing down.
class EngravingData {
  /// Usually [Engraver.engrave]'s; also built again from a saved copy.
  EngravingData({
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
    this.glyphs = const {},
    this.engravingDefaults = const {},
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

  /// The music font's glyphs (codepoint → box), as Verovio measured them: Bravura's where the
  /// font has none (Verovio's fallback).
  final Map<int, GlyphBox> glyphs;

  /// The SMuFL engraving defaults it was engraved with (staff spaces): the font's own, with
  /// the user's changes.
  final Map<String, double> engravingDefaults;

  int get commandCount => commandInts.length ~/ Cmd.words;

  EngravingData _with({required Map<int, GlyphBox> glyphs, required Map<String, double> engravingDefaults}) =>
      EngravingData(
        width: width,
        staffSpace: staffSpace,
        staves: staves,
        measures: measures,
        commandBytes: commandInts.buffer.asUint8List(commandInts.offsetInBytes, commandInts.lengthInBytes),
        pathBytes: pathInts.buffer.asUint8List(pathInts.offsetInBytes, pathInts.lengthInBytes),
        text: text,
        classNames: classNames,
        fontNames: fontNames,
        signatures: signatures,
        sourceIds: sourceIds,
        warnings: warnings,
        glyphs: Map.unmodifiable(glyphs),
        engravingDefaults: Map.unmodifiable(engravingDefaults),
      );
}

/// The Verovio this engine was built with, e.g. `6.3.0`.
String get verovioVersion => native.verovioVersion();

abstract final class Engraver {
  /// Engraves MusicXML into one endless system. Runs on a background isolate.
  /// [resourceDirectory] must contain Verovio's font metrics (`Bravura.xml`, `text/`…).
  /// [verovioOptions] go to Verovio as they are (the typography's: `ScoreTypography.verovioOptions`).
  static Future<EngravingData> engrave(
    String musicXML, {
    required String resourceDirectory,
    MusicFont font = MusicFont.bravura,
    EngravingOptions options = const EngravingOptions(),
    Map<String, Object> verovioOptions = const {},
  }) {
    final json = options.verovioJson(font, verovioOptions);
    final defaults = options.engravingDefaults(font), name = font.name;
    return Isolate.run(() {
      final data = native.engrave(musicXML, resourceDirectory, json);
      return data._with(glyphs: glyphMetrics(resourceDirectory, name), engravingDefaults: defaults);
    });
  }

  /// Font [name]'s glyph boxes from Verovio's metrics in [resourceDirectory] (`<name>.xml`),
  /// over Bravura's.
  static Map<int, GlyphBox> glyphMetrics(String resourceDirectory, String name) {
    final glyphs = <int, GlyphBox>{};
    for (final font in {'Bravura', name}) {
      final file = File('$resourceDirectory/$font.xml');
      if (!file.existsSync()) continue;
      final xml = file.readAsStringSync();
      final unitsPerEm = double.tryParse(RegExp(r'units-per-em="([^"]+)"').firstMatch(xml)?.group(1) ?? '') ?? 1000;
      final perSpace = unitsPerEm / 4; // SMuFL: one em is four staff spaces
      for (final g in RegExp(r'<g ([^>]*)>').allMatches(xml)) {
        final attributes = {for (final a in RegExp(r'([\w-]+)="([^"]*)"').allMatches(g.group(1)!)) a.group(1)!: a.group(2)!};
        final code = int.tryParse(attributes['c'] ?? '', radix: 16);
        double? number(String key) => double.tryParse(attributes[key] ?? '');
        final (x, y, w, h) = (number('x'), number('y'), number('w'), number('h'));
        if (code == null || x == null || y == null || w == null || h == null) continue;
        glyphs[code] = (
          x: x / perSpace,
          y: y / perSpace,
          width: w / perSpace,
          height: h / perSpace,
          advance: (number('h-a-x') ?? x + w) / perSpace,
        );
      }
    }
    return glyphs;
  }

  /// Every option Verovio knows, with its type, default and range: what [EngraveOption]s are
  /// checked against.
  static Map<String, Object?> availableOptions({required String resourceDirectory}) =>
      native.availableOptions(resourceDirectory);

  /// Verovio's log as one message a line, without its "[Warning] " and "MusicXML import: "
  /// prefixes.
  static List<String> logMessages(String log) => [
        for (final line in const LineSplitter().convert(log))
          if (line.replaceFirst(RegExp(r'^\[(Warning|Error)\]\s*'), '').replaceFirst(RegExp(r'^MusicXML import:\s*'), '').trim()
              case final message when message.isNotEmpty)
            message,
      ];
}
