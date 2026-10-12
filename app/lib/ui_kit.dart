import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

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

/// Whether the theme is [UiStyle.refined] (a theme without an [AppStyle] is: it's the default).
bool isRefined(BuildContext context) => Theme.of(context).extension<AppStyle>()?.style != UiStyle.classic;

/// How long a [UiStyle.refined] menu takes to open, and to close.
const menuOpenDuration = Duration(milliseconds: 90);
const menuCloseDuration = Duration(milliseconds: 60);

/// A popup menu's row: 48 px in [UiStyle.classic], a desktop menu's in [UiStyle.refined].
double menuRowHeight(BuildContext context) => isRefined(context) ? 28 : kMinInteractiveDimension;

const _refinedItemPadding = EdgeInsets.symmetric(horizontal: 10);

/// A [PopupMenuItem] at [menuRowHeight]. Use it, not the item itself, in a menu.
PopupMenuItem<T> menuItem<T>(BuildContext context, {T? value, bool enabled = true, required Widget child}) =>
    PopupMenuItem<T>(
      value: value,
      enabled: enabled,
      height: menuRowHeight(context),
      padding: isRefined(context) ? _refinedItemPadding : null,
      child: child,
    );

/// A [PopupMenuDivider] with the space of a [menuRowHeight]'s row.
PopupMenuDivider menuDivider(BuildContext context) => PopupMenuDivider(height: isRefined(context) ? 9 : 16);

/// A checked item at [menuRowHeight]. [UiStyle.refined] draws its own: the material one is a
/// list tile, 40 px at the least however its theme is set.
PopupMenuItem<T> checkedMenuItem<T>(BuildContext context,
    {required T value, required bool checked, required Widget child}) {
  if (!isRefined(context)) return CheckedPopupMenuItem<T>(value: value, checked: checked, child: child);
  return PopupMenuItem<T>(
    value: value,
    height: menuRowHeight(context),
    padding: _refinedItemPadding,
    child: Semantics(
      role: SemanticsRole.menuItemCheckbox,
      checked: checked,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 16, child: checked ? const Icon(Icons.done, size: 16) : null),
        const SizedBox(width: 6),
        child,
      ]),
    ),
  );
}

/// A [PopupMenuButton] that opens in [menuOpenDuration] and shuts in [menuCloseDuration] in
/// [UiStyle.refined] (the material menu takes 300 ms), its rows set close. Fill it with
/// [menuItem] and [checkedMenuItem].
class AppPopupMenuButton<T> extends StatelessWidget {
  const AppPopupMenuButton({
    super.key,
    required this.itemBuilder,
    this.onSelected,
    this.tooltip,
    this.position,
    this.style,
    this.icon,
    this.iconSize,
    this.padding = const EdgeInsets.all(8),
    this.constraints,
    this.child,
  });

  final PopupMenuItemBuilder<T> itemBuilder;
  final PopupMenuItemSelected<T>? onSelected;
  final String? tooltip;
  final PopupMenuPosition? position;
  final ButtonStyle? style;
  final Widget? icon;
  final double? iconSize;
  final EdgeInsetsGeometry padding;
  final BoxConstraints? constraints;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      itemBuilder: itemBuilder,
      onSelected: onSelected,
      tooltip: tooltip,
      position: position,
      style: style,
      icon: icon,
      iconSize: iconSize,
      padding: padding,
      constraints: constraints,
      popUpAnimationStyle: isRefined(context)
          ? AnimationStyle(
              duration: menuOpenDuration,
              reverseDuration: menuCloseDuration,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeIn,
            )
          : null,
      child: child,
    );
  }
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
          animationDuration: const Duration(milliseconds: 150),
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
                duration: const Duration(milliseconds: 160),
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
