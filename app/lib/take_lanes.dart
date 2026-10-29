import 'dart:async';

import 'package:flutter/material.dart';
import 'package:score_engine/score_engine.dart' show Region;

import 'app_colors.dart';
import 'app_icons.dart';
import 'audio_panel.dart' show pickAudio;
import 'edit_dialogs.dart';
import 'editor_controller.dart';
import 'lanes_common.dart';
import 'menu_kit.dart';
import 'project_state.dart';
import 'span_lane.dart';
import 'ui_kit.dart';
import 'l10n/l10n.dart';

/// The recordings' lanes at the top of the Audio tab, one per take: its regions say where it is
/// heard, one at a time, faded into the next at their edges. Edited as the instruments' are,
/// with the lanes' tools (a region drawn on one takes that stretch from the others; one erased
/// leaves silence). Each name has Solo (S: that recording alone, in its own time, its sync
/// edited below) and a menu (Rename…, Replace Recording…, Remove).
class TakeLanes extends StatelessWidget {
  const TakeLanes({super.key, required this.controller});
  final EditorController controller;

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
        for (final t in controller.takes)
          SpanLane(
            key: ValueKey(t.id),
            controller: controller,
            model: _TakeRegions(controller, t.id),
            tools: true,
            header: _TakeHeader(controller: controller, take: t),
          ),
      ]);
}

class _TakeHeader extends StatelessWidget {
  const _TakeHeader({required this.controller, required this.take});
  final EditorController controller;
  final Take take;

  static const _rename = 'rename', _replace = 'replace', _remove = 'remove';

  Future<void> _chosen(BuildContext context, String value) async {
    final c = controller;
    switch (value) {
      case _rename:
        final name = await showRenameRecordingDialog(context, take.label);
        if (name != null) c.renameTake(take.id, name);
      case _replace:
        if (c.focus != take.id) c.solo(take.id); // the focus's recording is the one replaced
        if (context.mounted) await pickAudio(context, c);
      case _remove:
        await c.removeTake(take.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = controller, colors = context.colors;
    final soloed = c.soloed == take.id;
    return LaneLabel(
      height: SpanLane.height,
      color: colors.accentWash,
      trailing: Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (c.takes.length > 1)
            Tip(
              message: soloed ? 'Solo (on): edit its sync below'.tr : 'Solo'.tr,
              child: InkWell(
                borderRadius: AppStyle.of(context).radius(5),
                onTap: () => c.solo(take.id),
                child: Container(
                  width: 22,
                  height: 20,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: soloed ? colors.accent : Colors.transparent,
                    borderRadius: AppStyle.of(context).radius(5),
                  ),
                  child: Text('S',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: soloed ? colors.surface : colors.textMuted)),
                ),
              ),
            ),
          OverlaySemantics(
            child: AppPopupMenuButton<String>(
              tooltip: 'Recording'.tr,
              padding: EdgeInsets.zero,
              iconSize: 14,
              constraints: const BoxConstraints(),
              icon: Icon(AppIcon.more.of(context), size: 14, color: colors.textMuted),
              onSelected: (value) => unawaited(_chosen(context, value)),
              itemBuilder: (context) => [
                menuItem(context, value: _rename, child: Text('Rename…'.tr)),
                menuItem(context, value: _replace, enabled: !c.isLoadingAudio, child: Text('Replace Recording…'.tr)),
                menuItem(context, value: _remove, enabled: !c.isLoadingAudio, child: Text('Remove'.tr)),
              ],
            ),
          ),
        ]),
      ),
      child: Text(take.label, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
    );
  }
}

/// A take's lane as a [SpanLane] edits it: each change once a drag ends (it carves the other
/// lanes, and restarts the sound).
class _TakeRegions implements SpanLaneModel {
  _TakeRegions(this.c, this.id);
  final EditorController c;
  final String id;

  List<Region> get _regions => c.takes.where((t) => t.id == id).firstOrNull?.regions ?? const [];

  /// The regions as they were when a drag began.
  List<Region> _before = const [];

  @override
  List<Span> get spans => [for (final r in _regions) (start: r.start, end: r.end)];

  @override
  int? get selected => c.takeSelection?.take == id ? c.takeSelection!.index : null;

  @override
  void select(int? index) => c.selectTakeRegion(id, index);

  @override
  bool get live => false;

  @override
  void update(int index, double start, double end) {
    final regions = [..._regions];
    regions[index] = regions[index].withBounds(start, end);
    c.setTakeRegions(id, regions);
    c.selectTakeRegion(id, null);
  }

  @override
  void begin() => _before = _regions;

  @override
  void replaceAll(List<({int from, double start, double end})> pieces) =>
      c.setTakeRegions(id, [for (final p in pieces) _before[p.from].withBounds(p.start, p.end)]);

  @override
  void drawn(double start, double end) => c.setTakeRegions(id, [..._regions, Region(start, end)]);

  @override
  void open(int index) {}

  @override
  String? label(int index) => null;

  @override
  InlineSpan labelSpan(String label, TextStyle style) => TextSpan(text: label, style: style);
}
