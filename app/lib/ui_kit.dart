import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Keys as the platform writes them: [mac] on macOS ("⇧⌘Z", "⌥-drag"), [other] elsewhere, or
/// else [mac] spelled out the Windows way: "Ctrl+Shift+Z", "Alt+drag". Modifier symbols are
/// Mac-ordered (⌃⌥⇧⌘) and come out in Windows order (Ctrl, Alt, Shift); ⌫ is Backspace.
String shortcut(String mac, [String? other]) =>
    defaultTargetPlatform == TargetPlatform.macOS ? mac : (other ?? windowsKeys(mac));

const _windowsModifiers = {'⌘': 'Ctrl', '⌃': 'Ctrl', '⌥': 'Alt', '⇧': 'Shift'};

/// [shortcut]'s spelling off macOS: each run of modifier symbols ("⇧⌘", "⌥-") becomes
/// "Ctrl+Shift+", and a lone modifier ("⇧ adds") its name ("Shift adds").
String windowsKeys(String mac) => mac
    .replaceAllMapped(RegExp('([⌘⌃⌥⇧]+)(-?)(?=(.?))'), (m) {
      final names = [
        for (final name in const ['Ctrl', 'Alt', 'Shift'])
          if (m[1]!.split('').any((symbol) => _windowsModifiers[symbol] == name)) name,
      ].join('+');
      // "⇧⌘Z" and "⌥-drag" join what follows with +; "⇧ adds" or "(⇧ a beat)" stays apart.
      final joined = m[2]!.isNotEmpty || RegExp(r'[^\s)·,/]').hasMatch(m[3]!);
      return joined ? '$names+' : names;
    })
    .replaceAll('⌫', 'Backspace');

/// Gives a widget that shows an overlay (a tooltip, a slider's value) a semantics node of its own.
///
/// Such widgets show their overlay through an [OverlayPortal], which ties the overlay to a
/// marker on the nearest semantics node above it. Where two markers reach the same node,
/// Flutter keeps only the first (flutter/flutter#182444, #190357), and the other overlay is
/// sent with no parent: the desktop engine rejects that update ("Failed to update ui::AXTree")
/// and its accessibility tree stays broken from then on. With a node each, no marker is lost.
class OverlaySemantics extends StatelessWidget {
  const OverlaySemantics({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(container: true, child: child);
}

/// A [Tooltip] for the app: always use it rather than [Tooltip] (see [OverlaySemantics]).
class Tip extends StatelessWidget {
  const Tip({super.key, required this.message, this.waitDuration, required this.child});
  final String message;
  final Duration? waitDuration;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      OverlaySemantics(child: Tooltip(message: message, waitDuration: waitDuration, child: child));
}

/// [showDialog] for the app: always use it rather than [showDialog].
///
/// A [Slider] keeps its overlay (the value) shown for as long as it is built. A fade at
/// opacity 0 drops what it fades from the semantics tree, but not the slider's overlay,
/// which then has no parent (flutter/flutter#190357; see [OverlaySemantics]). The material
/// dialog fades in from 0, so this one keeps its dialog in the tree while it fades.
Future<T?> showAppDialog<T>({required BuildContext context, required WidgetBuilder builder, bool barrierDismissible = true}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  return navigator.push(_DialogRoute<T>(
    context: context,
    builder: builder,
    barrierDismissible: barrierDismissible,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
  ));
}

class _DialogRoute<T> extends DialogRoute<T> {
  _DialogRoute({required super.context, required super.builder, super.barrierDismissible, super.themes})
      : super(traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop);

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    final fade = super.buildTransitions(context, animation, secondaryAnimation, child);
    return fade is FadeTransition
        ? FadeTransition(opacity: fade.opacity, alwaysIncludeSemantics: true, child: fade.child)
        : fade;
  }
}

/// The compact icon button used in every toolbar: 32 × 32, its label in the tooltip.
class ToolbarButton extends StatelessWidget {
  const ToolbarButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;

  /// The icon's colour when not selected (default: the text colour).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return OverlaySemantics(
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        isSelected: selected,
        iconSize: 18,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          foregroundColor: selected ? colors.accentStrong : (color ?? colors.text),
          backgroundColor: selected ? colors.accentSoft : null,
          animationDuration: const Duration(milliseconds: 150),
        ),
        icon: Icon(icon),
      ),
    );
  }
}

/// Mutually exclusive toolbar buttons (tools, tabs) in one rounded outline.
class ToolGroup extends StatelessWidget {
  const ToolGroup({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          border: Border.all(color: context.colors.line),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      );
}

/// A thin vertical rule between groups of toolbar buttons.
class ToolbarDivider extends StatelessWidget {
  const ToolbarDivider({super.key});

  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 18,
        margin: const EdgeInsets.symmetric(horizontal: 8),
        color: context.colors.line,
      );
}

/// A small dot that breathes: something is recording (tap mode) or busy.
class PulsingDot extends StatefulWidget {
  const PulsingDot({super.key, required this.color, this.size = 10});
  final Color color;
  final double size;

  @override
  State<PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<PulsingDot> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) {
          final t = Curves.easeInOut.transform(_pulse.value);
          return SizedBox.square(
            dimension: widget.size * 1.8,
            child: Center(
              child: Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  color: widget.color,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(color: widget.color.withValues(alpha: 0.45 * (1 - t)), blurRadius: 2, spreadRadius: widget.size * 0.4 * t),
                  ],
                ),
              ),
            ),
          );
        },
      );
}

/// Fades and slides [child] in when it appears (e.g. selection-only buttons).
class FadeSlideSwitcher extends StatelessWidget {
  const FadeSlideSwitcher({super.key, required this.child, this.offset = const Offset(0.15, 0), this.alignment = Alignment.centerLeft});
  final Widget child;
  final Offset offset;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) => AnimatedSize(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        alignment: alignment,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          layoutBuilder: (current, previous) => Stack(alignment: alignment, children: [...previous, ?current]),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(position: Tween(begin: offset, end: Offset.zero).animate(animation), child: child),
          ),
          child: child,
        ),
      );
}

/// A slider's value bubble that hangs below the thumb, pointing up at it: for sliders in the
/// top toolbar, where the usual bubble above would run off the top of the window.
class BelowValueIndicatorShape extends SliderComponentShape {
  const BelowValueIndicatorShape();

  static const _padding = EdgeInsets.symmetric(horizontal: 8, vertical: 4);
  static const _gap = 17.0; // from the thumb's centre to the tip of the pointer, clear of its halo
  static const _pointer = 5.0;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete, {TextPainter? labelPainter, double? textScaleFactor}) {
    final label = labelPainter?.size ?? Size.zero;
    return Size(label.width + _padding.horizontal, label.height + _padding.vertical + _gap + _pointer);
  }

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final scale = activationAnimation.value;
    if (scale <= 0) return;
    final label = labelPainter.size;
    final tip = center + const Offset(0, _gap);
    final box = Rect.fromLTWH(
      tip.dx - label.width / 2 - _padding.left,
      tip.dy + _pointer,
      label.width + _padding.horizontal,
      label.height + _padding.vertical,
    );
    final bubble = Path()
      ..addRRect(RRect.fromRectAndRadius(box, const Radius.circular(6)))
      ..moveTo(tip.dx - _pointer, box.top + 0.5)
      ..lineTo(tip.dx, tip.dy)
      ..lineTo(tip.dx + _pointer, box.top + 0.5)
      ..close();
    final canvas = context.canvas
      ..save()
      ..translate(tip.dx, tip.dy)
      ..scale(scale)
      ..translate(-tip.dx, -tip.dy);
    canvas.drawPath(bubble, Paint()..color = sliderTheme.valueIndicatorColor ?? Colors.black87);
    labelPainter.paint(canvas, box.topLeft + Offset(_padding.left, _padding.top));
    canvas.restore();
  }
}

/// Rebuilds with what [select] reads from [listenable] when that changes ([equals], by
/// default ==), not at every notification: an editor notifies at every move of a drag, and
/// most of the window shows nothing that moved.
class Select<T> extends StatefulWidget {
  const Select({super.key, required this.listenable, required this.select, required this.builder, this.equals});
  final Listenable listenable;
  final T Function() select;
  final Widget Function(BuildContext context, T value) builder;
  final bool Function(T a, T b)? equals;

  @override
  State<Select<T>> createState() => _SelectState<T>();
}

class _SelectState<T> extends State<Select<T>> {
  late T _value = widget.select();

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_changed);
  }

  @override
  void didUpdateWidget(Select<T> old) {
    super.didUpdateWidget(old);
    if (old.listenable != widget.listenable) {
      old.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
    _value = widget.select(); // built again by its parent: read afresh
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final value = widget.select();
    if (widget.equals?.call(value, _value) ?? value == _value) return;
    setState(() => _value = value);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _value);
}

/// A line of text that fades in when there is some and out when there is none, and otherwise
/// changes at once: a status that changes at every move of a drag must not flicker.
class FadingText extends StatefulWidget {
  const FadingText(this.text, {super.key, this.style});
  final String? text;
  final TextStyle? style;

  @override
  State<FadingText> createState() => _FadingTextState();
}

class _FadingTextState extends State<FadingText> {
  late String _shown = widget.text ?? ''; // the last text, while it fades out

  @override
  Widget build(BuildContext context) {
    if (widget.text case final text?) _shown = text;
    return AnimatedOpacity(
      opacity: widget.text == null ? 0 : 1,
      duration: const Duration(milliseconds: 180),
      alwaysIncludeSemantics: true,
      child: Text(_shown, overflow: TextOverflow.ellipsis, maxLines: 1, style: widget.style),
    );
  }
}
