import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'dialog_kit.dart';
import 'ui_kit.dart';
import 'l10n/l10n.dart';

/// Asks for a colour, starting at [initial]: hue, saturation and lightness strips and a hex
/// field. Null when cancelled.
Future<Color?> showColorDialog(BuildContext context, {required Color initial, String title = 'Custom Color'}) =>
    showAppDialog<Color>(context: context, builder: (context) => _ColorDialog(initial: initial, title: title));

class _ColorDialog extends StatefulWidget {
  const _ColorDialog({required this.initial, required this.title});
  final Color initial;
  final String title;

  @override
  State<_ColorDialog> createState() => _ColorDialogState();
}

class _ColorDialogState extends State<_ColorDialog> {
  // Kept as HSL, so a grey keeps the hue it had while its saturation is dragged back up.
  late HSLColor _hsl = HSLColor.fromColor(widget.initial.withValues(alpha: 1));
  late final _hex = TextEditingController(text: _hexOf(_hsl.toColor()));
  bool _bad = false;

  static String _hexOf(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  /// "#4DA8F0", "4da8f0" or "#4AF"; null for anything else.
  static Color? _parse(String text) {
    var t = text.trim().replaceFirst('#', '');
    if (t.length == 3) t = t.split('').map((c) => '$c$c').join();
    if (t.length != 6) return null;
    final rgb = int.tryParse(t, radix: 16);
    return rgb == null ? null : Color(0xFF000000 | rgb);
  }

  void _set(HSLColor hsl) => setState(() {
        _hsl = hsl;
        _bad = false;
        _hex.text = _hexOf(hsl.toColor());
      });

  void _typed(String text) {
    final color = _parse(text);
    setState(() {
      _bad = color == null;
      if (color != null) _hsl = HSLColor.fromColor(color);
    });
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = AppStyle.of(context);
    final h = _hsl;
    final color = h.toColor();
    final gap = dialogGap(context);
    Widget strip(String label, double value, List<Color> colors, ValueChanged<double> onChanged) => Padding(
          padding: EdgeInsets.only(top: gap),
          child: Row(children: [
            SizedBox(width: 84, child: Text(label.tr)),
            Expanded(child: _Strip(value: value, colors: colors, onChanged: onChanged, label: label)),
          ]),
        );
    return AppDialog(
      title: Text(widget.title.tr),
      content: SizedBox(
        width: dialogWidth(context, 300),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Container(
              width: style.field,
              height: style.field,
              decoration: BoxDecoration(color: color, borderRadius: style.radius(6), border: Border.all(color: context.colors.line)),
            ),
            SizedBox(width: gap),
            Expanded(
              child: AppTextField(
                controller: _hex,
                label: 'Hex',
                bad: _bad,
                onChanged: _typed,
                onSubmitted: (_) => _bad ? null : Navigator.pop(context, color),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[#0-9a-fA-F]')), LengthLimitingTextInputFormatter(7)],
              ),
            ),
          ]),
          strip('Hue', h.hue / 360, [for (var d = 0; d <= 360; d += 60) HSLColor.fromAHSL(1, d % 360, 1, 0.5).toColor()],
              (v) => _set(h.withHue(v * 359.9))),
          strip('Saturation', h.saturation, [h.withSaturation(0).toColor(), h.withSaturation(1).toColor()],
              (v) => _set(h.withSaturation(v))),
          strip('Lightness', h.lightness, [Colors.black, h.withLightness(0.5).toColor(), Colors.white],
              (v) => _set(h.withLightness(v))),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel'.tr)),
        FilledButton(onPressed: _bad ? null : () => Navigator.pop(context, color), child: Text('Done'.tr)),
      ],
    );
  }
}

/// A gradient to click or drag along, its [value] (0–1) a ring on it.
class _Strip extends StatelessWidget {
  const _Strip({required this.value, required this.colors, required this.onChanged, required this.label});
  final double value;
  final List<Color> colors;
  final ValueChanged<double> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) {
    final style = AppStyle.of(context);
    return LayoutBuilder(builder: (context, box) {
      void at(Offset p) => onChanged((p.dx / box.maxWidth).clamp(0.0, 1.0));
      return Semantics(
        label: label,
        value: '${(value * 100).round()}%',
        slider: true,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTapDown: (d) => at(d.localPosition),
            onHorizontalDragStart: (d) => at(d.localPosition),
            onHorizontalDragUpdate: (d) => at(d.localPosition),
            child: CustomPaint(
              size: Size(box.maxWidth, 20),
              painter: _StripPainter(value, colors, style.corner(5), context.colors.line),
            ),
          ),
        ),
      );
    });
  }
}

class _StripPainter extends CustomPainter {
  _StripPainter(this.value, this.colors, this.radius, this.line);
  final double value;
  final List<Color> colors;
  final double radius;
  final Color line;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final shape = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    canvas.drawRRect(shape, Paint()..shader = LinearGradient(colors: colors).createShader(rect));
    canvas.drawRRect(shape, Paint()..color = line..style = PaintingStyle.stroke);
    final x = value * size.width;
    final ring = Rect.fromCenter(center: Offset(x, size.height / 2), width: 8, height: size.height + 4);
    final knob = RRect.fromRectAndRadius(ring, Radius.circular(radius == 0 ? 0 : 4));
    canvas.drawRRect(knob, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 2.5);
    canvas.drawRRect(knob.inflate(1.25), Paint()..color = const Color(0x66000000)..style = PaintingStyle.stroke..strokeWidth = 0.75);
  }

  @override
  bool shouldRepaint(_StripPainter old) => old.value != value || old.radius != radius || old.line != line || !_same(old.colors);

  bool _same(List<Color> other) =>
      other.length == colors.length && [for (var i = 0; i < colors.length; i++) other[i] == colors[i]].every((s) => s);
}
