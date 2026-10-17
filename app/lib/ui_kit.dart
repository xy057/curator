import 'dart:math' as math;

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
    duration: motion(context, 150),
  ));
}

class _DialogRoute<T> extends DialogRoute<T> {
  _DialogRoute({
    required super.context,
    required super.builder,
    super.barrierDismissible,
    super.themes,
    required this.duration,
  }) : super(traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop);

  final Duration duration;

  @override
  Duration get transitionDuration => duration;

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    final fade = super.buildTransitions(context, animation, secondaryAnimation, child);
    return fade is FadeTransition
        ? FadeTransition(opacity: fade.opacity, alwaysIncludeSemantics: true, child: fade.child)
        : fade;
  }
}

/// Whether the theme is [UiStyle.refined]. A theme without an [AppStyle] (a bare [MaterialApp]'s,
/// which hasn't the app's palette either) is not: the material widgets are used there.
bool isRefined(BuildContext context) => Theme.of(context).extension<AppStyle>()?.style == UiStyle.refined;

/// [classic] milliseconds of motion, as [UiStyle.refined] has it: a desktop's, about three quarters as long.
Duration motion(BuildContext context, int classic) =>
    Duration(milliseconds: isRefined(context) ? (classic * 0.775).round() : classic);

/// How far a [UiStyle.refined] field's text is in from its border: the same in a text field
/// and a select, so what is typed and what is chosen start at one place under their labels.
const fieldInset = 10.0;

/// A field with its [label] over it: how [UiStyle.refined]'s dialogs label their fields.
class FieldLabel extends StatelessWidget {
  const FieldLabel({super.key, required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: context.colors.textMuted)),
        ),
        child,
      ]);
}

/// The compact icon button used in every toolbar: 32 × 32, its label in the tooltip; in
/// [UiStyle.refined] 28 × 28, and when selected a neutral pressed fill under an accent icon.
class ToolbarButton extends StatelessWidget {
  const ToolbarButton({
    super.key,
    this.icon,
    this.glyph,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    this.color,
  }) : assert((icon == null) != (glyph == null));

  final IconData? icon;

  /// Drawn instead of an [icon] (none fits), in the [IconTheme]'s colour and size.
  final Widget? glyph;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;

  /// The icon's colour when not selected (default: the text colour).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final refined = isRefined(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final size = refined ? 28.0 : 32.0;
    return OverlaySemantics(
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        isSelected: selected,
        iconSize: refined ? 16 : 18,
        visualDensity: VisualDensity.compact,
        constraints: BoxConstraints.tightFor(width: size, height: size),
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          foregroundColor: selected ? (refined && dark ? colors.accent : colors.accentStrong) : (color ?? colors.text),
          backgroundColor: selected
              ? (refined ? (dark ? Colors.white : Colors.black).withValues(alpha: dark ? 0.1 : 0.05) : colors.accentSoft)
              : null,
          shape: refined ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)) : null,
          animationDuration: motion(context, 150),
        ),
        icon: glyph ?? Icon(icon),
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
          borderRadius: BorderRadius.circular(isRefined(context) ? 7 : 10),
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
        duration: motion(context, 180),
        curve: Curves.easeOutCubic,
        alignment: alignment,
        child: AnimatedSwitcher(
          duration: motion(context, 180),
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
      duration: motion(context, 180),
      alwaysIncludeSemantics: true,
      child: Text(_shown, overflow: TextOverflow.ellipsis, maxLines: 1, style: widget.style),
    );
  }
}

/// True during the frame the appearance (light / dark, accent) changes.
bool _appearanceChanging = false;

/// The window's appearance is about to change (main.dart): for that frame, [stateDuration]s
/// are none.
void appearanceChanging() {
  _appearanceChanging = true;
  WidgetsBinding.instance.addPostFrameCallback((_) => _appearanceChanging = false);
}

/// How long a widget's own change of colour (a hover, a selection) takes: [duration], but none
/// in the frame the theme changes. The window shows that change by fading a still of itself
/// out over it; a colour animated under the still would trail it, and rebuild every frame.
Duration stateDuration(Duration duration) => _appearanceChanging ? Duration.zero : duration;

/// The app's on/off switch: always use it rather than [Switch]. In [UiStyle.refined] a small
/// track with a white knob that slides, drawn alike on every platform; in [UiStyle.classic]
/// Material's [Switch].
class AppSwitch extends StatefulWidget {
  const AppSwitch({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool>? onChanged;

  static const size = Size(34, 20);

  @override
  State<AppSwitch> createState() => _AppSwitchState();
}

class _AppSwitchState extends State<AppSwitch> {
  bool _hovered = false, _focused = false;

  void _toggle() => widget.onChanged?.call(!widget.value);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!isRefined(context)) {
      return Switch(value: widget.value, onChanged: widget.onChanged);
    }
    // The app's palette, or where there is none (a dialog shown on its own) the theme's.
    final colors = theme.extension<AppColors>();
    final dark = theme.brightness == Brightness.dark;
    final enabled = widget.onChanged != null;
    final accent = colors?.accent ?? theme.colorScheme.primary;
    final on = dark ? accent : (colors?.accentStrong ?? accent);
    final off = dark ? const Color(0xFF4A4F57) : const Color(0xFFD5DAE0);
    final hoverShade = (dark ? Colors.white : Colors.black).withValues(alpha: _hovered && enabled ? 0.07 : 0);
    return Semantics(
      toggled: widget.value,
      enabled: enabled,
      onTap: enabled ? _toggle : null,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _toggle())},
        child: GestureDetector(
          onTap: enabled ? _toggle : null,
          child: Opacity(
            opacity: enabled ? 1 : 0.45,
            // The tap area is a little larger than the track, as a Material switch's is.
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: widget.value ? 1 : 0),
                duration: motion(context, 160),
                curve: Curves.easeOutCubic,
                builder: (context, t, _) => CustomPaint(
                  size: AppSwitch.size,
                  painter: _SwitchPainter(
                    t: t,
                    track: Color.alphaBlend(hoverShade, Color.lerp(off, on, t)!),
                    focus: _focused ? accent.withValues(alpha: 0.45) : null,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SwitchPainter extends CustomPainter {
  _SwitchPainter({required this.t, required this.track, required this.focus});
  final double t;
  final Color track;
  final Color? focus;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.height / 2;
    final rect = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(r));
    if (focus case final focus?) {
      canvas.drawRRect(rect.inflate(2.5), Paint()..color = focus..style = PaintingStyle.stroke..strokeWidth = 2);
    }
    canvas.drawRRect(rect, Paint()..color = track);
    const inset = 2.0;
    final knob = Offset(r + (size.width - 2 * r) * t, r);
    final knobRadius = r - inset;
    canvas.drawCircle(knob.translate(0, 0.6), knobRadius + 0.3,
        Paint()..color = const Color(0x40000000)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.2));
    canvas.drawCircle(knob, knobRadius, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_SwitchPainter old) => old.t != t || old.track != track || old.focus != focus;
}

/// The app's segmented control: always use it rather than [SegmentedButton]. In
/// [UiStyle.refined] a recessed well whose chosen segment, a light tint of the accent, slides
/// to the segment chosen; in [UiStyle.classic] Material's [SegmentedButton] (with [style]).
/// Segments are as wide as the widest, or share the width given with [expand].
class AppSegmented<T> extends StatelessWidget {
  const AppSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.expand = false,
    this.style,
  });
  final List<ButtonSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;
  final bool expand;
  final ButtonStyle? style;

  @override
  Widget build(BuildContext context) {
    if (!isRefined(context)) {
      return SegmentedButton<T>(
        style: style,
        expandedInsets: expand ? EdgeInsets.zero : null,
        showSelectedIcon: false,
        segments: segments,
        selected: {selected},
        onSelectionChanged: (s) => onChanged(s.single),
      );
    }
    final colors = context.colors;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final n = segments.length;
    final index = segments.indexWhere((s) => s.value == selected);
    // The chosen segment: the accent's light tint, edged with the accent, its label the accent's
    // strong shade taken toward black (or in the dark, white) until it reads on the tint (4.5:1).
    final chosen = colors.accentSoft;
    final edge = colors.accent.withValues(alpha: dark ? 0.5 : 0.45);
    double contrast(Color a, Color b) {
      final (x, y) = (a.computeLuminance(), b.computeLuminance());
      return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
    }

    var onChosen = colors.accentStrong;
    for (var t = 0.05; contrast(onChosen, chosen) < 4.5 && t <= 1; t += 0.05) {
      onChosen = Color.lerp(colors.accentStrong, dark ? Colors.white : Colors.black, t)!;
    }
    final control = Container(
      height: 32,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: colors.well, border: Border.all(color: colors.line), borderRadius: BorderRadius.circular(7)),
      child: Stack(fit: StackFit.expand, children: [
        if (index >= 0)
          Positioned.fill(
            child: AnimatedAlign(
              alignment: Alignment(n == 1 ? 0 : -1 + 2 * index / (n - 1), 0),
              duration: motion(context, 220),
              curve: Curves.easeOutCubic,
              child: FractionallySizedBox(
                widthFactor: 1 / n,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: chosen,
                    border: Border.all(color: edge),
                    borderRadius: BorderRadius.circular(5),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.2 : 0.06), blurRadius: 2, offset: const Offset(0, 1))],
                  ),
                ),
              ),
            ),
          ),
        Material(
          type: MaterialType.transparency,
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final s in segments)
              Expanded(
                child: _Segment(
                  segment: s,
                  chosen: s.value == selected,
                  onChosen: onChosen,
                  onTap: () => onChanged(s.value),
                ),
              ),
          ]),
        ),
      ]),
    );
    return Semantics(container: true, explicitChildNodes: true, child: expand ? control : IntrinsicWidth(child: control));
  }
}

class _Segment extends StatefulWidget {
  const _Segment({required this.segment, required this.chosen, required this.onChosen, required this.onTap});
  final ButtonSegment<Object?> segment;
  final bool chosen;
  final Color onChosen;
  final VoidCallback onTap;

  @override
  State<_Segment> createState() => _SegmentState();
}

class _SegmentState extends State<_Segment> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final s = widget.segment;
    final enabled = s.enabled;
    final text = !enabled
        ? colors.textMuted.withValues(alpha: 0.5)
        : widget.chosen
            ? widget.onChosen
            : _pressed
                ? colors.text
                : colors.textMuted;
    // Not chosen: a faint shade of the well while hovered, the accent's tint while held down,
    // so a press already looks like the chosen segment.
    final overlay = WidgetStateProperty.resolveWith<Color?>((states) => widget.chosen
        ? Colors.transparent
        : states.contains(WidgetState.pressed)
            ? colors.accent.withValues(alpha: dark ? 0.2 : 0.14)
            : states.contains(WidgetState.hovered)
                ? colors.text.withValues(alpha: dark ? 0.06 : 0.045)
                : states.contains(WidgetState.focused)
                    ? colors.accent.withValues(alpha: 0.14)
                    : Colors.transparent);
    final label = theme.textTheme.labelLarge!.copyWith(fontSize: 13, fontWeight: FontWeight.w500, letterSpacing: 0);
    Widget segment = Semantics(
      button: true,
      selected: widget.chosen,
      inMutuallyExclusiveGroup: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(5),
        overlayColor: overlay,
        onTap: enabled ? widget.onTap : null,
        onHighlightChanged: (v) => setState(() => _pressed = v),
        child: TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: text),
          duration: stateDuration(motion(context, 200)),
          builder: (context, color, _) => IconTheme.merge(
            data: IconThemeData(color: color, size: 15),
            child: DefaultTextStyle.merge(
              style: label.copyWith(color: color),
              maxLines: 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
                  ?s.icon,
                  if (s.icon != null && s.label != null) const SizedBox(width: 6),
                  if (s.label case final label?) Flexible(child: label),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
    if (s.tooltip case final tip?) segment = Tip(message: tip, child: segment);
    return segment;
  }
}
