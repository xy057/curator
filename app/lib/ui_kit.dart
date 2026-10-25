import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

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

/// [ms] milliseconds of Material's motion, as the style has it ([AppStyle.duration]).
Duration motion(BuildContext context, int ms) => AppStyle.of(context).duration(ms);

/// A field with its [label] over it, as the app's dialogs label their fields (Carbon's label-01).
class FieldLabel extends StatelessWidget {
  const FieldLabel({super.key, required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final carbon = AppStyle.of(context).isCarbon;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: EdgeInsets.only(bottom: carbon ? 8 : 6),
        child: Text(label,
            style: carbon
                ? TextStyle(fontSize: 12, height: 16 / 12, letterSpacing: 0.32, color: context.colors.textMuted)
                : TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: context.colors.textMuted)),
      ),
      child,
    ]);
  }
}

/// The compact icon button used in every toolbar: [AppStyle.control] square, its label in the
/// tooltip; when selected a neutral fill (Carbon's $background-selected) under an accent icon
/// (Carbon's $icon-primary).
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
    final style = AppStyle.of(context);
    final carbon = CarbonColors.maybeOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final size = style.control;
    final fill = carbon?.backgroundSelected ?? (dark ? Colors.white : Colors.black).withValues(alpha: dark ? 0.1 : 0.05);
    return OverlaySemantics(
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        isSelected: selected,
        iconSize: 16,
        visualDensity: VisualDensity.compact,
        constraints: BoxConstraints.tightFor(width: size, height: size),
        padding: EdgeInsets.zero,
        style: (carbon == null
                ? IconButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: style.radius(5)))
                : const ButtonStyle())
            .copyWith(
          foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled)
              ? null
              : selected
                  ? (carbon != null ? colors.text : dark ? colors.accent : colors.accentStrong)
                  : color ??
                      // Refined: an icon at rest a little softer than text (a glyph is heavier than
                      // the words beside it), full strength under the pointer.
                      (carbon != null || s.contains(WidgetState.hovered) || s.contains(WidgetState.pressed)
                          ? colors.text
                          : Color.lerp(colors.text, colors.textMuted, 0.35))),
          backgroundColor: selected ? WidgetStatePropertyAll(fill) : null,
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
          borderRadius: AppStyle.of(context).radius(7),
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
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  // Pulses unless the interface keeps still (Reduce motion), then a steady dot.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppStyle.of(context).still) {
      _pulse.value = 0;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

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

/// The app's on/off switch: always use it rather than [Switch]. Drawn alike on every platform:
/// in [UiStyle.refined] a small track in the accent with a white knob that slides; in
/// [UiStyle.carbon] Carbon's small toggle, $support-success when on, a check in its knob.
class AppSwitch extends StatefulWidget {
  const AppSwitch({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool>? onChanged;

  /// The track: Refined's, or Carbon's small toggle's.
  static Size sizeOf(AppStyle style) => style.isCarbon ? const Size(32, 16) : const Size(34, 20);

  @override
  State<AppSwitch> createState() => _AppSwitchState();
}

class _AppSwitchState extends State<AppSwitch> {
  bool _hovered = false, _focused = false;

  void _toggle() => widget.onChanged?.call(!widget.value);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = AppStyle.of(context);
    // The app's palette, or where there is none (a dialog shown on its own) the theme's.
    final colors = theme.extension<AppColors>();
    final carbon = CarbonColors.maybeOf(context);
    final dark = theme.brightness == Brightness.dark;
    final enabled = widget.onChanged != null;
    final accent = colors?.accent ?? theme.colorScheme.primary;
    final on = carbon?.success ?? (dark ? accent : (colors?.accentStrong ?? accent));
    final off = carbon?.toggleOff ?? (dark ? RefinedGreys.dark600 : RefinedGreys.g300);
    // Carbon's toggle shows no hover; its disabled one is drawn, not faded.
    final hoverShade = (dark ? Colors.white : Colors.black).withValues(alpha: _hovered && enabled && carbon == null ? 0.07 : 0);
    CustomPainter painter(double t) => carbon == null
        ? _SwitchPainter(
            t: t,
            track: Color.alphaBlend(hoverShade, Color.lerp(off, on, t)!),
            focus: _focused ? accent.withValues(alpha: 0.45) : null,
          )
        : _CarbonTogglePainter(
            t: t,
            track: enabled ? Color.lerp(off, on, t)! : carbon.buttonDisabled,
            knob: enabled ? Colors.white : carbon.onColorDisabled,
            focus: _focused ? (carbon.focus, carbon.focusInset) : null,
          );
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
            opacity: enabled || carbon != null ? 1 : 0.45,
            // The tap area is a little larger than the track, as a Material switch's is.
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: widget.value ? 1 : 0),
                duration: motion(context, 160),
                curve: style.curve,
                builder: (context, t, _) => CustomPaint(size: AppSwitch.sizeOf(style), painter: painter(t)),
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

/// Carbon's small toggle: a 32 × 16 track, a 10 px knob 3 px in, and when on a check in the
/// knob in the track's colour; focused, a 1 px gap ($focus-inset) and a 2 px ring ($focus).
class _CarbonTogglePainter extends CustomPainter {
  _CarbonTogglePainter({required this.t, required this.track, required this.knob, required this.focus});
  final double t;
  final Color track, knob;
  final (Color, Color)? focus;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.height / 2;
    final rect = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(r));
    if (focus case (final ring, final inset)) {
      canvas.drawRRect(rect.inflate(2), Paint()..color = ring..style = PaintingStyle.stroke..strokeWidth = 2);
      canvas.drawRRect(rect.inflate(0.5), Paint()..color = inset..style = PaintingStyle.stroke..strokeWidth = 1);
    }
    canvas.drawRRect(rect, Paint()..color = track);
    const inset = 3.0, knobSize = 10.0;
    final knobCentre = Offset(inset + knobSize / 2 + (size.width - 2 * inset - knobSize) * t, r);
    canvas.drawCircle(knobCentre, knobSize / 2, Paint()..color = knob);
    if (t > 0.5) {
      // Carbon's checkmark, 6 × 5 in the knob.
      final o = knobCentre - const Offset(3, 2.5);
      final check = Path()
        ..moveTo(o.dx + 0.4, o.dy + 2.6)
        ..lineTo(o.dx + 2.3, o.dy + 4.4)
        ..lineTo(o.dx + 5.6, o.dy + 0.6);
      canvas.drawPath(
          check,
          Paint()
            ..color = track.withValues(alpha: (t - 0.5) * 2)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4
            ..strokeCap = StrokeCap.square);
    }
  }

  @override
  bool shouldRepaint(_CarbonTogglePainter old) => old.t != t || old.track != track || old.knob != knob || old.focus != focus;
}

/// Painted in the window, but not in the still a change of appearance fades from (main.dart)
/// while [moving]: something that moves meanwhile, which the still would hold where it was,
/// fading out there. Still, it is in the still, and cross-fades to its new colours as the rest
/// of the window does.
class LeftOutOfStills extends SingleChildRenderObjectWidget {
  const LeftOutOfStills({super.key, required this.moving, super.child});

  /// Asked as the still is taken.
  final bool Function() moving;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderLeftOutOfStills(moving);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) =>
      (renderObject as _RenderLeftOutOfStills).moving = moving;
}

class _RenderLeftOutOfStills extends RenderProxyBox {
  _RenderLeftOutOfStills(this.moving);
  bool Function() moving;

  static final _attached = <_RenderLeftOutOfStills>{};

  OpacityLayer? get _opacity => layer as OpacityLayer?;

  @override
  bool get alwaysNeedsCompositing => child != null;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _attached.add(this);
  }

  @override
  void detach() {
    _attached.remove(this);
    super.detach();
  }

  // Its own layer, fully opaque but for the moment a still is taken.
  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) {
      layer = null;
      return;
    }
    layer = context.pushOpacity(offset, 255, super.paint, oldLayer: layer as OpacityLayer?);
  }
}

/// [capture] (a still of the window) with every [LeftOutOfStills] that is moving hidden.
T withoutLeftOut<T>(T Function() capture) {
  final layers = [for (final r in _RenderLeftOutOfStills._attached) if (r.moving()) ?r._opacity];
  for (final l in layers) {
    l.alpha = 0;
  }
  try {
    return capture();
  } finally {
    for (final l in layers) {
      l.alpha = 255;
    }
  }
}

/// The app's segmented control: always use it rather than [SegmentedButton]. A row of segments
/// whose chosen one's fill slides to the segment clicked, each label taking the chosen colour as
/// the fill passes under it: in [UiStyle.refined] a clear track and a light tint of the accent;
/// in [UiStyle.carbon] Carbon's content switcher, edged in $border-inverse, the chosen segment
/// $layer-selected-inverse. A click chooses at once ([onChanged]); the fill is
/// [LeftOutOfStills], so a change of appearance it makes (Theme, Style) fades from a still
/// without it, not one holding it where it started. Segments are as wide as the widest, or
/// share the width given with [expand].
class AppSegmented<T> extends StatefulWidget {
  const AppSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.expand = false,
  });
  final List<ButtonSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;
  final bool expand;

  @override
  State<AppSegmented<T>> createState() => _AppSegmentedState<T>();
}

class _AppSegmentedState<T> extends State<AppSegmented<T>> with SingleTickerProviderStateMixin {
  /// Where the tint is, in segments: 0 over the first, 1 over the second, and between while it slides.
  late final _at = AnimationController.unbounded(vsync: this, value: math.max(_indexOf(widget.selected), 0).toDouble());

  int _indexOf(T value) => widget.segments.indexWhere((s) => s.value == value);

  /// A click is choosing: the tint is about to slide, though it hasn't started yet.
  bool _choosing = false;

  void _choose(T value) {
    if (value == widget.selected) return;
    _choosing = true;
    try {
      widget.onChanged(value);
    } finally {
      _choosing = false;
    }
  }

  /// Out of a still while it slides, or is about to (a click on Theme takes the still before the
  /// tint sets off); in it otherwise, so a change of accent cross-fades it as the rest.
  bool _moving() => _choosing || _at.isAnimating;

  // The tint follows what is chosen, from wherever it is.
  @override
  void didUpdateWidget(AppSegmented<T> old) {
    super.didUpdateWidget(old);
    final index = _indexOf(widget.selected);
    if (widget.segments.length != old.segments.length) {
      _at.value = math.max(index, 0).toDouble();
    } else if (widget.selected != old.selected && index >= 0) {
      _at.animateTo(index.toDouble(), duration: motion(context, 320), curve: Curves.fastOutSlowIn);
    }
  }

  @override
  void dispose() {
    _at.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final style = AppStyle.of(context);
    final carbon = CarbonColors.maybeOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final segments = widget.segments;
    final n = segments.length;
    final index = _indexOf(widget.selected);
    final shown = index >= 0;
    // Refined's chosen segment: the accent's light tint, edged with the accent, its label the
    // accent reading on the tint (AppColors.accentOn). Carbon's: inverse, its label $text-inverse.
    final chosen = carbon?.selectedInverse ?? colors.accentSoft;
    final onChosen = carbon?.textInverse ?? colors.accentOn(chosen, dark: dark);
    final unchosen = carbon?.textSecondary ?? colors.textMuted;
    final inner = carbon == null ? 2.0 : 1.0;
    final control = Container(
      height: 32,
      padding: EdgeInsets.all(inner),
      // Clear: the track takes the colour of what it is on, its edge marking it out.
      decoration: BoxDecoration(
          border: Border.all(color: carbon?.borderInverse ?? colors.line), borderRadius: style.radius(7)),
      child: AnimatedBuilder(
        animation: _at,
        builder: (context, _) {
          final at = _at.value;
          // How much of segment i the fill covers.
          double covered(int i) => shown ? (1 - (at - i).abs()).clamp(0, 1).toDouble() : 0;
          return Stack(fit: StackFit.expand, children: [
            if (shown)
              Align(
                alignment: Alignment(n == 1 ? 0 : -1 + 2 * at / (n - 1), 0),
                child: FractionallySizedBox(
                  widthFactor: 1 / n,
                  heightFactor: 1,
                  child: LeftOutOfStills(
                    moving: _moving,
                    child: DecoratedBox(
                      decoration: carbon != null
                          ? BoxDecoration(color: chosen)
                          : BoxDecoration(
                              color: chosen,
                              border: Border.all(color: colors.accent.withValues(alpha: dark ? 0.5 : 0.45)),
                              borderRadius: style.radius(5),
                              boxShadow: [
                                BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.2 : 0.06), blurRadius: 2, offset: const Offset(0, 1)),
                              ],
                            ),
                    ),
                  ),
                ),
              ),
            // Carbon: a short rule between two segments the fill isn't on.
            if (carbon != null)
              for (var i = 1; i < n; i++)
                Align(
                  alignment: Alignment(-1 + 2 * i / n, 0),
                  child: Container(
                    width: 1,
                    height: 16,
                    color: carbon.borderSubtle.withValues(alpha: 1 - math.max(covered(i - 1), covered(i))),
                  ),
                ),
            Material(
              type: MaterialType.transparency,
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final (i, s) in segments.indexed)
                  Expanded(
                    child: _Segment(
                      segment: s,
                      chosen: s.value == widget.selected,
                      sliding: _at.isAnimating,
                      // As much of the chosen colour as the fill covers of this segment.
                      color: !s.enabled
                          ? (carbon?.textDisabled ?? colors.textMuted.withValues(alpha: 0.5))
                          : Color.lerp(unchosen, onChosen, covered(i))!,
                      onTap: () => _choose(s.value),
                    ),
                  ),
              ]),
            ),
          ]);
        },
      ),
    );
    return Semantics(
        container: true, explicitChildNodes: true, child: widget.expand ? control : IntrinsicWidth(child: control));
  }
}

class _Segment extends StatefulWidget {
  const _Segment({
    required this.segment,
    required this.chosen,
    required this.sliding,
    required this.color,
    required this.onTap,
  });
  final ButtonSegment<Object?> segment;
  final bool chosen;

  /// The tint is on its way: no shade under the mouse, so only the tint and the labels change.
  final bool sliding;
  final Color color;
  final VoidCallback onTap;

  @override
  State<_Segment> createState() => _SegmentState();
}

class _SegmentState extends State<_Segment> {
  bool _hovered = false, _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final style = AppStyle.of(context);
    final carbon = CarbonColors.maybeOf(context);
    final dark = theme.brightness == Brightness.dark;
    final s = widget.segment;
    // Not chosen: a faint shade while hovered (Carbon's $layer-hover), and held down a faint
    // tint of the accent, so a press already looks like the chosen one (Carbon's
    // $background-active); none while the fill slides. Drawn here, not as the ink's overlay, so
    // it fades out as the slide starts and back in when it lands (the ink would change colour in
    // one frame). None is the hover's shade at no opacity: from another colour at none, the fade
    // passes through that colour (Carbon's text, near black or white, at half the shade's opacity).
    final none = (carbon?.layerHover ?? colors.text).withValues(alpha: 0);
    final shade = widget.chosen || widget.sliding || !s.enabled
        ? none
        : _pressed
            ? carbon?.backgroundActive ?? colors.accent.withValues(alpha: dark ? 0.2 : 0.14)
            : _hovered
                ? carbon?.layerHover ?? colors.text.withValues(alpha: dark ? 0.06 : 0.045)
                : none;
    final label = carbon != null
        ? theme.textTheme.bodyMedium!.copyWith(fontSize: 14, letterSpacing: 0.16, color: widget.color)
        : theme.textTheme.labelLarge!.copyWith(fontSize: 13, fontWeight: FontWeight.w500, letterSpacing: 0, color: widget.color);
    final radius = style.radius(5);
    Widget button = Semantics(
      button: true,
      selected: widget.chosen,
      inMutuallyExclusiveGroup: true,
      child: InkWell(
        borderRadius: radius,
        // Only a keyboard's focus, as the accent's tint.
        overlayColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.focused) && !widget.chosen
            ? colors.accent.withValues(alpha: 0.14)
            : Colors.transparent),
        onTap: s.enabled ? widget.onTap : null,
        onHover: (v) => setState(() => _hovered = v),
        onHighlightChanged: (v) => setState(() => _pressed = v),
        child: AnimatedContainer(
          duration: stateDuration(motion(context, 150)),
          curve: style.curve,
          decoration: BoxDecoration(color: shade, borderRadius: radius),
          child: IconTheme.merge(
            data: IconThemeData(color: widget.color, size: carbon != null ? 16 : 15),
            child: DefaultTextStyle.merge(
              style: label,
              maxLines: 1,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: carbon != null ? 16 : 12),
                child: Row(
                    // Carbon's content switcher sets its labels at the start.
                    mainAxisAlignment: carbon != null ? MainAxisAlignment.start : MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ?s.icon,
                      if (s.icon != null && s.label != null) SizedBox(width: carbon != null ? 8 : 6),
                      if (s.label case final label?) Flexible(child: label),
                    ]),
              ),
            ),
          ),
        ),
      ),
    );
    if (s.tooltip case final tip?) button = Tip(message: tip, child: button);
    return button;
  }
}

/// A field's borders as the style draws them, at rest and focused: Refined's outline (the
/// accent's when focused, red when [bad]); Carbon's line under a filled field, and a 2 px ring
/// in $focus (in $support-error when [bad]).
({InputBorder rest, InputBorder focused}) fieldBorders(BuildContext context, {bool bad = false, double radius = 8}) {
  final colors = context.colors;
  if (CarbonColors.maybeOf(context) case final k?) {
    return (
      rest: bad ? CarbonFieldBorder(ring: true, borderSide: BorderSide(color: k.error, width: 2)) : CarbonFieldBorder(borderSide: BorderSide(color: k.borderStrong)),
      focused: CarbonFieldBorder(ring: true, borderSide: BorderSide(color: bad ? k.error : k.focus, width: 2)),
    );
  }
  // No gap: it is room for a floating label (labels are over the field), and it moves the text
  // further in than [AppStyle.fieldInset].
  OutlineInputBorder border(Color color, [double width = 1]) =>
      OutlineInputBorder(gapPadding: 0, borderRadius: BorderRadius.circular(radius), borderSide: BorderSide(color: color, width: width));
  return (rest: border(bad ? colors.erase : colors.line), focused: border(bad ? colors.erase : colors.accent, 1.5));
}

/// A field's fill: Carbon's $field (a field on a layer), none in Refined.
Color? fieldFill(BuildContext context) => CarbonColors.maybeOf(context)?.field;

/// Carbon's field border: a line along the bottom of a filled field, or ([ring]) a square ring
/// all round it (focused, or invalid). An outline to the [InputDecorator] in both, so the text
/// sits at one place whichever it is.
class CarbonFieldBorder extends OutlineInputBorder {
  const CarbonFieldBorder({required super.borderSide, this.ring = false}) : super(borderRadius: BorderRadius.zero, gapPadding: 0);
  final bool ring;

  @override
  CarbonFieldBorder copyWith({BorderSide? borderSide, BorderRadius? borderRadius, double? gapPadding}) =>
      CarbonFieldBorder(borderSide: borderSide ?? this.borderSide, ring: ring);

  @override
  CarbonFieldBorder scale(double t) => CarbonFieldBorder(borderSide: borderSide.scale(t), ring: ring);

  // Carbon's field changes its border at once.
  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) => this;

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) => b;

  @override
  void paint(Canvas canvas, Rect rect,
      {double? gapStart, double gapExtent = 0.0, double gapPercentage = 0.0, TextDirection? textDirection}) {
    final w = borderSide.width;
    final paint = Paint()
      ..color = borderSide.color
      ..strokeWidth = w
      ..style = PaintingStyle.stroke;
    if (ring) {
      canvas.drawRect(rect.deflate(w / 2), paint);
    } else {
      canvas.drawLine(rect.bottomLeft.translate(0, -w / 2), rect.bottomRight.translate(0, -w / 2), paint);
    }
  }

  @override
  bool operator ==(Object other) => other is CarbonFieldBorder && other.ring == ring && other.borderSide == borderSide;

  @override
  int get hashCode => Object.hash(ring, borderSide);
}
