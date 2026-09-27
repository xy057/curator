import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'audio_panel.dart';
import 'editor_controller.dart';
import 'lanes_common.dart';
import 'timeline_panel.dart';
import 'ui_kit.dart';

/// The DAW-like panel under the preview. The switch at its top-left changes between the
/// Instruments tab (when each staff is shown) and the Audio tab (syncing to the recording).
/// Both share one time axis, so zoom and scroll carry over.
class BottomPanel extends StatelessWidget {
  const BottomPanel({super.key, required this.controller});
  final EditorController controller;

  static const _switch = Duration(milliseconds: 220);

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c.score == null || c.curation == null || c.sync == null) return const SizedBox.shrink();
    final audio = c.tab == BottomTab.audio;
    final colors = context.colors;
    return ColoredBox(
      color: colors.surface,
      child: Column(children: [
        Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: colors.line))),
          child: Row(children: [
            _TabSwitch(value: c.tab, onChanged: (tab) => c.tab = tab),
            const ToolbarDivider(),
            Expanded(
              child: AnimatedSwitcher(
                duration: _switch,
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
            // In a narrow window only Fit stays: pinch or ⌘-scroll zoom anyway.
            if (MediaQuery.sizeOf(context).width >= 1100) ...[
              ToolbarButton(icon: Icons.zoom_out_rounded, tooltip: 'Zoom out (${shortcut('⌘-scroll', 'Ctrl-scroll')})', onPressed: () => c.viewport.zoom(1 / 1.5)),
              ToolbarButton(icon: Icons.zoom_in_rounded, tooltip: 'Zoom in (${shortcut('⌘-scroll', 'Ctrl-scroll')} or pinch)', onPressed: () => c.viewport.zoom(1.5)),
            ],
            ToolbarButton(
              icon: Icons.fit_screen_outlined,
              tooltip: 'Fit the whole piece\nZoom with ${shortcut('⌘-scroll', 'Ctrl-scroll')} or a pinch',
              onPressed: c.viewport.fit,
            ),
          ]),
        ),
        Expanded(
          child: LayoutBuilder(builder: (context, constraints) {
            c.viewport.setWidth(constraints.maxWidth - kLaneHeaderWidth, c.playback.duration);
            return ViewportGestures(
              controller: c,
              child: Column(children: [
                BarRuler(controller: c),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: _switch,
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
            );
          }),
        ),
      ]),
    );
  }
}

/// Instruments | Audio, as two icons with a highlight that slides between them.
class _TabSwitch extends StatelessWidget {
  const _TabSwitch({required this.value, required this.onChanged});
  final BottomTab value;
  final ValueChanged<BottomTab> onChanged;

  static const _tabs = [
    (BottomTab.instruments, Icons.view_list_rounded, 'Instruments\nWhen each instrument’s staff is shown'),
    (BottomTab.audio, Icons.graphic_eq_rounded, 'Audio\nSync the score to the recording'),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    const size = 32.0;
    final index = _tabs.indexWhere((t) => t.$1 == value);
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: colors.accentWash, border: Border.all(color: colors.line), borderRadius: BorderRadius.circular(10)),
      child: Stack(children: [
        AnimatedPositioned(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          left: index * size,
          top: 0,
          width: size,
          height: size,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(8),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 3, offset: const Offset(0, 1))],
              border: Border.all(color: colors.line),
            ),
          ),
        ),
        Row(mainAxisSize: MainAxisSize.min, children: [
          for (final (tab, icon, tip) in _tabs)
            Tooltip(
              message: tip,
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => onChanged(tab),
                child: SizedBox.square(
                  dimension: size,
                  child: TweenAnimationBuilder<Color?>(
                    duration: const Duration(milliseconds: 200),
                    tween: ColorTween(end: tab == value ? colors.accentStrong : colors.textMuted),
                    builder: (context, color, _) => Icon(icon, size: 18, color: color),
                  ),
                ),
              ),
            ),
        ]),
      ]),
    );
  }
}
