import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'audio_panel.dart';
import 'caption_lane.dart';
import 'editor_controller.dart';
import 'lanes_common.dart';
import 'instruments_toolbar.dart';
import 'timeline_panel.dart';
import 'ui_kit.dart';

/// The DAW-like panel under the preview. The switch at its top-left changes between the
/// Instruments tab (when each staff is shown) and the Audio tab (syncing to the recording).
/// Both share one time axis, so zoom and scroll carry over. With Captions on, its lane is
/// pinned under the ruler in both. Project Settings… sits at its right end.
class BottomPanel extends StatelessWidget {
  const BottomPanel({super.key, required this.controller, this.onProjectSettings});
  final EditorController controller;

  /// Opens Project Settings (Edit ▸ Project Settings…).
  final VoidCallback? onProjectSettings;

  static const _switch = Duration(milliseconds: 220);

  @override
  Widget build(BuildContext context) => Select(
        listenable: controller,
        select: () => (
          score: controller.score,
          curation: controller.curation,
          sync: controller.sync,
          tab: controller.tab,
          captions: controller.captions.enabled,
          duration: controller.playback.duration,
        ),
        builder: (context, _) => _panel(context),
      );

  Widget _panel(BuildContext context) {
    final c = controller;
    if (c.score == null || c.curation == null || c.sync == null) return const SizedBox.shrink();
    final audio = c.tab == BottomTab.audio;
    final colors = context.colors;
    return ColoredBox(
      color: colors.surface,
      child: Column(children: [
        Container(
          height: AppStyle.of(context).panelBar,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(color: colors.chrome, border: Border(bottom: BorderSide(color: colors.line))),
          child: Row(children: [
            _TabSwitch(value: c.tab, onChanged: (tab) => c.tab = tab),
            const ToolbarDivider(),
            Expanded(
              child: AnimatedSwitcher(
                duration: AppStyle.of(context).moving(_switch),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                layoutBuilder: (current, previous) =>
                    Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
                transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
                child: audio
                    ? AudioToolbar(key: const ValueKey('audio'), controller: c)
                    : InstrumentsToolbar(key: const ValueKey('instruments'), controller: c),
              ),
            ),
            const ToolbarDivider(),
            _ZoomButtons(controller: c),
            ToolbarButton(
              icon: AppIcon.fit.of(context),
              tooltip: 'Fit',
              onPressed: c.viewport.fit,
            ),
            const ToolbarDivider(),
            ToolbarButton(
              icon: AppIcon.settings.of(context),
              tooltip: 'Project Settings (${shortcut('⇧⌘,')})',
              onPressed: onProjectSettings,
            ),
          ]),
        ),
        Expanded(
          // The same lanes at every width: resizing the window lays them out again (their
          // painters read the viewport as they paint) without rebuilding them.
          child: _Width(
            onWidth: (width) => c.viewport.setWidth(width - kLaneHeaderWidth, c.playback.duration),
            child: ViewportGestures(
              controller: c,
              child: Column(children: [
                BarRuler(controller: c),
                // Pinned: under the ruler in both tabs, never scrolled away.
                if (c.captions.enabled) CaptionLane(controller: c),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: AppStyle.of(context).moving(_switch),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween(begin: Offset(0, audio ? 0.03 : -0.03), end: Offset.zero).animate(animation),
                        child: child,
                      ),
                    ),
                    child: audio
                        ? AudioLanes(key: const ValueKey('audio'), controller: c)
                        : InstrumentLanes(key: const ValueKey('instruments'), controller: c),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Zoom out and in: in a narrow window only Fit stays (pinch or ⌘-scroll zoom anyway). On
/// its own, so a resize rebuilds only these.
class _ZoomButtons extends StatelessWidget {
  const _ZoomButtons({required this.controller});
  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width < 1100) return const SizedBox.shrink();
    final v = controller.viewport;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      ToolbarButton(icon: AppIcon.zoomOut.of(context), tooltip: 'Zoom out (${shortcut('⌘-scroll')} or pinch)', onPressed: () => v.zoom(1 / 1.5)),
      ToolbarButton(icon: AppIcon.zoomIn.of(context), tooltip: 'Zoom in (${shortcut('⌘-scroll')} or pinch)', onPressed: () => v.zoom(1.5)),
    ]);
  }
}

/// Tells [onWidth] the width it is laid out at, before its child is laid out, and builds
/// nothing for it.
class _Width extends StatelessWidget {
  const _Width({required this.onWidth, required this.child});
  final ValueChanged<double> onWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
        onWidth(constraints.maxWidth);
        return child;
      });
}

/// Instruments | Audio, as two icons with a highlight that slides between them.
class _TabSwitch extends StatelessWidget {
  const _TabSwitch({required this.value, required this.onChanged});
  final BottomTab value;
  final ValueChanged<BottomTab> onChanged;

  static const _tabs = [
    (BottomTab.instruments, AppIcon.lanes, 'Instruments'),
    (BottomTab.audio, AppIcon.audio, 'Audio'),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // In a well, the chosen icon in the text colour; Carbon's icon content switcher: edged in
    // $border-inverse, the chosen one inverse.
    final style = AppStyle.of(context);
    final k = CarbonColors.maybeOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final size = k != null ? 30.0 : 26.0;
    final well = k != null ? Colors.transparent : colors.well;
    final knob = k?.selectedInverse ?? (dark ? RefinedGreys.dark600 : colors.surface);
    final chosen = k?.textInverse ?? colors.text;
    final index = _tabs.indexWhere((t) => t.$1 == value);
    return Container(
      padding: EdgeInsets.all(k != null ? 0 : 2),
      decoration: BoxDecoration(color: well, border: Border.all(color: k?.borderInverse ?? colors.line), borderRadius: style.radius(7)),
      child: Stack(children: [
        AnimatedPositioned(
          duration: motion(context, 220),
          curve: style.curve,
          left: index * size,
          top: 0,
          width: size,
          height: size,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: knob,
              borderRadius: style.radius(5),
              boxShadow: [if (k == null) BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 3, offset: const Offset(0, 1))],
              border: k != null ? null : Border.all(color: colors.line),
            ),
          ),
        ),
        Row(mainAxisSize: MainAxisSize.min, children: [
          for (final (tab, icon, tip) in _tabs)
            Tip(
              message: tip,
              child: InkWell(
                borderRadius: style.radius(5),
                onTap: () => onChanged(tab),
                child: SizedBox.square(
                  dimension: size,
                  child: TweenAnimationBuilder<Color?>(
                    duration: stateDuration(motion(context, 200)),
                    tween: ColorTween(end: tab == value ? chosen : k?.textSecondary ?? colors.textMuted),
                    builder: (context, color, _) => Icon(icon.of(context), size: 16, color: color),
                  ),
                ),
              ),
            ),
        ]),
      ]),
    );
  }
}
