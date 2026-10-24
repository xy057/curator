import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:score_engine/score_engine.dart' show MotionCurve, ScoreMotion;

import 'app_colors.dart';
import 'app_icons.dart';
import 'app_settings.dart';
import 'dialog_kit.dart';
import 'editor_controller.dart';
import 'engraving_settings.dart' show formatOptionValue;
import 'menu_kit.dart';
import 'ui_kit.dart';

/// One of Project Settings ▸ Advanced's motion rows: a [ScoreMotion] setting by its JSON [key],
/// under [group]. A number has a [unit] and a slider [step]; a curve has neither.
class MotionSetting {
  const MotionSetting(this.key, this.title, this.group, {this.unit, this.step, this.percent = false, this.keywords = ''});
  final String key, title, group;
  final String? unit;
  final double? step;

  /// Shown as a share (0.25 → 25%).
  final bool percent;
  final String keywords;

  bool get isCurve => step == null;

  static const staves = 'Staves', scrolling = 'Scrolling', ending = 'Ending', captions = 'Captions';
  static const barNumbers = 'Bar numbers';

  static const all = [
    MotionSetting('glide', 'Glide', staves, keywords: 'move position stack space'),
    MotionSetting('fade', 'Fade', staves, keywords: 'visibility appear enter leave'),
    MotionSetting('inkDelay', 'Ink delay', staves, step: 0.05, percent: true, keywords: 'opacity late'),
    MotionSetting('ink', 'Ink fade', staves, keywords: 'opacity'),
    MotionSetting('settle', 'Settle', scrolling, unit: 's', step: 0.1, keywords: 'rest stop end final barline'),
    MotionSetting('settleCurve', 'Settle curve', scrolling, keywords: 'rest stop slow'),
    MotionSetting('slowest', 'Slowest speed', scrolling, step: 0.05, percent: true, keywords: 'floor stall notes'),
    MotionSetting('endFade', 'Fade out', ending, unit: 's', step: 0.1, keywords: 'paper end video'),
    MotionSetting('endCurve', 'Fade-out curve', ending, keywords: 'paper end video'),
    MotionSetting('captionFade', 'Caption fade', captions, unit: 's', step: 0.05, keywords: 'caption appear'),
    MotionSetting('captionRise', 'Caption rise', captions, unit: 'pt', step: 1, keywords: 'caption move'),
    MotionSetting('captionCurve', 'Caption curve', captions, keywords: 'caption'),
    MotionSetting('rowLead', 'Row rise', barNumbers, unit: 's', step: 0.1, keywords: 'bar numbers lift ahead'),
    MotionSetting('rowCurve', 'Row curve', barNumbers, keywords: 'bar numbers lift'),
    MotionSetting('tempoFade', 'Tempo fade', barNumbers, unit: 'sp', step: 0.5, keywords: 'tempo mark left cross-fade'),
    MotionSetting('tempoCurve', 'Tempo curve', barNumbers, keywords: 'tempo mark left'),
  ];

  /// [value] as the row shows it: "2.5 s", "25%".
  String format(double value) =>
      percent ? '${(value * 100).round()}%' : '${formatOptionValue(value)}${unit == null ? '' : ' $unit'}';
}

/// The project's motion (an edit each change) over the app's default.
class MotionTarget {
  const MotionTarget(this.settings, this.controller);
  final AppSettings settings;
  final EditorController controller;

  Object valueOf(String key) => controller.motion.valueOf(key);
  bool isChanged(String key) => valueOf(key) != ScoreMotion.standard.valueOf(key);
  void set(String key, Object value) => controller.setMotion(controller.motion.withValue(key, value));

  /// Back to the house style's.
  void reset(String key) => set(key, ScoreMotion.standard.valueOf(key));

  bool get isDefault => settings.motion == controller.motion;
  void saveAsDefault() => settings.motion = controller.motion;

  /// The project's motion back to the app's default.
  void resetToDefault() => controller.setMotion(settings.motion);
}

/// A row's control: a slider (set when let go, one Undo step) or a curve, and Reset once changed.
class MotionControl extends StatefulWidget {
  const MotionControl({super.key, required this.target, required this.setting});
  final MotionTarget target;
  final MotionSetting setting;

  @override
  State<MotionControl> createState() => _MotionControlState();
}

class _MotionControlState extends State<MotionControl> {
  /// The value under the thumb while dragging.
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final s = widget.setting, target = widget.target;
    final value = target.valueOf(s.key);
    final Widget control;
    if (value is MotionCurve) {
      control = CurvePicker(value: value, onChanged: (e) => target.set(s.key, e));
    } else {
      final range = ScoreMotion.ranges[s.key]!, step = s.step!;
      double snap(double v) => double.parse(((v / step).round() * step).clamp(range.min, range.max).toStringAsFixed(4));
      final shown = _dragging ?? value as double;
      control = Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 160,
          child: OverlaySemantics(
            child: Slider(
              value: shown.clamp(range.min, range.max),
              min: range.min,
              max: range.max,
              divisions: math.max(1, ((range.max - range.min) / step).round()),
              onChanged: (v) => setState(() => _dragging = snap(v)),
              onChangeEnd: (v) {
                target.set(s.key, snap(v));
                setState(() => _dragging = null);
              },
            ),
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(s.format(shown),
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 12.5, color: colors.text, fontFeatures: const [FontFeature.tabularFigures()])),
        ),
      ]);
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      control,
      SizedBox(
        width: 32,
        child: target.isChanged(s.key)
            ? IconButton(
                icon: Icon(AppIcon.reset.of(context), size: 15),
                tooltip: 'Reset',
                visualDensity: VisualDensity.compact,
                color: colors.textMuted,
                onPressed: () => target.reset(s.key),
              )
            : null,
      ),
    ]);
  }
}

/// A curve: its shape, then a menu of the named ones and the user's own (Custom…, an equation).
class CurvePicker extends StatelessWidget {
  const CurvePicker({super.key, required this.value, required this.onChanged});
  final MotionCurve value;
  final ValueChanged<MotionCurve> onChanged;

  Future<void> _ask(BuildContext context) async {
    final e = await showCurveDialog(context, initial: value);
    if (e != null) onChanged(e);
  }

  @override
  Widget build(BuildContext context) {
    final custom = value.presetName == null;
    final items = <DropdownMenuItem<Object>>[
      for (final (name, e) in MotionCurve.presets) DropdownMenuItem(value: e, child: Text(name)),
      if (custom) DropdownMenuItem(value: value, child: const Text('Custom')),
      DropdownMenuItem(value: #edit, child: Text(custom ? 'Edit…' : 'Custom…')),
    ];
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Tip(
        message: value.expression,
        child: InkWell(
          onTap: () => _ask(context),
          borderRadius: AppStyle.of(context).radius(5),
          child: CurveThumbnail(value, width: 40, height: 24),
        ),
      ),
      const SizedBox(width: 8),
      SettingsDropdown<Object>(
        value: value,
        width: 132,
        items: items,
        onChanged: (v) => v is MotionCurve ? onChanged(v) : _ask(context),
      ),
    ]);
  }
}

/// [curve]'s shape over 0–1, the 0 and 1 levels as hairlines; an overshoot goes past them.
class CurveThumbnail extends StatelessWidget {
  const CurveThumbnail(this.curve, {super.key, required this.width, required this.height, this.grid = false});
  final MotionCurve? curve;
  final double width, height;

  /// With quarter lines, for the editor's large plot.
  final bool grid;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return CustomPaint(
      size: Size(width, height),
      painter: _CurvePainter(curve, ink: colors.accent, line: colors.line, grid: grid),
    );
  }
}

class _CurvePainter extends CustomPainter {
  _CurvePainter(this.curve, {required this.ink, required this.line, required this.grid});
  final MotionCurve? curve;
  final Color ink, line;
  final bool grid;

  @override
  void paint(Canvas canvas, Size size) {
    final curve = this.curve;
    // Room above and below for an overshoot.
    final inset = size.height * 0.18, h = size.height - 2 * inset;
    double y(double v) => size.height - inset - v * h;
    final hairline = Paint()
      ..color = line
      ..strokeWidth = 1;
    for (final v in [0.0, 1.0, if (grid) ...[0.25, 0.5, 0.75]]) {
      canvas.drawLine(Offset(0, y(v)), Offset(size.width, y(v)), hairline);
    }
    if (grid) {
      for (final u in [0.25, 0.5, 0.75]) {
        canvas.drawLine(Offset(u * size.width, inset), Offset(u * size.width, size.height - inset), hairline);
      }
    }
    if (curve == null) return;
    final path = Path();
    final steps = math.max(24, size.width.round());
    for (var i = 0; i <= steps; i++) {
      final t = i / steps;
      final p = Offset(t * size.width, y(curve.at(t)).clamp(0.0, size.height));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = grid ? 2 : 1.5
          ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(_CurvePainter old) => old.curve != curve || old.ink != ink || old.line != line || old.grid != grid;
}

/// What an equation may use ([MotionCurve]'s grammar), set as mathematics: the domain, the
/// operators and constants, then every function.
class _Syntax extends StatelessWidget {
  const _Syntax();

  /// Each line as mathematics (`^{…}` raised, `_{…}` lowered: drawn smaller, as many fonts lack
  /// the Unicode super- and subscripts), with how it is typed beside it.
  static const _lines = [
    ('f(t),  0 ≤ t ≤ 1', 'f(0) ≠ f(1)'),
    ('a + b   a − b   a × b   a ÷ b   a^{b}', '+  -  *  /  ^'),
    ('3t^{2}', '3t^2'),
    ('π   e', 'pi  e'),
    ('c if a < b, else d', 'a < b ? c : d'),
    ('sin  cos  tan  asin  acos  atan', ''),
    ('e^{x}   ln x   log_{10} x', 'exp  ln  log'),
    ('√x   |x|   sgn x', 'sqrt  abs  sign'),
    ('floor x   ceil x   round x', ''),
    ('min(a, b, …)  max(a, b, …)', ''),
    ('a^{b}  clamp(x, lo, hi)', 'pow(a, b)'),
    ('a + (b − a)t', 'mix(a, b, t)'),
    ('smoothstep(a, b, x)', ''),
  ];

  static final _script = RegExp(r'([\^_])\{([^}]*)\}');

  static List<InlineSpan> _spans(String line, TextStyle style) {
    final spans = <InlineSpan>[];
    var at = 0;
    for (final m in _script.allMatches(line)) {
      if (m.start > at) spans.add(TextSpan(text: line.substring(at, m.start)));
      final small = style.copyWith(fontSize: style.fontSize! * 0.72, height: 1);
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: Transform.translate(
            offset: Offset(0.5, m[1] == '^' ? -style.fontSize! * 0.38 : style.fontSize! * 0.22),
            child: Text(m[2]!, style: small)),
      ));
      at = m.end;
    }
    if (at < line.length) spans.add(TextSpan(text: line.substring(at)));
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final math = TextStyle(fontSize: 12.5, height: 1.5, color: colors.textMuted, fontStyle: FontStyle.italic);
    final note = TextStyle(
        fontSize: 12, height: 1.5, color: colors.textMuted.withValues(alpha: 0.75));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (expression, typed) in _lines)
        Row(children: [
          Expanded(child: Text.rich(TextSpan(style: math, children: _spans(expression, math)))),
          if (typed.isNotEmpty) Text(typed, style: note),
        ]),
    ]);
  }
}

/// Asks for a curve as an equation in t, starting at [initial], plotted as it is typed. Null
/// when cancelled.
Future<MotionCurve?> showCurveDialog(BuildContext context, {required MotionCurve initial}) =>
    showAppDialog<MotionCurve>(context: context, builder: (context) => _CurveDialog(initial: initial));

class _CurveDialog extends StatefulWidget {
  const _CurveDialog({required this.initial});
  final MotionCurve initial;

  @override
  State<_CurveDialog> createState() => _CurveDialogState();
}

class _CurveDialogState extends State<_CurveDialog> {
  late final _text = TextEditingController(text: widget.initial.expression);
  late MotionCurve? _curve = widget.initial;
  String? _problem;

  void _typed(String text) => setState(() {
        _problem = MotionCurve.problemWith(text);
        _curve = _problem == null ? MotionCurve.parse(text) : null;
      });

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = _curve;
    final width = dialogWidth(context, 300);
    return AppDialog(
      title: const Text('Custom Curve'),
      content: SizedBox(
        width: width,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          CurveThumbnail(curve, width: width, height: width * 0.55, grid: true),
          SizedBox(height: dialogGap(context)),
          AppTextField(
            controller: _text,
            label: 'f(t)',
            hint: 't*t*(3-2*t)',
            helper: _problem,
            bad: _problem != null,
            autofocus: true,
            onChanged: _typed,
            onSubmitted: (_) => curve == null ? null : Navigator.pop(context, curve),
          ),
          SizedBox(height: dialogGap(context) * 0.75),
          const _Syntax(),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: curve == null ? null : () => Navigator.pop(context, curve), child: const Text('Done')),
      ],
    );
  }
}
