import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'app_settings.dart';
import 'editor_controller.dart';
import 'ui_kit.dart';

/// The engraving options most scores want changed, by plain name: the Engraving page of
/// Settings and of Project Settings. Every other one is in Engrave Option, by code name.
class EngravingSetting {
  const EngravingSetting(this.group, this.title, this.key, {this.step = 1, this.keywords = ''});

  /// The page's heading it is under.
  final String group;
  final String title;

  /// [EngraveOption.key].
  final String key;

  /// A slider's step; integers always go by 1.
  final double step;
  final String keywords;

  EngraveOption get option => EngraveOption.byKey(key)!;

  static const all = [
    EngravingSetting('Spacing', 'Note spacing', 'spacingLinear', step: 0.01, keywords: 'width wide narrow'),
    EngravingSetting('Spacing', 'Spacing ratio', 'spacingNonLinear', step: 0.01, keywords: 'long short duration'),
    EngravingSetting('Spacing', 'Minimum bar width', 'measureMinWidth', keywords: 'measure'),
    EngravingSetting('Spacing', 'Even spacing', 'evenNoteSpacing', keywords: 'equal'),
    EngravingSetting('Line thickness', 'Staff lines', 'engravingDefaults.staffLineThickness', step: 0.005,
        keywords: 'weight'),
    EngravingSetting('Line thickness', 'Stems', 'engravingDefaults.stemThickness', step: 0.005, keywords: 'weight'),
    EngravingSetting('Line thickness', 'Ledger lines', 'engravingDefaults.legerLineThickness', step: 0.01,
        keywords: 'leger weight'),
    EngravingSetting('Line thickness', 'Barlines', 'engravingDefaults.thinBarlineThickness', step: 0.01,
        keywords: 'bar line weight'),
    EngravingSetting('Notation', 'Slur curvature', 'slurCurveFactor', step: 0.05, keywords: 'curve'),
    EngravingSetting('Notation', 'Maximum beam slope', 'beamMaxSlope', keywords: 'angle'),
    EngravingSetting('Notation', 'Grace note size', 'graceFactor', step: 0.05, keywords: 'small'),
    EngravingSetting('Notation', 'Lyric size', 'lyricSize', step: 0.1, keywords: 'text words'),
  ];
}

/// The engraving options a control changes: the app's, or with [project] the open
/// project's, over the app's (each change an edit, a reset going back to the app's value).
class EngravingTarget {
  EngravingTarget(this.settings, this.controller, {required bool project}) : project = project && controller != null;
  final AppSettings settings;
  final EditorController? controller;
  final bool project;

  EngravingOptions get own => project ? controller!.projectEngraving : settings.engravingOptions;
  set own(EngravingOptions options) {
    if (project) {
      controller!.setProjectEngraving(options);
    } else {
      settings.engravingOptions = options;
    }
  }

  /// What the score is engraved with.
  EngravingOptions get effective => project ? own.over(settings.engravingOptions) : own;

  bool isChanged(EngraveOption option) => own.isChanged(option);

  /// Sets [option] here; null resets it.
  void set(EngraveOption option, Object? value) => own = own.withValue(option, value, keepDefault: project);

  /// [option]'s value as engraved: set, or the house style's, or for a line the open score's
  /// font's own (Verovio takes the font's engraving defaults unless one is set).
  Object valueOf(EngraveOption option) {
    final options = effective;
    if (options.isChanged(option)) return options.valueOf(option);
    return fontDefault(option) ?? option.defaultValue;
  }

  /// What a reset goes back to: in a project the app's, else the house style's.
  Object baseOf(EngraveOption option) => project && settings.engravingOptions.isChanged(option)
      ? settings.engravingOptions.valueOf(option)
      : fontDefault(option) ?? option.defaultValue;

  double? fontDefault(EngraveOption option) => switch (option.smuflKey) {
        final name? => controller?.fonts.music.engravingDefaults[name],
        null => null,
      };
}

/// One option as a slider (with its value) or a switch, and a reset once changed.
class EngravingControl extends StatefulWidget {
  const EngravingControl({super.key, required this.target, required this.setting});
  final EngravingTarget target;
  final EngravingSetting setting;

  @override
  State<EngravingControl> createState() => _EngravingControlState();
}

class _EngravingControlState extends State<EngravingControl> {
  /// The value under the thumb while dragging: set (and engraved) only once let go.
  num? _dragging;

  EngraveOption get option => widget.setting.option;

  num _snap(double v) {
    if (option.kind == EngraveOptionKind.integer) return v.round();
    final step = widget.setting.step;
    return double.parse(((v / step).round() * step).toStringAsFixed(4));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final target = widget.target;
    final value = target.valueOf(option);
    final changed = target.isChanged(option);
    final Widget control;
    if (option.kind == EngraveOptionKind.toggle) {
      control = AppSwitch(value: value as bool, onChanged: (v) => target.set(option, v));
    } else {
      final min = option.min!.toDouble(), max = option.max!.toDouble();
      final shown = _dragging ?? value as num;
      final step = option.kind == EngraveOptionKind.integer ? 1.0 : widget.setting.step;
      control = Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 160,
          child: OverlaySemantics(
            child: Slider(
              value: shown.toDouble().clamp(min, max),
              min: min,
              max: max,
              divisions: math.max(1, ((max - min) / step).round()),
              onChanged: (v) => setState(() => _dragging = _snap(v)),
              onChangeEnd: (v) {
                target.set(option, _snap(v));
                setState(() => _dragging = null);
              },
            ),
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            formatOptionValue(shown),
            textAlign: TextAlign.right,
            style: TextStyle(
                fontSize: 12.5, color: colors.text, fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ),
      ]);
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      control,
      SizedBox(
        width: 32,
        child: changed
            ? IconButton(
                icon: const Icon(Icons.restart_alt_rounded, size: 15),
                tooltip: 'Reset',
                visualDensity: VisualDensity.compact,
                color: colors.textMuted,
                onPressed: () => target.set(option, null),
              )
            : null,
      ),
    ]);
  }
}

/// A value as the settings show it: numbers without trailing zeros.
String formatOptionValue(Object value) => switch (value) {
      int() => '$value',
      double() => value.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), ''),
      bool() => value ? 'on' : 'off',
      _ => '$value',
    };

/// The open score as engraved, at the playhead until scrubbed: drawn as the score view and a
/// video frame draw it, again whenever it is re-engraved.
class EngravingPreview extends StatefulWidget {
  const EngravingPreview({super.key, required this.controller, this.scale = 1});
  final EditorController controller;

  /// Drawn this much smaller, so a short strip shows more staves.
  final double scale;

  /// Whether [controller] has a score to show.
  static bool canShow(EditorController? c) => c?.scene != null && c?.curation != null;

  @override
  State<EngravingPreview> createState() => _EngravingPreviewState();
}

class _EngravingPreviewState extends State<EngravingPreview> {
  late double _time = widget.controller.playback.time.value;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final c = widget.controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        if (!EngravingPreview.canShow(c)) return const SizedBox.shrink();
        final duration = c.playback.duration;
        final time = _time.clamp(0.0, math.max(duration, 0.0)).toDouble();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: Stack(children: [
              Positioned.fill(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _PreviewPainter(c.scene!, c.curation!, time, MediaQuery.devicePixelRatioOf(context),
                        colors.scorePaper, colors.scoreInk, widget.scale),
                  ),
                ),
              ),
              if (c.isReengraving)
                const Positioned(
                  right: 12,
                  top: 12,
                  child: SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
            ]),
          ),
          Divider(height: 1, color: colors.line),
          SizedBox(
            height: 32,
            child: OverlaySemantics(
              child: Slider(
                value: time,
                max: math.max(duration, 0.001),
                onChanged: (t) => setState(() => _time = t),
              ),
            ),
          ),
        ]);
      },
    );
  }
}

class _PreviewPainter extends CustomPainter {
  _PreviewPainter(this.scene, this.curation, this.time, this.devicePixelRatio, this.paper, this.ink, this.scale);
  final CuratedScene scene;
  final Curation curation;
  final double time;
  final double devicePixelRatio;
  final Color paper, ink;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    canvas.drawColor(paper, BlendMode.src);
    canvas.scale(scale);
    scene.paint(canvas, size / scale,
        time: time, curation: curation, devicePixelRatio: devicePixelRatio * scale, paper: paper, ink: ink);
  }

  @override
  bool shouldRepaint(_PreviewPainter old) =>
      old.scene != scene ||
      old.curation != curation ||
      old.time != time ||
      old.devicePixelRatio != devicePixelRatio ||
      old.paper != paper ||
      old.ink != ink ||
      old.scale != scale;
}
