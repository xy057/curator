import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart' show ExtensionRuntime, GraphNode;

import 'app_colors.dart';
import 'audio_panel.dart';
import 'extensions/extension_lane.dart';
import 'editor_controller.dart';
import 'lanes_common.dart';
import 'panel_bar.dart';
import 'spacer_lane.dart';
import 'timeline_panel.dart';
import 'toolbar_layout.dart';
import 'ui_kit.dart';
import 'video_panel.dart';

/// The DAW-like panel under the preview. The switch at its top-left ([PanelBar]) changes between
/// the Instruments tab (when each staff is shown), the Audio tab (syncing to the recording) and
/// the Video tab (what a frame shows when: [VideoLanes]), each with its tools on the bar. All
/// share one time axis, so zoom and scroll carry over. Extensions' lanes (Tonality's,
/// Captions', Chapters') are pinned under the ruler in both, by their order; with Attach Image
/// on, the Spacers lane among them.
class BottomPanel extends StatelessWidget {
  const BottomPanel({super.key, required this.controller, this.layoutOf, this.onLayout, this.onCustomize, this.commands, this.commandsChanged});
  final EditorController controller;

  /// Its bar's ([PanelBar]): where each tab's tools are and what changes that, what starts
  /// customizing it, and the app's commands for the buttons that do one.
  final ToolbarLayout Function(BarKind kind)? layoutOf;
  final ValueChanged<ToolbarLayout>? onLayout;
  final VoidCallback? onCustomize;
  final Map<String, VoidCallback?> Function()? commands;
  final Listenable? commandsChanged;

  static const _switch = Duration(milliseconds: 220);

  /// Where the Spacers lane sits among the pinned lanes (a lane's `order` in a connector).
  static const _spacersOrder = 40;

  /// An extension's lane, as its kind says: markers, or spans.
  Widget _lane(ExtensionRuntime runtime, GraphNode node) => node.props['kind'] == 'spans'
      ? ExtensionSpanLane(controller: controller, runtime: runtime, node: node)
      : ExtensionLane(controller: controller, runtime: runtime, node: node);

  @override
  Widget build(BuildContext context) => Select(
        listenable: controller,
        select: () => (
          score: controller.score,
          curation: controller.curation,
          sync: controller.sync,
          tab: controller.tab,
          spacers: controller.spacers.enabled,
          // (Which runtime too: one run again from its files is another.)
          extensions: [for (final lane in controller.extensions.lanes) '${lane.runtime.id} ${lane.node.id} ${identityHashCode(lane.runtime)}'].join('\n'),
          duration: controller.playback.duration,
        ),
        builder: (context, _) => _panel(context),
      );

  Widget _panel(BuildContext context) {
    final c = controller;
    if (c.score == null || c.curation == null || c.sync == null) return const SizedBox.shrink();
    final up = c.tab == BottomTab.instruments; // the lanes come down from above, going to it
    final colors = context.colors;
    return ColoredBox(
      color: colors.surface,
      child: Column(children: [
        PanelBar(
          controller: c,
          layoutOf: layoutOf,
          onLayout: onLayout,
          onCustomize: onCustomize,
          commands: commands,
          commandsChanged: commandsChanged,
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
                // Pinned: under the ruler in every tab, never scrolled away. Extensions' lanes go
                // by their order (Tonality's first: its band tops the score), the app's Spacers
                // lane among them; any other under them.
                for (final lane in c.extensions.lanes)
                  if (lane.order < _spacersOrder) _lane(lane.runtime, lane.node),
                if (c.spacers.enabled) SpacerLane(controller: c),
                for (final lane in c.extensions.lanes)
                  if (lane.order >= _spacersOrder) _lane(lane.runtime, lane.node),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: AppStyle.of(context).moving(_switch),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween(begin: Offset(0, up ? -0.03 : 0.03), end: Offset.zero).animate(animation),
                        child: child,
                      ),
                    ),
                    child: switch (c.tab) {
                      BottomTab.audio => AudioLanes(key: const ValueKey('audio'), controller: c),
                      BottomTab.video => Align(alignment: Alignment.topCenter, child: VideoLanes(key: const ValueKey('video'), controller: c)),
                      BottomTab.instruments => InstrumentLanes(key: const ValueKey('instruments'), controller: c),
                    },
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
