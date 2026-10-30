import 'dart:convert';
import 'dart:typed_data';

import 'engraving.dart';

/// An engraving saved as one file, for where there is no engraver (a web page shows a score
/// engraved beforehand): `CCEN`, a version, then four parts, each its length (4 bytes, little
/// endian) and its bytes: the rest of [EngravingData] as JSON, then the recorded commands, the
/// path elements and the text as they are.
abstract final class EngravingFile {
  static const _magic = [0x43, 0x43, 0x45, 0x4E]; // CCEN
  static const version = 1;

  static Uint8List write(EngravingData e) {
    final json = utf8.encode(jsonEncode({
      'width': e.width,
      'staffSpace': e.staffSpace,
      'staves': [for (final s in e.staves) [s.n, s.top, s.height, s.lines]],
      'measures': [
        for (final m in e.measures) [m.left, m.right, m.duration, m.onsetTimes, m.onsetXs],
      ],
      'classNames': e.classNames,
      'fontNames': e.fontNames,
      'sourceIds': e.sourceIds,
      'warnings': e.warnings,
      'signatures': [
        for (final s in e.signatures)
          [
            s.staff, s.x, s.commandStart, s.commandCount,
            ...switch (s) {
              ClefSignature() => ['clef', s.shape.index, s.line, s.octave],
              KeySignature() => ['key', s.fifths],
              TimeSignature() => ['time', s.count, s.unit, s.symbol, s.summands],
            },
          ],
      ],
      'glyphs': {
        for (final MapEntry(key: c, value: g) in e.glyphs.entries) '$c': [g.x, g.y, g.width, g.height, g.advance],
      },
      'engravingDefaults': e.engravingDefaults,
    }));
    Uint8List bytesOf(TypedData d) => d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
    final parts = [json, bytesOf(e.commandInts), bytesOf(e.pathInts), e.text];
    final out = BytesBuilder(copy: false)
      ..add(_magic)
      ..add(_u32(version));
    for (final p in parts) {
      out
        ..add(_u32(p.length))
        ..add(p);
    }
    return out.takeBytes();
  }

  /// Reads what [write] wrote. Throws a [FormatException] when it isn't that.
  static EngravingData read(Uint8List bytes) {
    final view = ByteData.sublistView(bytes);
    var at = 0;
    int u32() {
      if (at + 4 > bytes.length) throw const FormatException('The engraving is cut short.');
      return view.getUint32((at += 4) - 4, Endian.little);
    }

    Uint8List part() {
      final length = u32();
      if (length > bytes.length - at) throw const FormatException('The engraving is cut short.');
      // A copy of its own, so the int and float views of it are aligned.
      return Uint8List.fromList(Uint8List.sublistView(bytes, at, at += length));
    }

    if (bytes.length < 8 || !Iterable.generate(4).every((i) => bytes[i] == _magic[i])) {
      throw const FormatException('This isn’t an engraving.');
    }
    at = 4;
    if (u32() != version) throw const FormatException('The engraving is from another version.');
    final header = part(), commands = part(), paths = part(), text = part();
    if (commands.length % (Cmd.words * 4) != 0 || paths.length % (7 * 4) != 0) {
      throw const FormatException('The engraving is damaged.');
    }
    try {
      final j = jsonDecode(utf8.decode(header)) as Map<String, Object?>;
      double d(Object? v) => (v as num).toDouble();
      List<Object?> list(Object? v) => v as List<Object?>;
      List<String> strings(Object? v) => [for (final s in list(v)) s as String];
      return EngravingData(
        width: d(j['width']),
        staffSpace: d(j['staffSpace']),
        staves: [
          for (final s in list(j['staves']).map(list))
            StaffInfo(n: s[0] as int, top: d(s[1]), height: d(s[2]), lines: s[3] as int),
        ],
        measures: [
          for (final m in list(j['measures']).map(list))
            MeasureLayout(
              left: d(m[0]),
              right: d(m[1]),
              duration: d(m[2]),
              onsetTimes: Float64List.fromList([for (final t in list(m[3])) d(t)]),
              onsetXs: Float64List.fromList([for (final x in list(m[4])) d(x)]),
            ),
        ],
        commandBytes: commands,
        pathBytes: paths,
        text: text,
        classNames: strings(j['classNames']),
        fontNames: strings(j['fontNames']),
        sourceIds: strings(j['sourceIds']),
        warnings: List.unmodifiable(strings(j['warnings'])),
        signatures: [
          for (final s in list(j['signatures']).map(list))
            switch (s[4]) {
              'clef' => ClefSignature(
                  staff: s[0] as int,
                  x: d(s[1]),
                  commandStart: s[2] as int,
                  commandCount: s[3] as int,
                  shape: ClefShape.values[s[5] as int],
                  line: s[6] as int,
                  octave: s[7] as int,
                ),
              'key' => KeySignature(staff: s[0] as int, x: d(s[1]), commandStart: s[2] as int, commandCount: s[3] as int, fifths: s[5] as int),
              _ => TimeSignature(
                  staff: s[0] as int,
                  x: d(s[1]),
                  commandStart: s[2] as int,
                  commandCount: s[3] as int,
                  count: s[5] as int,
                  unit: s[6] as int,
                  symbol: s[7] as int?,
                  summands: [for (final n in list(s[8])) n as int],
                ),
            },
        ],
        glyphs: Map.unmodifiable({
          for (final MapEntry(:key, :value) in (j['glyphs'] as Map<String, Object?>).entries)
            if (list(value) case [final x, final y, final w, final h, final a])
              int.parse(key): (x: d(x), y: d(y), width: d(w), height: d(h), advance: d(a)),
        }),
        engravingDefaults: Map.unmodifiable({
          for (final MapEntry(:key, :value) in (j['engravingDefaults'] as Map<String, Object?>).entries) key: d(value),
        }),
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      // A wrong type or a missing field: TypeError, RangeError.
      throw const FormatException('The engraving is damaged.');
    }
  }

  static Uint8List _u32(int n) => Uint8List(4)..buffer.asByteData().setUint32(0, n, Endian.little);
}
