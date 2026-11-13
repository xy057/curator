import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'app_settings.dart';
import 'editor_controller.dart';
import 'key_bindings.dart';
import 'menu_kit.dart';
import 'ui_kit.dart';
import 'l10n/l10n.dart';

/// Instruments tab tools (right of the tab switch). Every button explains itself on hover.
class InstrumentsToolbar extends StatelessWidget {
  const InstrumentsToolbar({super.key, required this.controller});
  final EditorController controller;

  /// Each tool's icon and hover text: its name and key (as set where [context] is), then what
  /// each key held changes.
  static Map<LaneTool, (AppIcon, String)> toolsIn(BuildContext context) => {
        LaneTool.select: (
          AppIcon.pointer,
          '${keyed(context, KeyCommand.selectTool, (key) => 'Select ({key})'.fill({'key': key}), 'Select'.tr)}\n'
              '${shortcut('⇧ add · ⌘ toggle, no snap · ⌥ draw'.tr)}'
        ),
        LaneTool.draw: (
          AppIcon.draw,
          '${keyed(context, KeyCommand.drawTool, (key) => 'Draw ({key})'.fill({'key': key}), 'Draw'.tr)}\n${shortcut('⌘ no snap · ⌥ erase'.tr)}'
        ),
        LaneTool.erase: (
          AppIcon.erase,
          '${keyed(context, KeyCommand.eraseTool, (key) => 'Erase ({key})'.fill({'key': key}), 'Erase'.tr)}\n${shortcut('⌘ no snap · ⌥ draw'.tr)}'
        ),
      };

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final curation = c.curation!;
    final score = c.score!;
    return ListenableBuilder(
      listenable: Listenable.merge([curation, c]),
      builder: (context, _) {
        final selected = c.lanes.selected;
        final lanes = c.lanes.selectedPartIds;
        final status = _status(c, score, c.lanes.selection, lanes);
        return Row(
          children: [
            ToolGroup(children: [
              for (final MapEntry(key: tool, value: (icon, tip)) in toolsIn(context).entries)
                ToolbarButton(icon: icon.of(context), tooltip: tip, selected: c.lanes.tool == tool, onPressed: () => c.lanes.tool = tool),
            ]),
            const SizedBox(width: 10),
            Expanded(child: FadingText(status, style: TextStyle(fontSize: 12, color: context.colors.textMuted))),
            FadeSlideSwitcher(
              alignment: Alignment.centerRight,
              child: selected.isEmpty
                  ? const SizedBox.shrink()
                  : Row(key: const ValueKey('selection'), mainAxisSize: MainAxisSize.min, children: [
                      ToolbarButton(
                        icon: AppIcon.trimStart.of(context),
                        tooltip: keyed(context, KeyCommand.trimStart, (key) => 'Start at the playhead ({key})'.fill({'key': key}),
                            'Start at the playhead'.tr),
                        onPressed: () => c.lanes.trimToPlayhead(start: true),
                      ),
                      ToolbarButton(
                        icon: AppIcon.trimEnd.of(context),
                        tooltip: keyed(context, KeyCommand.trimEnd, (key) => 'End at the playhead ({key})'.fill({'key': key}),
                            'End at the playhead'.tr),
                        onPressed: () => c.lanes.trimToPlayhead(start: false),
                      ),
                      ToolbarButton(icon: AppIcon.delete.of(context), tooltip: 'Remove (Delete)'.tr, onPressed: c.commands.delete),
                      const ToolbarDivider(),
                      _TransitionMenu(controller: c),
                      if (c.lanes.selectedStaffCount > 1) _StavesMenu(controller: c),
                      const ToolbarDivider(),
                    ]),
            ),
            _TidyMenu(controller: c, lanes: lanes.length),
            ToolbarButton(
              icon: AppIcon.autoCurate.of(context),
              tooltip: 'Auto-curate'.tr,
              onPressed: c.canAutoCurate ? c.lanes.autoCurate : null,
            ),
            ToolbarButton(
              icon: AppIcon.clearLanes.of(context),
              tooltip: 'Clear all lanes'.tr,
              onPressed: c.lanes.clear,
            ),
          ],
        );
      },
    );
  }

  /// What is selected; nothing when nothing is (the tools explain themselves on hover).
  static String? _status(EditorController c, LoadedScore score, Map<RegionRef, RegionEdges> selected, Set<String> lanes) {
    if (selected.length == 1) {
      final MapEntry(key: ref, value: edges) = selected.entries.single;
      final part = c.laneRowOf(ref.partId);
      final (from, to) = (c.beats.format(ref.region.start), c.beats.format(ref.region.end));
      return '${c.laneName(part)} · ${switch (edges) {
        RegionEdges.both => '$from → $to',
        RegionEdges.start => 'start ({at})'.fill({'at': from}),
        RegionEdges.end => 'end ({at})'.fill({'at': to}),
      }}';
    }
    if (selected.isNotEmpty) {
      final whole = selected.values.where((e) => e == RegionEdges.both).length, edges = selected.length - whole;
      final what = [
        if (whole > 0) (whole == 1 ? '1 region' : '{n} regions').fill({'n': whole}),
        if (edges > 0) (edges == 1 ? '1 edge' : '{n} edges').fill({'n': edges}),
      ].join(', '.tr);
      final where = (lanes.length == 1 ? '{what} in 1 lane' : '{what} in {n} lanes').fill({'what': what, 'n': lanes.length});
      return '$where · ${shortcut('←/→ a bar (⇧ a beat)'.tr)}';
    }
    if (lanes.length == 1) return c.laneName(c.laneRowOf(lanes.single));
    if (lanes.isNotEmpty) return '{n} lanes'.fill({'n': lanes.length});
    return null;
  }
}

/// Clean-up that acts on the selected lanes (or all of them).
class _TidyMenu extends StatelessWidget {
  const _TidyMenu({required this.controller, required this.lanes});
  final EditorController controller;
  final int lanes;

  @override
  Widget build(BuildContext context) {
    String bars(double n) => (n == 1 ? '1 Bar' : '{n} Bars').fill({'n': n.toStringAsFixed(0)});
    // Its tooltip is an overlay: a semantics node of its own (see OverlaySemantics).
    return OverlaySemantics(
      child: AppPopupMenuButton<void Function()>(
        tooltip: switch (lanes) { 0 => 'Tidy all lanes'.tr, 1 => 'Tidy 1 selected lane'.tr, _ => 'Tidy {n} selected lanes'.fill({'n': lanes}) },
        iconSize: 18,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 280),
        style: IconButton.styleFrom(
          fixedSize: const Size(32, 32),
          minimumSize: const Size(32, 32),
          shape: RoundedRectangleBorder(borderRadius: AppStyle.of(context).radius(8)),
        ),
        icon: Icon(AppIcon.tidy.of(context)),
        onSelected: (action) => action(),
        itemBuilder: (context) => [
          menuHeader(context, switch (lanes) { 0 => 'Tidy All Lanes'.tr, 1 => 'Tidy 1 Selected Lane'.tr, _ => 'Tidy {n} Selected Lanes'.fill({'n': lanes}) }),
          for (final n in const [1.0, 2.0, 4.0])
            menuItem(
              context,
              value: () => controller.lanes.fillGaps(n),
              child: Text('Bridge Rests Up to {bars}'.fill({'bars': bars(n)})),
            ),
          menuDivider(context),
          for (final n in const [1.0, 2.0])
            menuItem(
              context,
              value: () => controller.lanes.removeShort(n),
              child: Text('Remove Regions Shorter Than {bars}'.fill({'bars': bars(n)})),
            ),
        ],
      ),
    );
  }
}

/// Which staves of their instruments the selected regions show: "≡ Staff 1 ▾", each staff
/// checked or not (a region keeps one at least).
class _StavesMenu extends StatelessWidget {
  const _StavesMenu({required this.controller});
  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final shown = controller.lanes.selectedStavesShown;
    final only = [for (final (i, s) in shown.indexed) if (s == true) i + 1];
    final label = switch (shown) {
      _ when shown.every((s) => s == true) => 'All'.tr,
      _ when shown.contains(null) => 'Mixed'.tr,
      _ => only.length == 1 ? 'Staff {n}'.fill({'n': only.single}) : only.join(', '),
    };
    return OverlaySemantics(
      child: AppPopupMenuButton<int>(
        tooltip: 'Staves'.tr,
        position: PopupMenuPosition.under,
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.only(left: 6, right: 2),
          shape: RoundedRectangleBorder(borderRadius: AppStyle.of(context).radius(8)),
        ),
        onSelected: (n) => controller.lanes.setStaffShown(n, shown[n - 1] != true),
        itemBuilder: (context) => [
          for (final (i, s) in shown.indexed)
            checkedMenuItem(context,
                value: i + 1,
                checked: s == true,
                // The last one shown stays.
                enabled: s != true || only.length > 1 || shown.contains(null),
                child: Text('Staff {n}'.fill({'n': i + 1}))),
        ],
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(AppIcon.lanes.of(context), size: 16, color: colors.textMuted),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(fontSize: 12.5, color: only.length < shown.length ? colors.text : colors.textMuted)),
          Icon(AppIcon.dropDown.of(context), size: 18, color: colors.textMuted),
        ]),
      ),
    );
  }
}

/// How long the staves glide at the selected edges (both of a whole region): "0.8 s ▾",
/// their own or the project's (dimmed), for all of them at once.
class _TransitionMenu extends StatelessWidget {
  const _TransitionMenu({required this.controller});
  final EditorController controller;

  /// The project's transition in the menu (a menu's null means it was dismissed).
  static const _project = -1.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final project = controller.curation!.transition;
    final values = controller.lanes.selectedTransitions;
    final value = values.length == 1 ? values.single : _project;
    final (label, tip) = switch (values.length) {
      1 when values.single == null => ('{n} s'.fill({'n': project}), "Transition (the project's)".tr),
      1 => ('{n} s'.fill({'n': values.single}), 'Transition (their own)'.tr),
      _ => ('Mixed'.tr, 'Transition (mixed)'.tr),
    };
    return OverlaySemantics(
      child: AppPopupMenuButton<double>(
        tooltip: tip,
        position: PopupMenuPosition.under,
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.only(left: 6, right: 2),
          shape: RoundedRectangleBorder(borderRadius: AppStyle.of(context).radius(8)),
        ),
        onSelected: (s) => controller.lanes.setTransition(s == _project ? null : s),
        itemBuilder: (context) => [
          checkedMenuItem(context,
              value: _project, checked: values.length == 1 && value == null, child: Text("Project's ({n} s)".fill({'n': project}))),
          menuDivider(context),
          for (final s in {...AppSettings.transitionChoices, for (final v in values) ?v}.toList()..sort())
            checkedMenuItem(context, value: s, checked: values.length == 1 && value == s, child: Text('{n} s'.fill({'n': s}))),
        ],
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(AppIcon.transition.of(context), size: 16, color: colors.textMuted),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(
                  fontSize: 12.5,
                  color: values.length == 1 && value != null ? colors.text : colors.textMuted,
                  fontFeatures: const [FontFeature.tabularFigures()])),
          Icon(AppIcon.dropDown.of(context), size: 18, color: colors.textMuted),
        ]),
      ),
    );
  }
}
