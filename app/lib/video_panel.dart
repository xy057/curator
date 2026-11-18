import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'editor_controller.dart';
import 'instruments_toolbar.dart';
import 'lanes_common.dart';
import 'menu_kit.dart';
import 'span_lane.dart';
import 'ui_kit.dart';
import 'l10n/l10n.dart';

/// What each view is called, in a menu and on the lane.
String viewName(ViewKind kind) => switch (kind) {
      ViewKind.score => 'Score'.tr,
      ViewKind.map => 'Player Map'.tr,
      ViewKind.split => 'Side by Side'.tr,
      ViewKind.inset => 'Map Inset'.tr,
    };

String _sideName(MapSide side) => switch (side) {
      MapSide.right => 'Map Right'.tr,
      MapSide.left => 'Map Left'.tr,
      MapSide.bottom => 'Map Below'.tr,
      MapSide.top => 'Map Above'.tr,
    };

String _cornerName(MapCorner corner) => switch (corner) {
      MapCorner.bottomRight => 'Bottom Right'.tr,
      MapCorner.bottomLeft => 'Bottom Left'.tr,
      MapCorner.topRight => 'Top Right'.tr,
      MapCorner.topLeft => 'Top Left'.tr,
    };

String _percent(double size) => '{n}%'.fill({'n': (size * 100).round()});

/// A change's length; none is a cut (a film's, not the clipboard's).
String _seconds(double fade) => fade <= 0 ? 'Cut'.trIn('transition') : '{n} s'.fill({'n': fade});

/// Each view's colour on the lane.
Color _viewColor(ViewKind kind) => switch (kind) {
      ViewKind.score => const Color(0xFF6E7787),
      ViewKind.map => const Color(0xFF3E6BD6),
      ViewKind.split => const Color(0xFF23907F),
      ViewKind.inset => const Color(0xFF8656C9),
    };

/// The Video tab's toolbar: the lanes' tools; the view the stretch selected shows (with nothing
/// selected, the one Draw paints), where its map goes and how big; how long the change into it
/// takes; Remove.
class VideoToolbar extends StatelessWidget {
  const VideoToolbar({super.key, required this.controller});
  final EditorController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final c = controller, a = c.automation;
          final stretch = a.selectedStretch;
          final view = stretch?.value ?? a.drawing;
          void set(SceneView v) => stretch != null ? a.setSelectedView(v) : a.drawing = v;
          return Row(children: [
            ToolGroup(children: [
              for (final MapEntry(key: tool, value: (icon, tip)) in InstrumentsToolbar.toolsIn(context).entries)
                ToolbarButton(icon: icon.of(context), tooltip: tip, selected: c.lanes.tool == tool, onPressed: () => c.lanes.tool = tool),
            ]),
            const SizedBox(width: 6),
            _Menu<ViewKind>(
              tooltip: stretch != null ? 'View'.trIn('video') : 'View to draw'.tr,
              label: viewName(view.kind),
              swatch: _viewColor(view.kind),
              values: ViewKind.values,
              chosen: view.kind,
              name: viewName,
              onSelected: (k) => set(view.copyWith(kind: k)),
            ),
            if (view.kind.hasSide)
              _Menu<MapSide>(
                tooltip: 'Where the map goes'.tr,
                label: _sideName(view.side),
                values: MapSide.values,
                chosen: view.side,
                name: _sideName,
                onSelected: (s) => set(view.copyWith(side: s)),
              ),
            if (view.kind.hasCorner)
              _Menu<MapCorner>(
                tooltip: 'Where the map goes'.tr,
                label: _cornerName(view.corner),
                values: MapCorner.values,
                chosen: view.corner,
                name: _cornerName,
                onSelected: (s) => set(view.copyWith(corner: s)),
              ),
            if (view.kind.sized)
              _Menu<double>(
                tooltip: 'Map size'.tr,
                label: _percent(view.size),
                values: {...view.kind.hasSide ? SceneView.shares : SceneView.insets, view.size}.toList()..sort(),
                chosen: view.size,
                name: _percent,
                onSelected: (s) => set(view.copyWith(size: s)),
              ),
            if (stretch != null) ...[
              const ToolbarDivider(),
              _Menu<double>(
                tooltip: 'Crossfade'.tr,
                icon: AppIcon.transition,
                label: _seconds(stretch.fade),
                values: {0.0, 0.25, 0.5, 1.0, 2.0, stretch.fade}.toList()..sort(),
                chosen: stretch.fade,
                name: _seconds,
                onSelected: a.setSelectedFade,
              ),
              ToolbarButton(icon: AppIcon.delete.of(context), tooltip: 'Remove (Delete)'.tr, onPressed: a.removeSelected),
            ],
            const Spacer(),
            if (c.playerMap.map == null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FadingText('No player map'.tr, style: TextStyle(fontSize: 12, color: context.colors.textMuted)),
              ),
          ]);
        },
      );
}

/// A toolbar's menu of [values], [chosen] checked.
class _Menu<T> extends StatelessWidget {
  const _Menu({
    required this.tooltip,
    required this.label,
    required this.values,
    required this.chosen,
    required this.name,
    required this.onSelected,
    this.icon,
    this.swatch,
  });

  final String tooltip, label;
  final List<T> values;
  final T chosen;
  final String Function(T) name;
  final ValueChanged<T> onSelected;
  final AppIcon? icon;
  final Color? swatch;

  @override
  Widget build(BuildContext context) => ToolbarValueMenu<T>(
        tooltip: tooltip,
        label: label,
        icon: icon,
        swatch: swatch,
        onSelected: onSelected,
        items: (context) => [
          for (final v in values) checkedMenuItem(context, value: v, checked: v == chosen, child: Text(name(v))),
        ],
      );
}

/// The Video tab's lanes: View, the stretches of the performance showing something other than
/// the score (drawn, moved, trimmed and erased as regions are; one drawn over others paints
/// them), each in its view's colour.
class VideoLanes extends StatelessWidget {
  const VideoLanes({super.key, required this.controller});
  final EditorController controller;

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
        SpanLane(
          controller: controller,
          model: _ViewStretches(controller),
          header: LaneLabel(
            height: SpanLane.height,
            trailing: Padding(
              padding: const EdgeInsets.only(right: 4),
              child: LaneButton(icon: AppIcon.add, tooltip: 'Add View'.tr, onPressed: controller.automation.addAtPlayhead),
            ),
            child: Text('View'.trIn('video'), style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
        ),
      ]);
}

/// The View lane as a [SpanLane] edits it: live (a drag is one Undo step), painting over.
class _ViewStretches extends SpanLaneModel {
  _ViewStretches(this.c);
  final EditorController c;

  AutomationEditing get _a => c.automation;
  List<AutoStretch<SceneView>> get _stretches => _a.views.stretches;

  /// The stretches as a drag found them: a move goes over these, an erase's pieces are of these.
  List<AutoStretch<SceneView>> _before = const [];

  @override
  List<Span> get spans => [for (final s in _stretches) (start: s.start, end: s.end)];

  @override
  int? get selected => _a.selected;

  @override
  void select(int? index) => _a.select(index);

  @override
  bool get live => true;

  @override
  bool get paints => true;

  @override
  void begin() => _before = _stretches;

  @override
  void update(int index, double start, double end) {
    if (index >= _before.length) return;
    final next = _before[index].withBounds(start, end), lane = _a.views.reshaped(index, next, base: _before);
    _a.setSteps(lane);
    _a.select(lane.indexOf(next));
  }

  @override
  void replaceAll(List<({int from, double start, double end})> pieces) {
    _a.select(null);
    _a.setSteps(StepLane(SceneViews.target, [
      for (final p in pieces)
        if (p.from < _before.length) _before[p.from].withBounds(p.start, p.end),
    ]));
  }

  @override
  void drawn(double start, double end) => _a.draw(start, end);

  @override
  void open(int index) => _a.select(index);

  @override
  String? label(int index) {
    final v = _stretches[index].value;
    return switch (v.kind) {
      ViewKind.split => '${viewName(v.kind)} · ${_sideName(v.side)} · ${_percent(v.size)}',
      ViewKind.inset => '${viewName(v.kind)} · ${_cornerName(v.corner)}',
      _ => viewName(v.kind),
    };
  }

  @override
  Color? color(int index) => _viewColor(_stretches[index].value.kind);
}
