import 'dart:math' as math;
import 'dart:ui' as ui;

import 'display_list.dart';
import 'engraving.dart';
import 'native/bindings.dart' show VBKind;

/// The frozen zone at the left of every staff, like Dorico's galley view: the clef, key and
/// time signature currently in force stay visible while the music scrolls. A change takes over
/// the zone the moment it scrolls into the zone's right edge. Time signatures share one column
/// after the key signatures, so they line up down the whole score. The key column is only as
/// wide as the widest key signature of the staves shown ([KeyColumnPlan] animates it); a key
/// signature wider than the column (a staff fading out) slides under the time signature.
///
/// Signatures are redrawn from their musical meaning (not copied glyphs), so a clef change
/// engraved at cue size appears full size here, and key signatures are positioned for the
/// clef in force, as an engraver would.
class FrozenZone {
  FrozenZone(EngravingData data, this.style) {
    for (final sig in data.signatures) {
      switch (sig) {
        case ClefSignature():
          _clefs.putIfAbsent(sig.staff, () => []).add(sig);
        case KeySignature():
          _keys.putIfAbsent(sig.staff, () => []).add(sig);
        case TimeSignature():
          _meters.putIfAbsent(sig.staff, () => []).add(sig);
      }
    }
    for (final list in [..._clefs.values, ..._keys.values, ..._meters.values]) {
      list.sort((a, b) => a.x.compareTo(b.x));
    }
    // Staff lines as thick as the engraving's own, so the zone joins the scrolling staff seamlessly.
    final staffClass = data.classNames.indexOf('staff');
    for (var i = 0; i < data.commandCount; i++) {
      final base = i * Cmd.words;
      if (data.commandInts[base + Cmd.classIndex] != staffClass || data.commandInts[base + Cmd.kind] != VBKind.path) continue;
      final width = data.commandFloats[base + Cmd.strokeWidth];
      if (width > 0) {
        _lineThickness = width / data.staffSpace;
        break;
      }
    }
    for (final staff in data.staves) {
      _drawsKeys[staff.n] = staff.lines == 5 && !(_clefs[staff.n]?.every((c) => c.shape == ClefShape.percussion) ?? false);
    }
    maxKeyColumn = [
      for (final MapEntry(key: n, value: keys) in _keys.entries)
        if (_drawsKeys[n] ?? false) ...keys.map(_keyColumn)
    ].fold(0.0, math.max);
    _meterDigits = data.signatures.whereType<TimeSignature>().fold(
        0, (m, t) => math.max(m, t.symbol != null ? 1 : math.max(_numerator(t).length, '${t.unit}'.length)));

    // The opening clefs and keys are shown by the zone, so the score itself leaves them out.
    final firstOnset = data.measures.isEmpty || data.measures.first.onsetXs.isEmpty
        ? double.infinity
        : data.measures.first.onsetXs.first;
    _firstOnset = firstOnset;
    for (final list in [..._clefs.values, ..._keys.values, ..._meters.values]) {
      final first = list.first;
      if (first.x < firstOnset) {
        for (var i = first.commandStart; i < first.commandStart + first.commandCount; i++) {
          openingCommands.add(i);
        }
      }
    }
  }

  final RenderStyle style;
  final _clefs = <int, List<ClefSignature>>{};
  final _keys = <int, List<KeySignature>>{};
  final _meters = <int, List<TimeSignature>>{};
  final _drawsKeys = <int, bool>{}; // staff number → whether its key signatures are drawn
  late final int _meterDigits; // widest time signature, in glyphs (0: none in the piece)
  late final double _firstOnset;

  /// Recorded commands of the opening clefs/keys, to be left out of the scrolling score.
  final Set<int> openingCommands = {};

  // Layout in staff spaces.
  static const _padLeft = 0.8, _clefWidth = 2.8, _clefGap = 1.0, _sharpStep = 1.1, _flatStep = 1.0, _padRight = 1.4;
  static const _meterGap = 1.1, _digitWidth = 1.9;
  double _lineThickness = 0.13; // staff spaces; the engraving's own when it has staff lines
  static const _startLineThickness = 0.16;
  static const _braceWidth = 1.0, _braceGap = 0.35; // fits beside the names up to 10 px a staff space

  /// The widest key column in the piece, in staff spaces.
  late final double maxKeyColumn;

  /// Width of the zone in logical pixels with a key column [keyColumn] staff spaces wide.
  double widthFor(double keyColumn) => (_meterLeft(keyColumn) + _meterWidth + _padRight) * style.staffSpace;

  /// The widest the zone gets: with the widest key signature in the piece.
  double get maxWidth => widthFor(maxKeyColumn);

  /// Room a key signature takes after the clef, in staff spaces (none for no accidentals).
  static double _keyColumn(KeySignature key) =>
      key.fifths == 0 ? 0 : _clefGap + key.fifths.abs().clamp(0, 7) * (key.fifths > 0 ? _sharpStep : _flatStep);

  /// The widest key column staff [staff] needs while the zone's right edge is anywhere between
  /// score positions [from] and [to] (device units).
  double keyColumnIn(int staff, double from, double to) {
    final keys = _keys[staff];
    if (keys == null || !(_drawsKeys[staff] ?? false)) return 0;
    var widest = _keyColumnOrZero(stateAt(staff, from).key);
    for (final k in keys) {
      if (k.x > from && k.x <= to) widest = math.max(widest, _keyColumn(k));
    }
    return widest;
  }

  /// Each key change on staff [staff] (score position, device units) and the key column it
  /// needs before and after.
  Iterable<({double x, double before, double after})> keyColumnChanges(int staff) sync* {
    final keys = _keys[staff];
    if (keys == null || !(_drawsKeys[staff] ?? false)) return;
    for (final (i, k) in keys.indexed) {
      if (i == 0 && k.x < _firstOnset) continue; // the opening key: in force from the start
      final before = i == 0 ? 0.0 : _keyColumn(keys[i - 1]), after = _keyColumn(k);
      if (before != after) yield (x: k.x, before: before, after: after);
    }
  }

  static double _keyColumnOrZero(KeySignature? key) => key == null ? 0 : _keyColumn(key);

  /// Where the time signature column starts, and its width, in staff spaces from the zone's left.
  double _meterLeft(double keyColumn) => _padLeft + _clefWidth + keyColumn + (_meterDigits == 0 ? 0 : _meterGap);
  double get _meterWidth => _meterDigits * _digitWidth;

  ({ClefSignature? clef, KeySignature? key, TimeSignature? time}) stateAt(int staff, double x) {
    T? current<T extends Signature>(List<T>? list) {
      if (list == null || list.isEmpty) return null;
      // Before anything has passed the edge, only an opening signature applies; a staff
      // with no opening key (e.g. horns in C) shows none until its first key change.
      T? result = list.first.x < _firstOnset ? list.first : null;
      for (final s in list) {
        if (s.x > x) break;
        result = s;
      }
      return result;
    }

    return (clef: current(_clefs[staff]), key: current(_keys[staff]), time: current(_meters[staff]));
  }

  /// Paints one staff's zone: staff lines, a starting line, clef, key and time signature.
  /// [top] is the staff's top line in logical pixels, [scoreX] the score position at the
  /// zone's right edge (device units), [keyColumn] the key column's width in staff spaces.
  /// The staff lines run on to [linesTo] (where the scrolling staff begins, at the start of
  /// the piece) or through the fade.
  void paintStaff(ui.Canvas canvas, StaffInfo staff,
      {required double left,
      required double top,
      required double scoreX,
      required double keyColumn,
      required double fadeWidth,
      double linesTo = 0}) {
    final sp = style.staffSpace;
    final lines = math.max(1, staff.lines);
    final height = (lines - 1) * sp;
    final right = left + widthFor(keyColumn);
    final ink = ui.Paint()..color = style.ink;

    // Staff lines through the zone and the fade, so they join the scrolling staff seamlessly.
    final lineThickness = _lineThickness * sp;
    for (var i = 0; i < lines; i++) {
      final y = top + i * sp;
      canvas.drawRect(
          ui.Rect.fromLTRB(left, y - lineThickness / 2, math.max(right + fadeWidth, linesTo), y + lineThickness / 2), ink);
    }
    final reach = lines == 1 ? sp : 0.0;
    canvas.drawRect(
      ui.Rect.fromLTWH(left, top - reach - lineThickness / 2, _startLineThickness * sp, height + 2 * reach + lineThickness),
      ink,
    );

    final state = stateAt(staff.n, scoreX);
    final time = state.time;
    if (time != null) _paintTime(canvas, time, left + (_meterLeft(keyColumn) + _meterWidth / 2) * sp, top + (lines - 1) * sp / 2);
    final clef = state.clef;
    var x = left + _padLeft * sp;
    if (clef != null) {
      final glyph = _clefGlyph(clef);
      if (glyph != null) {
        final line = clef.shape == ClefShape.percussion || lines == 1 ? (lines + 1) / 2 : clef.line.toDouble();
        _drawGlyph(canvas, glyph, x, top + (lines - line) * sp);
      }
    }
    final columnLeft = x + _clefWidth * sp;
    x = columnLeft + _clefGap * sp;

    final key = state.key;
    if (key == null || key.fifths == 0 || lines != 5 || clef?.shape == ClefShape.percussion) return;
    // Wider than the column while the column closes: cut off where the column ends.
    final cut = _keyColumn(key) > keyColumn + 1e-6;
    if (cut) {
      canvas.save();
      canvas.clipRect(ui.Rect.fromLTRB(left, top - 4 * sp, columnLeft + keyColumn * sp, top + height + 4 * sp));
    }
    final steps = _keySteps(key.fifths, clef);
    for (final step in steps) {
      _drawGlyph(canvas, key.fifths > 0 ? 0xE262 : 0xE260, x, top + height - step * sp / 2);
      x += (key.fifths > 0 ? _sharpStep : _flatStep) * sp;
    }
    if (cut) canvas.restore();
  }

  /// A brace just left of the zone at [left] joining one instrument's [staves] (top line and
  /// height, logical pixels, top to bottom), and the starting line run on between them.
  /// Bravura's brace is one em (four staff spaces) tall and 0.08 em wide (2 to 82 of 1000
  /// units): it is stretched to the staves and kept one staff space wide, as Verovio does.
  void paintBrace(ui.Canvas canvas, {required double left, required List<({double top, double height})> staves}) {
    if (staves.length < 2) return;
    final sp = style.staffSpace;
    final ink = ui.Paint()..color = style.ink;
    // Only between the staves: each staff draws its own stretch, and drawn twice a line comes out heavier.
    for (var i = 1; i < staves.length; i++) {
      final above = staves[i - 1];
      canvas.drawRect(ui.Rect.fromLTRB(left, above.top + above.height, left + _startLineThickness * sp, staves[i].top), ink);
    }
    final top = staves.first.top, bottom = staves.last.top + staves.last.height;
    final em = 4 * sp;
    canvas.save();
    canvas.translate(left - (_braceGap + _braceWidth) * sp, bottom);
    canvas.scale(_braceWidth * sp / (0.080 * em), (bottom - top) / (0.997 * em));
    _drawGlyph(canvas, 0xE000, -0.002 * em, 0);
    canvas.restore();
  }

  /// A time signature centred on [centerX]: the two numbers either side of the middle line,
  /// or common / cut time on it. SMuFL time signature digits are centred on their baseline.
  void _paintTime(ui.Canvas canvas, TimeSignature time, double centerX, double middleY) {
    final sp = style.staffSpace;
    if (time.symbol != null) {
      _drawCentered(canvas, String.fromCharCode(time.symbol!), centerX, middleY);
    } else if (time.count > 0 && time.unit > 0) {
      _drawCentered(canvas, _numerator(time), centerX, middleY - sp);
      _drawCentered(canvas, _digits(time.unit), centerX, middleY + sp);
    }
  }

  /// SMuFL time signature digits for [n].
  static String _digits(int n) => String.fromCharCodes('$n'.codeUnits.map((c) => 0xE080 + c - 0x30));

  /// The upper number as written: "2+2+3" for an additive meter.
  static String _numerator(TimeSignature time) => time.summands.length > 1
      ? time.summands.map(_digits).join(String.fromCharCode(0xE08C)) // timeSigPlus
      : _digits(time.count);

  void _drawCentered(ui.Canvas canvas, String text, double centerX, double baselineY) {
    final paragraph = _paragraph(text);
    canvas.drawParagraph(paragraph, ui.Offset(centerX - paragraph.longestLine / 2, baselineY - paragraph.alphabeticBaseline));
  }

  static int? _clefGlyph(ClefSignature clef) => switch ((clef.shape, clef.octave)) {
        (ClefShape.g || ClefShape.gg, -2) => 0xE051,
        (ClefShape.g || ClefShape.gg, -1) => 0xE052,
        (ClefShape.g || ClefShape.gg, 1) => 0xE053,
        (ClefShape.g || ClefShape.gg, 2) => 0xE054,
        (ClefShape.g || ClefShape.gg, _) => 0xE050,
        (ClefShape.f, -2) => 0xE063,
        (ClefShape.f, -1) => 0xE064,
        (ClefShape.f, 1) => 0xE065,
        (ClefShape.f, 2) => 0xE066,
        (ClefShape.f, _) => 0xE062,
        (ClefShape.c, -1) => 0xE05D,
        (ClefShape.c, _) => 0xE05C,
        (ClefShape.percussion, _) => 0xE069,
        (ClefShape.tab, _) => 0xE06D,
        _ => null,
      };

  /// Staff steps (0 = bottom line, 2 per staff space) of each accidental, in order.
  /// Treble-clef patterns shifted to the clef in force; tenor clef sharps follow their
  /// traditional low pattern.
  static List<int> _keySteps(int fifths, ClefSignature? clef) {
    const trebleSharps = [8, 5, 9, 6, 3, 7, 4];
    const trebleFlats = [4, 7, 3, 6, 2, 5, 1];
    const tenorSharps = [2, 6, 3, 7, 4, 8, 5];
    final count = fifths.abs().clamp(0, 7);
    if (fifths > 0 && clef?.shape == ClefShape.c && clef?.line == 4) return tenorSharps.sublist(0, count);

    // Shift = how many steps the treble pattern moves for this clef, reduced to -3…3.
    var shift = 0;
    if (clef != null) {
      const e4 = 30; // diatonic index of the treble clef's bottom line
      final reference = switch (clef.shape) {
        ClefShape.f => 24, // F3
        ClefShape.c => 28, // C4
        _ => 32, // G4
      };
      final bottom = reference - 2 * (clef.line - 1);
      shift = (e4 - bottom) % 7;
      if (shift > 3) shift -= 7;
    }
    return [for (final s in (fifths > 0 ? trebleSharps : trebleFlats).take(count)) s + shift];
  }

  final _glyphs = <String, ui.Paragraph>{};

  void dispose() {
    for (final paragraph in _glyphs.values) {
      paragraph.dispose();
    }
    _glyphs.clear();
  }

  ui.Paragraph _paragraph(String text) => _glyphs.putIfAbsent(text, () {
        final size = 4 * style.staffSpace; // SMuFL: one em is four staff spaces
        final builder = ui.ParagraphBuilder(ui.ParagraphStyle(fontFamily: style.musicFontFamily, fontSize: size))
          ..pushStyle(ui.TextStyle(
              color: style.ink,
              fontFamily: style.musicFontFamily,
              fontFamilyFallback: RenderStyle.musicFontFallback,
              fontSize: size))
          ..addText(text);
        return builder.build()..layout(ui.ParagraphConstraints(width: size * 4));
      });

  void _drawGlyph(ui.Canvas canvas, int codepoint, double x, double baselineY) {
    final paragraph = _paragraph(String.fromCharCode(codepoint));
    canvas.drawParagraph(paragraph, ui.Offset(x, baselineY - paragraph.alphabeticBaseline));
  }
}
