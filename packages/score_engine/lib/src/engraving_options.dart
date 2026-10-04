import 'dart:convert';

import 'score_fonts.dart';

/// What kind of value an [EngraveOption] takes.
enum EngraveOptionKind { number, integer, toggle, choice }

/// A Verovio engraving option the user may change: the "safe" ones, which restyle the music
/// but never touch what the curated view relies on (one endless system, no page furniture, the
/// bars and staves as written). Those stay fixed in the bridge (`vb_engraver_create`) and are
/// never in [all], so nothing here can override them.
///
/// Types, ranges and choices match Verovio's own (`engraving_options_test` checks them against
/// `Toolkit::GetAvailableOptions`); only the defaults are the house style's.
class EngraveOption {
  const EngraveOption._(this.key, this.kind, this.defaultValue, {this.min, this.max, this.choices = const []});

  const EngraveOption.number(String key, double defaultValue, {required double min, required double max})
      : this._(key, EngraveOptionKind.number, defaultValue, min: min, max: max);

  const EngraveOption.integer(String key, int defaultValue, {required int min, required int max})
      : this._(key, EngraveOptionKind.integer, defaultValue, min: min, max: max);

  const EngraveOption.toggle(String key, bool defaultValue) : this._(key, EngraveOptionKind.toggle, defaultValue);

  const EngraveOption.choice(String key, String defaultValue, {required List<String> choices})
      : this._(key, EngraveOptionKind.choice, defaultValue, choices: choices);

  /// The code name, as Verovio takes it. SMuFL engraving defaults are written
  /// `engravingDefaults.<name>`: they are sent inside that one option, in staff spaces.
  final String key;
  final EngraveOptionKind kind;

  /// The house style's value (Bravura's own for the engraving defaults).
  final Object defaultValue;
  final num? min, max;
  final List<String> choices;

  static const _smufl = 'engravingDefaults.';

  /// The name inside `engravingDefaults`, or null for a top-level option.
  String? get smuflKey => key.startsWith(_smufl) ? key.substring(_smufl.length) : null;

  /// [value] as this option takes it (clamped into range), or null when it can't be (NaN and
  /// infinity are no value: one would pass through clamping, the other not round).
  Object? coerce(Object? value) => switch (kind) {
        EngraveOptionKind.number when value is num && value.isFinite => value.toDouble().clamp(min!, max!).toDouble(),
        EngraveOptionKind.integer when value is num && value.isFinite => value.round().clamp(min!, max!).toInt(),
        EngraveOptionKind.toggle when value is bool => value,
        EngraveOptionKind.choice when value is String && choices.contains(value) => value,
        _ => null,
      };

  static EngraveOption? byKey(String key) => _byKey[key];
  static final _byKey = {for (final o in all) o.key: o};

  /// Every option offered, sorted by code name.
  static final List<EngraveOption> all = [
    // Spacing: a quarter note gets about 5½ staff spaces, each doubling of duration √2 more.
    // Generous, since a scrolling score never has to fit a line.
    const EngraveOption.number('spacingLinear', 0.62, min: 0, max: 1),
    const EngraveOption.number('spacingNonLinear', 0.5, min: 0, max: 1),
    const EngraveOption.integer('measureMinWidth', 15, min: 1, max: 30),
    const EngraveOption.toggle('evenNoteSpacing', false),
    const EngraveOption.number('graceFactor', 0.75, min: 0.5, max: 1),
    const EngraveOption.toggle('graceRhythmAlign', false),
    const EngraveOption.integer('beamMaxSlope', 10, min: 0, max: 20),
    const EngraveOption.toggle('tupletNumHead', false),
    const EngraveOption.toggle('tupletAngledOnBeams', false),
    const EngraveOption.number('slurCurveFactor', 1, min: 0.2, max: 5),
    const EngraveOption.integer('slurMaxSlope', 60, min: 30, max: 85),
    const EngraveOption.number('slurSymmetry', 0, min: 0, max: 1),
    const EngraveOption.number('slurMargin', 1, min: 0.1, max: 4),
    const EngraveOption.number('tieMinLength', 2, min: 0, max: 10),
    const EngraveOption.number('dynamDist', 1, min: 0.5, max: 16),
    const EngraveOption.toggle('dynamSingleGlyphs', false),
    const EngraveOption.number('hairpinSize', 3, min: 1, max: 8),
    const EngraveOption.integer('mnumInterval', 0, min: 0, max: 64),
    const EngraveOption.toggle('octaveAlternativeSymbols', false),
    const EngraveOption.choice('multiRestStyle', 'auto', choices: ['auto', 'default', 'block', 'symbols']),
    const EngraveOption.number('lyricSize', 4.5, min: 2, max: 8),

    // Line thicknesses and lengths: the font's SMuFL engraving defaults, in staff spaces
    // (Verovio's ranges for them, which are in half spaces, halved).
    for (final (name, min, max) in _smuflDefaults)
      EngraveOption.number('$_smufl$name', MusicFont.bravura.engravingDefaults[name]!, min: min, max: max),

    // The space kept around each kind of thing, in half staff spaces.
    for (final (name, def, max) in _margins) EngraveOption.number(name, def, min: 0, max: max),
  ]..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));

  static const _smuflDefaults = [
    ('staffLineThickness', 0.05, 0.15),
    ('stemThickness', 0.05, 0.25),
    ('legerLineThickness', 0.05, 0.25),
    ('legerLineExtension', 0.1, 0.5),
    ('slurEndpointThickness', 0.025, 0.125),
    ('slurMidpointThickness', 0.1, 0.6),
    ('tieEndpointThickness', 0.025, 0.125),
    ('tieMidpointThickness', 0.1, 0.5),
    ('thinBarlineThickness', 0.05, 0.4),
    ('thickBarlineThickness', 0.25, 1.0),
    ('barlineSeparation', 0.25, 1.0),
    ('repeatBarlineDotSeparation', 0.05, 0.5),
    ('dashedBarlineDashLength', 0.05, 2.5),
    ('dashedBarlineGapLength', 0.05, 2.5),
    ('bracketThickness', 0.25, 1.0),
    ('subBracketThickness', 0.05, 1.0),
    ('hairpinThickness', 0.05, 0.4),
    ('octaveLineThickness', 0.05, 0.5),
    ('pedalLineThickness', 0.05, 0.5),
    ('repeatEndingLineThickness', 0.05, 1.0),
    ('lyricLineThickness', 0.05, 0.25),
    ('tupletBracketThickness', 0.05, 0.4),
    ('textEnclosureThickness', 0.05, 0.4),
    ('hBarThickness', 0.25, 3.0),
  ];

  static const _margins = [
    ('defaultLeftMargin', 0.0, 2.0),
    ('defaultRightMargin', 0.0, 2.0),
    ('defaultTopMargin', 0.5, 6.0),
    ('defaultBottomMargin', 0.5, 5.0),
    ('leftMarginAccid', 1.0, 2.0),
    ('rightMarginAccid', 0.5, 2.0),
    ('leftMarginBarLine', 0.0, 2.0),
    ('rightMarginBarLine', 0.0, 2.0),
    ('leftMarginLeftBarLine', 1.0, 2.0),
    ('rightMarginLeftBarLine', 1.0, 2.0),
    ('leftMarginRightBarLine', 1.0, 2.0),
    ('rightMarginRightBarLine', 0.0, 2.0),
    ('leftMarginBeatRpt', 2.0, 2.0),
    ('rightMarginBeatRpt', 0.0, 2.0),
    ('leftMarginChord', 1.0, 2.0),
    ('rightMarginChord', 0.0, 2.0),
    ('leftMarginClef', 1.0, 2.0),
    ('rightMarginClef', 1.0, 2.0),
    ('leftMarginKeySig', 1.0, 2.0),
    ('rightMarginKeySig', 1.0, 2.0),
    ('leftMarginMensur', 1.0, 2.0),
    ('rightMarginMensur', 1.0, 2.0),
    ('leftMarginMeterSig', 1.0, 2.0),
    ('rightMarginMeterSig', 1.0, 2.0),
    ('leftMarginMRest', 0.0, 2.0),
    ('rightMarginMRest', 0.0, 2.0),
    ('leftMarginMultiRest', 0.0, 2.0),
    ('rightMarginMultiRest', 0.0, 2.0),
    ('leftMarginMultiRpt', 0.0, 2.0),
    ('rightMarginMultiRpt', 0.0, 2.0),
    ('leftMarginNote', 1.0, 2.0),
    ('rightMarginNote', 0.0, 2.0),
    ('leftMarginRest', 1.0, 2.0),
    ('rightMarginRest', 0.0, 2.0),
    ('leftMarginTabDurSym', 1.0, 2.0),
    ('rightMarginTabDurSym', 0.0, 2.0),
    ('topMarginArtic', 0.75, 10.0),
    ('bottomMarginArtic', 0.75, 10.0),
    ('topMarginHarm', 1.0, 10.0),
    ('bottomMarginHarm', 1.0, 10.0),
    ('bottomMarginOctave', 1.0, 10.0),
  ];
}

/// The user's engraving options: only those changed from the house style.
class EngravingOptions {
  const EngravingOptions() : overrides = const {};
  EngravingOptions._(Map<String, Object> overrides) : overrides = Map.unmodifiable(overrides);

  /// Code name → value, for options set to something other than their default.
  final Map<String, Object> overrides;

  bool get isEmpty => overrides.isEmpty;

  Object valueOf(EngraveOption option) => overrides[option.key] ?? option.defaultValue;

  bool isChanged(EngraveOption option) => overrides.containsKey(option.key);

  /// With [option] set to [value]; its default (or null) removes the override.
  EngravingOptions withValue(EngraveOption option, Object? value) {
    final v = option.coerce(value);
    final next = {...overrides}..remove(option.key);
    if (v != null && v != option.defaultValue) next[option.key] = v;
    return EngravingOptions._(next);
  }

  /// Read back from [toJson], dropping anything unknown or out of place.
  factory EngravingOptions.fromJson(Object? json) {
    var options = const EngravingOptions();
    if (json is! Map) return options;
    for (final MapEntry(:key, :value) in json.entries) {
      final option = key is String ? EngraveOption.byKey(key) : null;
      if (option != null) options = options.withValue(option, value);
    }
    return options;
  }

  Map<String, Object> toJson() => overrides;

  /// The Verovio options to engrave with in [font]: every offered option, overridden or not,
  /// so the house style lives in [EngraveOption.all] alone.
  String verovioJson(MusicFont font) {
    final smufl = <String, Object>{...font.engravingDefaults};
    final options = <String, Object>{'font': font.name, 'fontFallback': 'Bravura'};
    for (final option in EngraveOption.all) {
      final name = option.smuflKey;
      if (name == null) {
        options[option.key] = valueOf(option);
      } else if (isChanged(option)) {
        smufl[name] = valueOf(option);
      }
    }
    options['engravingDefaults'] = smufl;
    return jsonEncode(options);
  }

  @override
  bool operator ==(Object other) =>
      other is EngravingOptions &&
      other.overrides.length == overrides.length &&
      overrides.entries.every((e) => other.overrides[e.key] == e.value);

  @override
  int get hashCode => Object.hashAllUnordered(overrides.entries.map((e) => Object.hash(e.key, e.value)));
}
