import 'package:flutter/material.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'captions_dialog.dart';
import 'edit_dialogs.dart';
import 'editor_controller.dart';
import 'lanes_common.dart';
import 'span_lane.dart';
import 'ui_kit.dart';

/// The Captions lane (the Captions extension): a [SpanLane] whose stretches are the captions,
/// changed as they are dragged. Drawing one asks for its text; double-click one for its text
/// and bars, or the lane's name for the Captions sheet.
class CaptionLane extends StatefulWidget {
  const CaptionLane({super.key, required this.controller});
  final EditorController controller;

  static const height = SpanLane.height;

  @override
  State<CaptionLane> createState() => _CaptionLaneState();
}

class _CaptionLaneState extends State<CaptionLane> {
  EditorController get controller => widget.controller;
  final _nameClicks = DoubleClicks();

  /// Kept: it holds the captions as an erase found them.
  late final _model = _Captions(controller, context);

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SpanLane(
      controller: controller,
      model: _model,
      header: Listener(
        onPointerUp: (e) {
          if (_nameClicks.press(e.timeStamp, e.position)) showCaptionsDialog(context, controller);
        },
        child: LaneLabel(
          height: CaptionLane.height,
          color: colors.accentWash,
          trailing: Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Tip(message: 'Pinned', child: Icon(AppIcon.pin.of(context), size: 13, color: colors.textMuted)),
          ),
          child: const Text('Captions', style: TextStyle(fontWeight: FontWeight.w500)),
        ),
      ),
    );
  }
}

class _Captions implements SpanLaneModel {
  _Captions(this.c, this.context);
  final EditorController c;
  final BuildContext context;

  List<Caption> get _captions => c.captions.captions;

  /// The captions as a drag found them: erasing changes them as it goes, its pieces are of these.
  List<Caption> _before = const [];

  @override
  List<Span> get spans => [for (final cap in _captions) (start: cap.start, end: cap.end)];

  @override
  int? get selected => c.captions.selected;

  @override
  void select(int? index) => c.captions.select(index);

  @override
  bool get live => true;

  @override
  void update(int index, double start, double end) =>
      c.captions.update(index, _captions[index].copyWith(start: start, end: end));

  @override
  void begin() => _before = _captions;

  @override
  void replaceAll(List<({int from, double start, double end})> pieces) => c.captions.replaceAll([
        for (final p in pieces)
          if (p.from >= 0 && p.from < _before.length) _before[p.from].copyWith(start: p.start, end: p.end),
      ]);

  @override
  void drawn(double start, double end) => showCaptionDialog(context, c, draft: Caption(start, end, ''));

  @override
  void open(int index) => showCaptionDialog(context, c, index: index);

  @override
  String? label(int index) => _captions[index].text;

  @override
  InlineSpan labelSpan(String label, TextStyle style) => TextSpan(style: style, children: [
        for (final run in captionRuns(label))
          TextSpan(
            text: run.text,
            style: TextStyle(fontStyle: run.italic ? FontStyle.italic : null, fontWeight: run.bold ? FontWeight.bold : null),
          ),
      ]);
}
