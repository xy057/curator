
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';
import 'package:score_engine/src/engraving.dart' show Engraver;


void main() {
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
}
