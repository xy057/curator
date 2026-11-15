import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'engraving.dart';
import 'lilypond_svg.dart';
import 'native/constants.dart';

/// Builds the recorded commands of an engraving that isn't Verovio's: a LilyPond score's
/// shapes and text, a MIDI score's rows.
class CommandWriter {
  CommandWriter();

  /// One that adds to [data]'s commands.
  factory CommandWriter.from(EngravingData data) {
    final w = CommandWriter();
    w._ints.addAll(data.commandInts);
    w._paths.addAll(data.pathInts);
    w._text.add(data.text);
    w.classNames.addAll(data.classNames);
    w.sourceIds.addAll(data.sourceIds);
    return w;
  }

  // The words as ints; floats are stored as their bits.
  final _ints = <int>[];
  final _paths = <int>[];
  final _text = BytesBuilder(copy: false);
  final classNames = <String>[];
  final sourceIds = <String>[];

  /// The fonts its text names (a LilyPond score's: the one it was spaced in).
  List<String> fontNames = const ['serif'];
  static final _bits = ByteData(4);

  int get count => _ints.length ~/ Cmd.words;

  static int _f(double v) => (_bits..setFloat32(0, v)).getInt32(0);

  int classOf(String name) {
    final i = classNames.indexOf(name);
    if (i >= 0) return i;
    classNames.add(name);
    return classNames.length - 1;
  }

  int sourceOf(String? id) {
    if (id == null) return -1;
    final i = sourceIds.indexOf(id);
    if (i >= 0) return i;
    sourceIds.add(id);
    return sourceIds.length - 1;
  }

  void _command({
    required int kind,
    required int staff,
    required int flags,
    required int classIndex,
    double strokeWidth = 0,
    double dash = 0,
    double gap = 0,
    double x = 0,
    double y = 0,
    double size = 0,
    int alignment = 0,
    int start = 0,
    int count = 0,
    ui.Rect bounds = ui.Rect.zero,
    int source = -1,
    double fitWidth = 0,
    double fade = 0,
  }) {
    _ints.addAll([
      kind, staff, flags, classIndex, _f(strokeWidth), _f(dash), _f(gap), _f(x), _f(y), _f(size), 0, alignment, start, count, 0, //
      _f(bounds.left), _f(bounds.top), _f(bounds.width), _f(bounds.height), source, _f(fitWidth), _f(fade),
    ]);
  }

  void path(int staff, int classIndex, LilyPath p, {int source = -1}) {
    final start = _paths.length ~/ 7;
    for (var i = 0; i < p.ops.length; i++) {
      _paths.add(p.ops[i]);
      for (var k = 0; k < 6; k++) {
        _paths.add(_f(p.points[i * 6 + k]));
      }
    }
    _command(
        kind: VBKind.path,
        staff: staff,
        flags: (p.fill ? VBFlag.fill : 0) | (p.stroke ? VBFlag.stroke | p.flags : 0),
        classIndex: classIndex,
        strokeWidth: p.width,
        dash: p.dash,
        gap: p.gap,
        start: start,
        count: p.ops.length,
        bounds: p.bounds,
        source: source);
  }

  /// A plain stroke from ([x0], [y]) to ([x1], [y]): what the display list takes for a staff line.
  void line(int staff, String className, double x0, double y, double x1, double width) {
    final start = _paths.length ~/ 7;
    _paths.addAll([VBPathOp.move, _f(x0), _f(y), 0, 0, 0, 0, VBPathOp.line, _f(x1), _f(y), 0, 0, 0, 0]);
    _command(
        kind: VBKind.path,
        staff: staff,
        flags: VBFlag.stroke,
        classIndex: classOf(className),
        strokeWidth: width,
        start: start,
        count: 2,
        bounds: ui.Rect.fromLTRB(x0, y - width / 2, x1, y + width / 2));
  }

  /// [rect] filled, its ink [fade] lighter (0: as it is, 1: gone; [Cmd.fade]).
  void rect(int staff, int classIndex, ui.Rect rect, {double fade = 0}) {
    final start = _paths.length ~/ 7;
    final l = _f(rect.left), t = _f(rect.top), r = _f(rect.right), b = _f(rect.bottom);
    _paths.addAll([
      VBPathOp.move, l, t, 0, 0, 0, 0, VBPathOp.line, r, t, 0, 0, 0, 0, VBPathOp.line, r, b, 0, 0, 0, 0, VBPathOp.line, l, b, 0, 0, 0, 0, //
      VBPathOp.close, 0, 0, 0, 0, 0, 0,
    ]);
    _command(kind: VBKind.path, staff: staff, flags: VBFlag.fill, classIndex: classIndex, start: start, count: 5, bounds: rect, fade: fade);
  }

  /// [t], drawn no wider than [fitWidth] (0: any).
  void text(int staff, int classIndex, LilyText t, {int source = -1, double fitWidth = 0}) {
    final bytes = utf8.encode(t.text);
    final start = _text.length;
    _text.add(bytes);
    _command(
        kind: VBKind.text,
        staff: staff,
        flags: VBFlag.newTextBlock | (t.italic ? VBFlag.italic : 0) | (t.bold ? VBFlag.bold : 0),
        classIndex: classIndex,
        x: t.x,
        y: t.y,
        size: t.size,
        alignment: t.anchor,
        start: start,
        count: bytes.length,
        bounds: t.bounds,
        source: source,
        fitWidth: fitWidth);
  }

  /// [data]'s command [i] again, on [staff], [dy] lower.
  void copy(EngravingData data, int i, {required int staff, required double dy}) {
    final base = i * Cmd.words;
    final words = [for (var k = 0; k < Cmd.words; k++) data.commandInts[base + k]];
    words[Cmd.staff] = staff;
    double float(int k) => data.commandFloats[base + k];
    words[Cmd.y] = _f(float(Cmd.y) + dy);
    words[Cmd.bounds + 1] = _f(float(Cmd.bounds + 1) + dy);
    if (data.commandInts[base + Cmd.kind] == VBKind.path) {
      final start = data.commandInts[base + Cmd.start], count = data.commandInts[base + Cmd.count];
      words[Cmd.start] = _paths.length ~/ 7;
      for (var e = start; e < start + count; e++) {
        final op = data.pathInts[e * 7];
        _paths.add(op);
        for (var k = 0; k < 6; k++) {
          final v = data.pathFloats[e * 7 + 1 + k];
          // The y of each point (an ellipse's box: its top).
          _paths.add(_f(k.isOdd && (op != VBPathOp.ellipse || k == 1) ? v + dy : v));
        }
      }
    } else if (data.commandInts[base + Cmd.kind] == VBKind.text) {
      final bytes = data.text.sublist(data.commandInts[base + Cmd.start], data.commandInts[base + Cmd.start] + data.commandInts[base + Cmd.count]);
      words[Cmd.start] = _text.length;
      _text.add(bytes);
    }
    _ints.addAll(words);
  }

  /// The engraving of what was written, [staffSpace] device units a staff space; what isn't
  /// given is [like]'s.
  EngravingData build(EngravingData? like,
      {required double staffSpace,
      double? width,
      List<StaffInfo>? staves,
      List<MeasureLayout>? measures,
      List<Signature>? signatures,
      List<String>? warnings,
      Map<String, double>? engravingDefaults}) {
    final commands = Uint8List(_ints.length * 4), paths = Uint8List(_paths.length * 4);
    commands.buffer.asInt32List().setAll(0, _ints);
    paths.buffer.asInt32List().setAll(0, _paths);
    return EngravingData(
      width: width ?? like!.width,
      staffSpace: staffSpace,
      staves: staves ?? like!.staves,
      measures: measures ?? like!.measures,
      commandBytes: commands,
      pathBytes: paths,
      text: _text.toBytes(),
      classNames: List.unmodifiable(classNames),
      fontNames: fontNames,
      signatures: List.unmodifiable(signatures ?? like!.signatures),
      sourceIds: List.unmodifiable(sourceIds),
      warnings: warnings ?? like!.warnings,
      engravingDefaults: engravingDefaults ?? like?.engravingDefaults ?? const {},
    );
  }
}
