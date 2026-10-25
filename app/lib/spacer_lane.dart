import 'package:flutter/material.dart';
import 'package:score_engine/score_engine.dart' show ScoreTimeline;

import 'app_colors.dart';
import 'app_icons.dart';
import 'editor_controller.dart';
import 'lanes_common.dart';
import 'spacer_dialogs.dart';
import 'span_lane.dart';
import 'ui_kit.dart';

/// The Spacers lane (Attach Image): a [SpanLane] whose stretches are the horizontal spacers,
/// each engraved again once a drag ends. Its name's buttons add a vertical spacer (below the
/// lowest lane selected, else at the bottom: a lane of its own in the Instruments tab), add a
/// horizontal one over the beat the playhead is in, and remove the spacer selected (or the
/// spacers' lanes selected). Double-click a horizontal one for how much wider it makes its
/// stretch.
class SpacerLane extends StatelessWidget {
  const SpacerLane({super.key, required this.controller});
  final EditorController controller;

  static const height = SpanLane.height;

  EditorController get c => controller;
  ScoreTimeline get tl => c.timeline;

  /// A vertical spacer below the lowest lane selected, else at the bottom.
  void _addVertical() {
    final selected = c.lanes.selectedPartIds;
    final below = c.laneParts.where((p) => selected.contains(p.id)).lastOrNull;
    c.spacers.addVertical(below: below?.id);
  }

  /// A horizontal spacer over the beat the playhead is in.
  void _addHorizontal() {
    final seconds = c.playback.time.value;
    final q = tl.quarterAtSeconds(seconds).clamp(0.0, tl.measureStarts.last - 1e-6);
    final beat = beatInLanes(c, q, pass: tl.passAt(seconds));
    c.spacers.addHorizontal(beat.start, beat.end);
  }

  /// The spacers' lanes selected, when no spacer is.
  List<String> get _selectedLanes => [for (final id in c.lanes.selectedPartIds) if (c.spacers.verticalOf(id) != null) id];

  void _remove() {
    if (c.spacers.hasSelection) {
      c.spacers.removeSelected();
    } else {
      c.spacers.removeVerticals(_selectedLanes);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SpanLane(
      controller: c,
      model: _HorizontalSpacers(c, context),
      header: ListenableBuilder(
        listenable: c,
        builder: (context, _) => LaneLabel(
          height: height,
          color: colors.accentWash,
          trailing: Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _LaneButton(icon: AppIcon.verticalSpacer, tooltip: 'Add Vertical Spacer', onPressed: _addVertical),
              _LaneButton(icon: AppIcon.horizontalSpacer, tooltip: 'Add Horizontal Spacer', onPressed: _addHorizontal),
              _LaneButton(
                icon: AppIcon.delete,
                tooltip: 'Remove Spacer',
                onPressed: c.spacers.hasSelection || _selectedLanes.isNotEmpty ? _remove : null,
              ),
            ]),
          ),
          child: const Text('Spacers', style: TextStyle(fontWeight: FontWeight.w500)),
        ),
      ),
    );
  }
}

class _HorizontalSpacers implements SpanLaneModel {
  _HorizontalSpacers(this.c, this.context);
  final EditorController c;
  final BuildContext context;

  @override
  List<Span> get spans => [for (final (i, _) in c.spacers.horizontal.indexed) (start: c.spacers.startOf(i), end: c.spacers.endOf(i))];

  @override
  int? get selected => c.spacers.selectedHorizontal;

  @override
  void select(int? index) => c.spacers.selectHorizontal(index);

  @override
  bool get live => false; // each change engraves the score again

  @override
  void update(int index, double start, double end) => c.spacers.setHorizontalSpan(index, start, end);

  @override
  void begin() {} // nothing changes until a drag ends

  @override
  void replaceAll(List<({int from, double start, double end})> pieces) => c.spacers.replaceHorizontal(pieces);

  @override
  void drawn(double start, double end) => c.spacers.addHorizontal(start, end);

  @override
  void open(int index) => showHorizontalSpacerDialog(context, c, index);

  @override
  String? label(int index) => '+${spacerNumber(c.spacers.horizontal[index].width)} sp';

  @override
  InlineSpan labelSpan(String label, TextStyle style) => TextSpan(text: label, style: style);
}

/// A small button in a lane's name.
class _LaneButton extends StatelessWidget {
  const _LaneButton({required this.icon, required this.tooltip, required this.onPressed});
  final AppIcon icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => OverlaySemantics(
        child: IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          iconSize: 14,
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 22, height: 22),
          color: context.colors.textMuted,
          style: IconButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: AppStyle.of(context).radius(5))),
          icon: Icon(icon.of(context)),
        ),
      );
}
