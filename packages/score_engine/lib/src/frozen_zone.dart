import 'dart:math' as math;
import 'dart:ui' as ui;

import 'display_list.dart';
import 'engraving.dart';
import 'native/constants.dart' show VBKind;
import 'score_typography.dart';

/// The frozen zone at the left of every staff, like Dorico's galley view: the clef, key and
/// time signature currently in force stay visible while the music scrolls. A change takes over
/// the zone the moment it scrolls into the zone's right edge. Time signatures share one column
/// after the key signatures, so they line up down the whole score. The key column is only as
/// wide as the widest key signature of the staves shown ([KeyColumnPlan] animates it); a key
/// signature wider than the column (a staff fading out) slides under the time signature.
///
/// Signatures are redrawn from their musical meaning (not copied glyphs), so a clef change
/// engraved at cue size appears full size here, and key signatures are positioned for the
/// clef in force, as an engraver would. Each is the size [typography] sets, as engraved.
class FrozenZone {
  FrozenZone(EngravingData data, this.style, {ScoreTypography typography = ScoreTypography.standard})
      : _clefScale = typography[TextKind.clefs].size,
        _keyScale = typography[TextKind.keySignatures].size,
        _timeScale = typography[TextKind.timeSignatures].size,
        _clefWidth = _scaled(data, 2.8, [0xE050, 0xE05C, 0xE062]) * typography[TextKind.clefs].size,
        _sharpStep = _scaled(data, 1.1, [0xE262]) * typography[TextKind.keySignatures].size,
        _flatStep = _scaled(data, 1.0, [0xE260]) * typography[TextKind.keySignatures].size,
        _digitWidth = _scaled(data, 1.9, [for (var c = 0xE080; c <= 0xE089; c++) c]) * typography[TextKind.timeSignatures].size,
        _lineThickness = data.engravingDefaults['staffLineThickness'] ?? 0.13,
        _startLineThickness = data.engravingDefaults['thinBarlineThickness'] ?? 0.16,
        _bracketThickness = data.engravingDefaults['bracketThickness'] ?? 0.5,
        _brace = data.glyphs[0xE000] ?? _bravuraBrace,
        _boxes = data.glyphs {
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

  // Layout in staff spaces. The glyphs' room is Bravura's, in proportion to this font's
  // glyphs (a wider sharp, a wider step); the lines are as thick as the engraving's.
  static const _padLeft = 0.8, _clefGap = 1.0, _padRight = 1.4, _meterGap = 1.1;
  final double _clefWidth, _sharpStep, _flatStep, _digitWidth;
  final double _clefScale, _keyScale, _timeScale; // their glyphs' size, a share of the staff's
  double _lineThickness; // the engraving's own staff lines when it has them
  final double _startLineThickness; // a thin barline's
  final double _bracketThickness;
  final GlyphBox _brace;
  final Map<int, GlyphBox> _boxes;

  /// Bravura's [value], for glyphs as wide as the widest of [codepoints] in this font.
  static double _scaled(EngravingData data, double value, List<int> codepoints) {
    double? widest(Map<int, GlyphBox> glyphs) =>
        codepoints.map((c) => glyphs[c]?.advance).nonNulls.fold<double?>(null, (m, a) => m == null ? a : math.max(m, a));
    final own = widest(data.glyphs), bravura = widest(_bravuraGlyphs);
    return own == null || bravura == null ? value : value * own / bravura;
  }

  /// The advances [_scaled] measures against, and Bravura's brace (from Bravura.xml).
  static const Map<int, GlyphBox> _bravuraGlyphs = {
    0xE050: (x: 0, y: 0, width: 0, height: 0, advance: 671 / 250),
    0xE05C: (x: 0, y: 0, width: 0, height: 0, advance: 699 / 250),
    0xE062: (x: 0, y: 0, width: 0, height: 0, advance: 684 / 250),
    0xE262: (x: 0, y: 0, width: 0, height: 0, advance: 249 / 250),
    0xE260: (x: 0, y: 0, width: 0, height: 0, advance: 226 / 250),
    0xE080: (x: 0, y: 0, width: 0, height: 0, advance: 470 / 250), // the widest digits, 0 and 4
  };
  static const GlyphBox _bravuraBrace = (x: 2 / 250, y: 0, width: 80 / 250, height: 997 / 250, advance: 84 / 250);
  static const _braceWidth = 1.0, _braceGap = 0.35; // fits beside the names up to 10 px a staff space
  static const _bracketGap = 0.25;

  /// The widest key column in the piece, in staff spaces.
  late final double maxKeyColumn;

  /// Width of the zone in logical pixels with a key column [keyColumn] staff spaces wide.
  double widthFor(double keyColumn) => (_meterLeft(keyColumn) + _meterWidth + _padRight) * style.staffSpace;

  /// The widest the zone gets: with the widest key signature in the piece.
  double get maxWidth => widthFor(maxKeyColumn);

  /// Room a key signature takes after the clef, in staff spaces (none for no accidentals).
  double _keyColumn(KeySignature key) =>
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

  double _keyColumnOrZero(KeySignature? key) => key == null ? 0 : _keyColumn(key);

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
        _drawGlyph(canvas, glyph, x, top + (lines - line) * sp, _clefScale);
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
      _drawGlyph(canvas, key.fifths > 0 ? 0xE262 : 0xE260, x, top + height - step * sp / 2, _keyScale);
      x += (key.fifths > 0 ? _sharpStep : _flatStep) * sp;
    }
    if (cut) canvas.restore();
  }

  /// A brace just left of the zone at [left] joining one instrument's [staves] (top line and
  /// height, logical pixels, top to bottom), and the starting line run on between them.
  /// The font's brace (Bravura's is one em tall and 0.08 em wide) is stretched to the staves
  /// and kept one staff space wide, as Verovio does.
  void paintBrace(ui.Canvas canvas, {required double left, required List<({double top, double height})> staves}) {
    if (staves.length < 2) return;
    final sp = style.staffSpace;
    for (var i = 1; i < staves.length; i++) {
      paintJoin(canvas, left: left, top: staves[i - 1].top + staves[i - 1].height, bottom: staves[i].top);
    }
    final top = staves.first.top, bottom = staves.last.top + staves.last.height;
    final brace = _brace;
    canvas.save();
    canvas.translate(left - (_braceGap + _braceWidth) * sp, bottom);
    canvas.scale(_braceWidth / brace.width, (bottom - top) / (brace.height * sp));
    _drawGlyph(canvas, 0xE000, -brace.x * sp, brace.y * sp); // its ink's lower left corner at the origin
    canvas.restore();
  }

  /// The starting line at [left] run on between two staves, from [top] (the bottom line of the
  /// one above) to [bottom] (the top line of the one below): only between them, as each staff
  /// draws its own stretch, and drawn twice a line comes out heavier.
  void paintJoin(ui.Canvas canvas, {required double left, required double top, required double bottom}) {
    if (bottom <= top) return;
    canvas.drawRect(
        ui.Rect.fromLTRB(left, top, left + _startLineThickness * style.staffSpace, bottom), ui.Paint()..color = style.ink);
  }

  /// How far left of the zone a bracket reaches, logical pixels (see [paintBracket]).
  double bracketReach({bool outset = false}) =>
      (_bracketGap + _bracketThickness + (outset ? _braceGap + _braceWidth : 0)) * style.staffSpace;

  /// A section's bracket just left of the zone at [left], from [top] (its first staff's top
  /// line) to [bottom] (its last staff's bottom line): a line as thick as the font's
  /// `bracketThickness`, with the font's hooks curling over the staves at its ends.
  /// [outset]: set further left, clear of the braces.
  void paintBracket(ui.Canvas canvas, {required double left, required double top, required double bottom, bool outset = false}) {
    final sp = style.staffSpace;
    final x = left - bracketReach(outset: outset);
    canvas.drawRect(ui.Rect.fromLTRB(x, top, x + _bracketThickness * sp, bottom), ui.Paint()..color = style.ink);
    _drawGlyph(canvas, 0xE003, x, top); // bracketTop: its ink above the baseline
    _drawGlyph(canvas, 0xE004, x, bottom); // bracketBottom: below it
  }

  /// A time signature centred on [centerX]: the two numbers either side of the middle line,
  /// or common / cut time on it. SMuFL time signature digits are centred on their baseline:
  /// a staff space above and below the middle line, or meeting on it when they are taller
  /// than two (a handwritten font's, as Verovio stacks Petaluma's).
  void _paintTime(ui.Canvas canvas, TimeSignature time, double centerX, double middleY) {
    final sp = style.staffSpace * _timeScale;
    double offset(String digits) =>
        math.max(1.0, digits.runes.map((c) => (_boxes[c]?.height ?? 2) / 2).fold(0.0, math.max)) * sp;
    if (time.symbol != null) {
      _drawCentered(canvas, String.fromCharCode(time.symbol!), centerX, middleY);
    } else if (time.count > 0 && time.unit > 0) {
      final numerator = _numerator(time), denominator = _digits(time.unit);
      _drawCentered(canvas, numerator, centerX, middleY - offset(numerator));
      _drawCentered(canvas, denominator, centerX, middleY + offset(denominator));
    }
  }

  /// SMuFL time signature digits for [n].
  static String _digits(int n) => String.fromCharCodes('$n'.codeUnits.map((c) => 0xE080 + c - 0x30));

  /// The upper number as written: "2+2+3" for an additive meter.
  static String _numerator(TimeSignature time) => time.summands.length > 1
      ? time.summands.map(_digits).join(String.fromCharCode(0xE08C)) // timeSigPlus
      : _digits(time.count);

  void _drawCentered(ui.Canvas canvas, String text, double centerX, double baselineY) {
    final paragraph = _paragraph(text, _timeScale);
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

  final _glyphs = <(String, double), ui.Paragraph>{};

  void dispose() {
    for (final paragraph in _glyphs.values) {
      paragraph.dispose();
    }
    _glyphs.clear();
  }

  /// [text] in the music font at [scale] × the staff's size.
  ui.Paragraph _paragraph(String text, [double scale = 1]) => _glyphs.putIfAbsent((text, scale), () {
        final size = 4 * style.staffSpace * scale; // SMuFL: one em is four staff spaces
        final builder = ui.ParagraphBuilder(ui.ParagraphStyle(fontFamily: style.musicFontFamily, fontSize: size))
          ..pushStyle(ui.TextStyle(
              color: style.ink,
              fontFamily: style.musicFontFamily,
              fontFamilyFallback: RenderStyle.musicFontFallback,
              fontSize: size))
          ..addText(text);
        return builder.build()..layout(ui.ParagraphConstraints(width: size * 4));
      });

  void _drawGlyph(ui.Canvas canvas, int codepoint, double x, double baselineY, [double scale = 1]) {
    final paragraph = _paragraph(String.fromCharCode(codepoint), scale);
    canvas.drawParagraph(paragraph, ui.Offset(x, baselineY - paragraph.alphabeticBaseline));
  }
}
