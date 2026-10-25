import 'dart:async';

import 'package:flutter/material.dart';
import 'package:score_engine/score_engine.dart' show ScoreTypography, TextFace, TextKind, TextLook;

import 'app_colors.dart';
import 'app_settings.dart';
import 'editor_controller.dart';
import 'engraving_settings.dart' show formatOptionValue;
import 'menu_kit.dart';
import 'motion_settings.dart' show ResetSlot, SettingSlider;

/// One of Project Settings ▸ Typography's rows: a property of one kind of text, by its
/// [ScoreTypography.valueOf] key, under the kind's name; a music symbol's size, by the symbol's
/// name under [symbols].
class TypographySetting {
  const TypographySetting(this.kind, this.property);
  final TextKind kind;

  /// `size`, `face`, `tracking` or `opacity`.
  final String property;

  String get key => '${kind.name}.$property';

  /// The music symbols' group.
  static const symbols = 'Music symbols';

  String get group => kind.isSymbol ? symbols : kind.label;

  String get title => switch (property) {
        _ when kind.isSymbol => kind.label,
        'size' => 'Size',
        'face' => 'Style',
        'tracking' => 'Letter spacing',
        _ => 'Opacity',
      };

  String get keywords => switch (property) {
        'size' => 'scale bigger smaller large small point',
        'face' => 'italic bold weight slant regular upright',
        'tracking' => 'letter spacing tracking wide tight',
        _ => 'grey gray transparent fade light',
      };

  bool get isFace => property == 'face';

  /// A slider's step.
  double get step => property == 'tracking' ? 0.01 : 0.05;

  /// [value] as the row shows it: "120%", "0.05 em".
  String format(double value) => property == 'tracking' ? '${formatOptionValue(value)} em' : '${(value * 100).round()}%';

  /// Every row in page order: each kind's size, style, letter spacing, and opacity for those
  /// drawn (the engraving is all one ink); a music symbol's size alone.
  static final all = [
    for (final kind in TextKind.values)
      for (final property in kind.isSymbol ? ['size'] : ['size', 'face', 'tracking', if (!kind.engraved) 'opacity'])
        TypographySetting(kind, property),
  ];
}

/// The project's typography (an edit each change) over the app's default.
class TypographyTarget {
  const TypographyTarget(this.settings, this.controller);
  final AppSettings settings;
  final EditorController controller;

  Object valueOf(String key) => controller.typography.valueOf(key);
  bool isChanged(String key) => valueOf(key) != ScoreTypography.standard.valueOf(key);
  void set(String key, Object value) => unawaited(controller.setTypography(controller.typography.withValue(key, value)));

  /// Back to the house style's.
  void reset(String key) => set(key, ScoreTypography.standard.valueOf(key));

  bool get isDefault => settings.typography == controller.typography;
  void saveAsDefault() => settings.typography = controller.typography;

  /// The project's typography back to the app's default.
  Future<void> resetToDefault() => controller.setTypography(settings.typography);
}

/// A row's control: a slider (set when let go, one Undo step) or a style, and Reset once changed.
class TypographyControl extends StatelessWidget {
  const TypographyControl({super.key, required this.target, required this.setting});
  final TypographyTarget target;
  final TypographySetting setting;

  @override
  Widget build(BuildContext context) {
    final s = setting;
    final value = target.valueOf(s.key);
    final Widget control;
    if (value is TextFace) {
      control = SettingsDropdown<TextFace>(
        value: value,
        width: 132,
        items: [
          for (final face in TextFace.values)
            if (s.kind.engraved || face != TextFace.asWritten) DropdownMenuItem(value: face, child: Text(face.label)),
        ],
        onChanged: (f) => target.set(s.key, f),
      );
    } else {
      final range = TextLook.ranges[s.property]!;
      control = SettingSlider(
          value: value as double,
          min: range.min,
          max: s.property == 'size' ? s.kind.maxSize : range.max,
          step: s.step,
          format: s.format,
          scale: s.property == 'tracking' ? 1 : 100,
          onChanged: (v) => target.set(s.key, v));
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      control,
      ResetSlot(changed: target.isChanged(s.key), color: context.colors.textMuted, onReset: () => target.reset(s.key)),
    ]);
  }
}
