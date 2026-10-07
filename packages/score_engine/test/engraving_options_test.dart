import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';
import 'package:score_engine/src/engraving.dart' show Engraver;

import 'demo_score.dart';

void main() {
  test('verovioVersion is the Verovio the Makefile pins', () {
    final tag = RegExp(r'^VEROVIO_TAG := version-(\S+)', multiLine: true).firstMatch(File('../../Makefile').readAsStringSync())![1]!;
    expect(verovioVersion, tag);
  });

  test('every option is one Verovio has, with its type, range and choices', () {
    final groups = Engraver.availableOptions(resourceDirectory: engineResourceDirectory())['groups'] as Map;
    final verovio = <String, Map>{
      for (final group in groups.values)
        if ((group as Map)['options'] is Map)
          for (final MapEntry(:key, :value) in (group['options'] as Map).entries) key as String: value as Map,
    };
    // Verovio's own names for the SMuFL engraving defaults (Options::Sync), in half spaces.
    const smufl = {
      'staffLineThickness': 'staffLineWidth', 'stemThickness': 'stemWidth',
      'legerLineThickness': 'ledgerLineThickness', 'legerLineExtension': 'ledgerLineExtension',
      'slurEndpointThickness': 'slurEndpointThickness', 'slurMidpointThickness': 'slurMidpointThickness',
      'tieEndpointThickness': 'tieEndpointThickness', 'tieMidpointThickness': 'tieMidpointThickness',
      'thinBarlineThickness': 'barLineWidth', 'thickBarlineThickness': 'thickBarlineThickness',
      'barlineSeparation': 'barLineSeparation', 'repeatBarlineDotSeparation': 'repeatBarLineDotSeparation',
      'dashedBarlineDashLength': 'dashedBarLineDashLength', 'dashedBarlineGapLength': 'dashedBarLineGapLength',
      'bracketThickness': 'bracketThickness', 'subBracketThickness': 'subBracketThickness',
      'hairpinThickness': 'hairpinThickness', 'octaveLineThickness': 'octaveLineThickness',
      'pedalLineThickness': 'pedalLineThickness', 'repeatEndingLineThickness': 'repeatEndingLineThickness',
      'lyricLineThickness': 'lyricLineThickness', 'tupletBracketThickness': 'tupletBracketThickness',
      'textEnclosureThickness': 'textEnclosureThickness', 'hBarThickness': 'multiRestThickness',
    };
    // The house style's own spacing; everything else starts as Verovio has it.
    const house = {'spacingLinear', 'spacingNonLinear'};

    for (final option in EngraveOption.all) {
      final name = option.smuflKey;
      final spec = verovio[name == null ? option.key : smufl[name]];
      expect(spec, isNotNull, reason: option.key);
      final scale = name == null ? 1 : 2;
      final type = switch (option.kind) {
        EngraveOptionKind.number => 'double',
        EngraveOptionKind.integer => 'int',
        EngraveOptionKind.toggle => 'bool',
        EngraveOptionKind.choice => 'std::string-list',
      };
      expect(spec!['type'], type, reason: option.key);
      if (option.min != null) {
        expect(option.min! * scale, closeTo(spec['min'] as num, 0.01), reason: '${option.key} min');
        expect(option.max! * scale, closeTo(spec['max'] as num, 0.01), reason: '${option.key} max');
        expect(option.coerce(option.defaultValue), option.defaultValue, reason: '${option.key} default in range');
      }
      if (option.kind == EngraveOptionKind.choice) expect(option.choices, spec['values'], reason: option.key);
      if (name == null && !house.contains(option.key)) {
        final def = spec['default'];
        if (def is num) {
          expect((option.defaultValue as num).toDouble(), closeTo(def, 0.01), reason: '${option.key} default');
        } else {
          expect(option.defaultValue, def, reason: '${option.key} default');
        }
      }
    }
  });

  test('nothing offered can undo the one endless system', () {
    const fixed = {
      'breaks', 'header', 'footer', 'adjustPageHeight', 'adjustPageWidth', 'scale', 'font', 'fontFallback',
      'pageMarginLeft', 'pageMarginRight', 'pageMarginTop', 'pageMarginBottom', 'pageWidth', 'pageHeight',
      'spacingStaff', 'spacingSystem', 'condense', 'condenseFirstPage', 'condenseEncoded', 'shrinkToFit',
      'justificationStaff', 'justificationSystem', 'noJustification', 'expand', 'transpose', 'mdivAll',
    };
    final keys = EngraveOption.all.map((o) => o.key).toList();
    expect(keys.toSet(), hasLength(keys.length), reason: 'each option once');
    expect(keys.where(fixed.contains), isEmpty);
    expect(keys, orderedEquals([...keys]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()))),
        reason: 'sorted by code name');
  });

  test('keeps only valid changes, and reads back what it wrote', () {
    final curve = EngraveOption.byKey('slurCurveFactor')!;
    final stem = EngraveOption.byKey('engravingDefaults.stemThickness')!;
    var options = const EngravingOptions().withValue(curve, 9).withValue(stem, 0.15);
    expect(options.valueOf(curve), 5.0, reason: 'clamped to Verovio\'s maximum');
    expect(options.withValue(curve, curve.defaultValue).isChanged(curve), isFalse);
    expect(EngravingOptions.fromJson(options.toJson()), options);
    expect(
      EngravingOptions.fromJson({'breaks': 'auto', 'slurCurveFactor': 'round', 'tupletNumHead': true}).overrides,
      {'tupletNumHead': true},
    );
    options = EngravingOptions.fromJson(null);
    expect(options.isEmpty, isTrue);
  });

  test("a project's options win over the app's, one set back to the default too", () {
    final curve = EngraveOption.byKey('slurCurveFactor')!, spacing = EngraveOption.byKey('spacingLinear')!;
    final app = const EngravingOptions().withValue(curve, 3).withValue(spacing, 0.8);
    final project = const EngravingOptions().withValue(curve, curve.defaultValue, keepDefault: true);
    expect(project.isChanged(curve), isTrue);
    final both = project.over(app);
    expect(both.valueOf(curve), curve.defaultValue);
    expect(both.valueOf(spacing), 0.8);
    expect(const EngravingOptions().over(app), app);
    expect(EngravingOptions.fromJson(project.toJson(), keepDefault: true), project);
    expect(EngravingOptions.fromJson(project.toJson()).isEmpty, isTrue);
  });

  test('options restyle the engraving but keep its bars', () async {
    final xml = demoScore();
    final plain = await LoadedScore.load(xml);
    final spacing = EngraveOption.byKey('spacingLinear')!;
    final stems = EngraveOption.byKey('engravingDefaults.stemThickness')!;
    final wide = await plain.withEdits(options: const EngravingOptions().withValue(spacing, 0.9));
    expect(wide.options.valueOf(spacing), 0.9);
    expect(wide.engraving.width, greaterThan(plain.engraving.width * 1.1));
    expect(wide.engraving.measures.map((m) => m.duration), plain.engraving.measures.map((m) => m.duration));
    expect(wide.engraving.staves.map((s) => s.n), plain.engraving.staves.map((s) => s.n));

    final thick = await plain.withEdits(options: const EngravingOptions().withValue(stems, 0.24));
    // Thicker stems only nudge the spacing where things would collide.
    expect(thick.engraving.width, closeTo(plain.engraving.width, plain.engraving.width * 0.01));
    expect(thick.engraving.measures.length, plain.engraving.measures.length);
    expect(thick.engraving.commandFloats, isNot(plain.engraving.commandFloats));
  });

  test('NaN and infinity are no value for a number (they passed clamping, or failed to round)', () {
    final integer = EngraveOption.byKey('measureMinWidth')!, number = EngraveOption.byKey('spacingLinear')!;
    for (final bad in [double.nan, double.infinity, double.negativeInfinity]) {
      expect(integer.coerce(bad), isNull, reason: '$bad');
      expect(number.coerce(bad), isNull, reason: '$bad');
    }
    expect(integer.coerce(99.4), 30);
  });
}
