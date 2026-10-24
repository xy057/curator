import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

/// A text's face: its slant and weight. [asWritten] keeps what the score file says (texts
/// Verovio engraves only).
enum TextFace {
  asWritten('As written'),
  regular('Regular'),
  italic('Italic'),
  bold('Bold'),
  boldItalic('Bold Italic');

  const TextFace(this.label);
  final String label;

  bool get isItalic => this == italic || this == boldItalic;
  bool get isBold => this == bold || this == boldItalic;
  ui.FontStyle get fontStyle => isItalic ? ui.FontStyle.italic : ui.FontStyle.normal;
  ui.FontWeight get fontWeight => isBold ? ui.FontWeight.bold : ui.FontWeight.normal;

  static TextFace? named(Object? name) => values.where((f) => f.name == name).firstOrNull;
}

/// The kinds of text in the score, each set on its own (Project Settings ▸ Typography). The
/// first four are drawn by the scene and change nothing but the drawing; the rest Verovio
/// engraves, so changing them engraves again, and the music makes room for them. The last are
/// the music font's (SMuFL) symbols, with fingering and chord symbols (the text font's, their
/// accidentals the music font's): only their size is theirs.
enum TextKind {
  names('Names', TextLook()),
  barNumbers('Bar numbers', TextLook(face: TextFace.italic, opacity: 0.5)),
  tempoRow('Tempo at left', TextLook(face: TextFace.italic)),
  captions('Captions', captionsHouse),
  tempo('Tempo marks', TextLook(face: TextFace.asWritten), engraved: true),
  expressions('Expressions', TextLook(face: TextFace.asWritten), engraved: true),
  rehearsal('Rehearsal marks', TextLook(face: TextFace.asWritten), engraved: true),
  lyrics('Lyrics', TextLook(face: TextFace.asWritten), engraved: true),
  clefs.symbol('Clefs', 'curatedClefScale'),
  keySignatures.symbol('Key signatures', 'curatedKeySigScale'),
  timeSignatures.symbol('Time signatures', 'curatedMeterSigScale'),
  noteheads.symbol('Noteheads', 'curatedNoteheadScale'),
  flags.symbol('Flags', 'curatedFlagScale'),
  dots.symbol('Dots', 'curatedDotScale'),
  rests.symbol('Rests', 'curatedRestScale'),
  accidentals.symbol('Accidentals', 'curatedAccidScale'),
  articulations.symbol('Articulations', 'curatedArticScale'),
  dynamics.symbol('Dynamics', 'curatedDynamScale'),
  ornaments.symbol('Ornaments', 'curatedOrnamentScale'),
  fermatas.symbol('Fermatas', 'curatedFermataScale'),
  breathMarks.symbol('Breath marks', 'curatedBreathScale'),
  tremolos.symbol('Tremolos', 'curatedTremScale'),
  arpeggios.symbol('Arpeggios', 'curatedArpegScale'),
  tupletNumbers.symbol('Tuplet numbers', 'curatedTupletNumScale'),
  fingering.symbol('Fingering', 'curatedFingScale'),
  chordSymbols.symbol('Chord symbols', 'curatedHarmScale'),
  pedal.symbol('Pedal marks', 'curatedPedalScale'),
  octave.symbol('Octave marks', 'curatedOctaveScale'),
  barRepeats.symbol('Bar repeats', 'curatedMRptScale'),
  segnoCoda.symbol('Segno and coda', 'curatedRepeatMarkScale');

  const TextKind(this.label, this.house, {this.engraved = false}) : verovioScale = null;
  const TextKind.symbol(this.label, String this.verovioScale)
      : house = const TextLook(face: TextFace.asWritten),
        engraved = true;

  /// [captions]' house look, for a default value.
  static const captionsHouse = TextLook(tracking: 0.01);
  final String label;

  /// How it looks in the house style.
  final TextLook house;

  /// Engraved by Verovio: a face may be [TextFace.asWritten], and there is no opacity (the
  /// engraving is all one ink).
  final bool engraved;

  /// For a music-font symbol, the patched Verovio's option scaling its size (and nothing else:
  /// the font has one face, and its symbols are set glyph by glyph).
  final String? verovioScale;
  bool get isSymbol => verovioScale != null;
}

/// How one kind of text looks: its [size] as a share of the house size (the names' 13 points,
/// the bar numbers' 1.3 staff spaces, a caption's Small / Medium / Large, the engraving's text
/// size for the rest), its [face], [tracking] (letter spacing, ems) and [opacity].
@immutable
class TextLook {
  const TextLook({this.size = 1, this.face = TextFace.regular, this.tracking = 0, this.opacity = 1});
  final double size;
  final TextFace face;
  final double tracking;
  final double opacity;

  /// Each property's key in the JSON, and its range for numbers.
  static const ranges = <String, ({double min, double max})>{
    'size': (min: 0.5, max: 2.5),
    'tracking': (min: -0.1, max: 0.5),
    'opacity': (min: 0.1, max: 1),
  };

  /// Letter spacing in points at [fontSize].
  double spacingAt(double fontSize) => tracking * fontSize;

  Map<String, Object?> toJson() => {'size': size, 'face': face.name, 'tracking': tracking, 'opacity': opacity};

  /// Reads [toJson]'s map over [house]: a key left out is the house's. Throws a
  /// [FormatException] naming the key that is wrong.
  factory TextLook.fromJson(Map<String, Object?> json, TextLook house) {
    double number(String key, double fallback) {
      final v = json[key];
      if (v == null) return fallback;
      final range = ranges[key]!;
      if (v is! num || !v.isFinite || v < range.min || v > range.max) {
        throw FormatException('$key is not between ${range.min} and ${range.max}.');
      }
      return v.toDouble();
    }

    final face = json['face'];
    return TextLook(
      size: number('size', house.size),
      face: face == null ? house.face : (TextFace.named(face) ?? (throw const FormatException('face is not a face.'))),
      tracking: number('tracking', house.tracking),
      opacity: number('opacity', house.opacity),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TextLook && size == other.size && face == other.face && tracking == other.tracking && opacity == other.opacity;

  @override
  int get hashCode => Object.hash(size, face, tracking, opacity);
}

/// How every kind of text in the score looks ([TextKind]); the default is the house style. Its
/// fonts are the project's ([ScoreFonts], and a caption font of its own); this is the rest.
@immutable
class ScoreTypography {
  const ScoreTypography([this._looks = const {}]);

  /// Those set, by kind; the rest are the house's.
  final Map<TextKind, TextLook> _looks;

  static const standard = ScoreTypography();

  TextLook operator [](TextKind kind) => _looks[kind] ?? kind.house;

  /// This with [kind] looking like [look].
  ScoreTypography withLook(TextKind kind, TextLook look) =>
      ScoreTypography(Map.unmodifiable({..._looks, kind: look}..removeWhere((k, v) => v == k.house)));

  /// One property by its key, "kind.property" (`barNumbers.size`): a double or a [TextFace].
  Object valueOf(String key) {
    final (kind, property) = _split(key);
    final look = this[kind];
    return switch (property) {
      'size' => look.size,
      'face' => look.face,
      'tracking' => look.tracking,
      'opacity' => look.opacity,
      _ => throw ArgumentError.value(key, 'key'),
    };
  }

  /// This with one property, by its [valueOf] key, set to [value].
  ScoreTypography withValue(String key, Object value) {
    final (kind, property) = _split(key);
    final json = {...this[kind].toJson(), property: value is TextFace ? value.name : value};
    return withLook(kind, TextLook.fromJson(json, kind.house));
  }

  static (TextKind, String) _split(String key) {
    final dot = key.indexOf('.');
    final kind = dot < 0 ? null : TextKind.values.where((k) => k.name == key.substring(0, dot)).firstOrNull;
    if (kind == null) throw ArgumentError.value(key, 'key');
    return (kind, key.substring(dot + 1));
  }

  /// Every kind's look by its name, each written whole, so a project keeps its typography even
  /// if the house style changes.
  Map<String, Object?> toJson() => {for (final kind in TextKind.values) kind.name: this[kind].toJson()};

  /// Reads [toJson]'s map. A kind or property left out is the house style's; a kind this
  /// version doesn't know is ignored. Throws a [FormatException] naming the key that is wrong.
  factory ScoreTypography.fromJson(Map<String, Object?> json) {
    var typography = standard;
    for (final kind in TextKind.values) {
      final v = json[kind.name];
      if (v == null) continue;
      if (v is! Map) throw FormatException('${kind.name} is not a text look.');
      try {
        typography = typography.withLook(kind, TextLook.fromJson(v.cast<String, Object?>(), kind.house));
      } on FormatException catch (e) {
        throw FormatException('${kind.name}.${e.message}');
      }
    }
    return typography;
  }

  /// Whether the engraving is the same with [other]'s (only drawn texts differ).
  bool engravesLike(ScoreTypography other) =>
      TextKind.values.every((k) => !k.engraved || this[k] == other[k]);

  /// The patched Verovio's options for the symbols' sizes, those changed only.
  Map<String, double> get verovioOptions => {
        for (final kind in TextKind.values)
          if (kind.isSymbol && this[kind].size != 1) kind.verovioScale!: this[kind].size,
      };

  /// Writes the engraved kinds' looks into [doc] for Verovio (after the text edits and dynamics
  /// typed as text, before condensing copies them): a face as MusicXML's `font-style` and
  /// `font-weight`, a size and letter spacing as the patched importer's own attributes
  /// (`curated-score-size`, a percent of the text's size; `curated-score-tracking`, in MEI's
  /// virtual units). [textSize] is the engraving's text size, virtual units (`lyricSize`).
  void applyTo(XmlDocument doc, {required double textSize}) {
    if (TextKind.values.every((k) => !k.engraved || k.isSymbol || this[k] == k.house)) return;
    void set(XmlElement e, TextKind kind) {
      final look = this[kind];
      if (look.face != TextFace.asWritten) {
        e.setAttribute('font-style', look.face.isItalic ? 'italic' : 'normal');
        e.setAttribute('font-weight', look.face.isBold ? 'bold' : 'normal');
      }
      if (look.size != 1) e.setAttribute('curated-score-size', '${look.size * 100}');
      if (look.tracking != 0) e.setAttribute('curated-score-tracking', '${look.tracking * textSize * look.size}');
    }

    for (final direction in doc.findAllElements('direction')) {
      final types = direction.findElements('direction-type');
      // As Verovio tells a tempo from other directions.
      final isTempo = types.any((t) => t.findElements('metronome').isNotEmpty) ||
          direction.getElement('sound')?.getAttribute('tempo') != null;
      for (final t in types) {
        for (final words in t.findElements('words')) {
          set(words, isTempo ? TextKind.tempo : TextKind.expressions);
        }
        for (final rehearsal in t.findElements('rehearsal')) {
          set(rehearsal, TextKind.rehearsal);
        }
      }
    }
    for (final lyric in doc.findAllElements('lyric')) {
      for (final text in lyric.findElements('text')) {
        set(text, TextKind.lyrics);
      }
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ScoreTypography && TextKind.values.every((k) => this[k] == other[k]);

  @override
  int get hashCode => Object.hashAll([for (final k in TextKind.values) this[k]]);
}
