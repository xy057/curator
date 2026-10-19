import 'package:flutter/material.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'app_settings.dart';
import 'editor_controller.dart';
import 'menu_kit.dart';
import 'ui_kit.dart';

/// Instruments tab tools (right of the tab switch). Every button explains itself on hover.
class InstrumentsToolbar extends StatelessWidget {
  const InstrumentsToolbar({super.key, required this.controller});
  final EditorController controller;

  /// Each tool's icon and hover text: its name, then what each key changes.
  static Map<LaneTool, (AppIcon, String)> get _tools => {
        LaneTool.select: (AppIcon.pointer, 'Select (V)\n${shortcut('⇧ add · ⌘ toggle, no snap · ⌥ draw')}'),
        LaneTool.draw: (AppIcon.draw, 'Draw (D)\n${shortcut('⌘ no snap · ⌥ erase')}'),
        LaneTool.erase: (AppIcon.erase, 'Erase (E)\n${shortcut('⌘ no snap · ⌥ draw')}'),
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
              for (final MapEntry(key: tool, value: (icon, tip)) in _tools.entries)
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
                        tooltip: 'Start at the playhead ([)',
                        onPressed: () => c.lanes.trimToPlayhead(start: true),
                      ),
                      ToolbarButton(
                        icon: AppIcon.trimEnd.of(context),
                        tooltip: 'End at the playhead (])',
                        onPressed: () => c.lanes.trimToPlayhead(start: false),
                      ),
                      ToolbarButton(icon: AppIcon.delete.of(context), tooltip: 'Remove (Delete)', onPressed: c.commands.delete),
                      const ToolbarDivider(),
                      _TransitionMenu(controller: c),
                      const ToolbarDivider(),
                    ]),
            ),
            _TidyMenu(controller: c, lanes: lanes.length),
            ToolbarButton(
              icon: AppIcon.autoCurate.of(context),
              tooltip: 'Auto-curate',
              onPressed: c.lanes.autoCurate,
            ),
            ToolbarButton(
              icon: AppIcon.clearLanes.of(context),
              tooltip: 'Clear all lanes',
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
      final part = score.metadata.parts.firstWhere((p) => p.id == ref.partId);
      final (from, to) = (c.beats.format(ref.region.start), c.beats.format(ref.region.end));
      return '${c.laneName(part)} · ${switch (edges) {
        RegionEdges.both => '$from → $to',
        RegionEdges.start => 'start ($from)',
        RegionEdges.end => 'end ($to)',
      }}';
    }
    if (selected.isNotEmpty) {
      final whole = selected.values.where((e) => e == RegionEdges.both).length, edges = selected.length - whole;
      final what = [if (whole > 0) '$whole ${whole == 1 ? 'region' : 'regions'}', if (edges > 0) '$edges ${edges == 1 ? 'edge' : 'edges'}'];
      return '${what.join(', ')} in ${lanes.length} ${lanes.length == 1 ? 'lane' : 'lanes'} · ${shortcut('←/→ a bar (⇧ a beat)')}';
    }
    if (lanes.length == 1) return c.laneName(score.metadata.parts.firstWhere((p) => p.id == lanes.single));
    if (lanes.isNotEmpty) return '${lanes.length} lanes';
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
    final where = lanes == 0 ? 'all lanes' : '$lanes selected ${lanes == 1 ? 'lane' : 'lanes'}';
    String bars(double n) => n == 1 ? '1 Bar' : '${n.toStringAsFixed(0)} Bars';
    // Its tooltip is an overlay: a semantics node of its own (see OverlaySemantics).
    return OverlaySemantics(
      child: AppPopupMenuButton<void Function()>(
        tooltip: 'Tidy $where',
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
          menuHeader(context, lanes == 0 ? 'Tidy All Lanes' : 'Tidy $lanes Selected ${lanes == 1 ? 'Lane' : 'Lanes'}'),
          for (final n in const [1.0, 2.0, 4.0])
            menuItem(
              context,
              value: () => controller.lanes.fillGaps(n),
              child: Text('Bridge Rests Up to ${bars(n)}'),
            ),
          menuDivider(context),
          for (final n in const [1.0, 2.0])
            menuItem(
              context,
              value: () => controller.lanes.removeShort(n),
              child: Text('Remove Regions Shorter Than ${bars(n)}'),
            ),
        ],
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
      1 when values.single == null => ('$project s', "the project's"),
      1 => ('${values.single} s', 'their own'),
      _ => ('Mixed', 'mixed'),
    };
    return OverlaySemantics(
      child: AppPopupMenuButton<double>(
        tooltip: 'Transition ($tip)',
        position: PopupMenuPosition.under,
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.only(left: 6, right: 2),
          shape: RoundedRectangleBorder(borderRadius: AppStyle.of(context).radius(8)),
        ),
        onSelected: (s) => controller.lanes.setTransition(s == _project ? null : s),
        itemBuilder: (context) => [
          checkedMenuItem(context,
              value: _project, checked: values.length == 1 && value == null, child: Text("Project's ($project s)")),
          menuDivider(context),
          for (final s in {...AppSettings.transitionChoices, for (final v in values) ?v}.toList()..sort())
            checkedMenuItem(context, value: s, checked: values.length == 1 && value == s, child: Text('$s s')),
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
