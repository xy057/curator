import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'edit_dialogs.dart';
import 'editor_controller.dart';
import 'lanes_common.dart';
import 'span_lane.dart';
import 'l10n/l10n.dart';

/// The Tonality lane (the Tonality extension), pinned under the bar ruler in both tabs: a
/// [SpanLane] whose stretches are the key areas, each in its key's colour and named as the band
/// names it, edited as an instrument's regions are: Draw drags across bars (a click, one beat)
/// and asks for the key, Select moves an area or trims an edge, Erase cuts areas back or in
/// two, double-click opens an area's dialog. An area drawn, moved or trimmed over others goes
/// over them, as a region goes over its lane's: what it covers of them is cut back, and given
/// back as the drag goes on. Its name's buttons add a key from the playhead's beat to the next
/// one, find the keys in the score (Find Keys, in place of those there are), and remove the one
/// selected.
class TonalityLane extends StatefulWidget {
  const TonalityLane({super.key, required this.controller});
  final EditorController controller;

  static const height = SpanLane.height;

  @override
  State<TonalityLane> createState() => _TonalityLaneState();
}

class _TonalityLaneState extends State<TonalityLane> {
  EditorController get c => widget.controller;

  /// Kept: it holds the areas as a drag found them.
  late final _model = _KeyAreas(c, context);

  /// A key from the beat the playhead is in to where the next starts, in the key there.
  void _add() {
    final tl = c.timeline, seconds = c.playback.time.value;
    final q = tl.quarterAtSeconds(seconds).clamp(0.0, tl.measureStarts.last - 1e-6);
    final start = beatInLanes(c, q, pass: tl.passAt(seconds)).start;
    showKeyDialog(context, c, draft: KeyArea(start, c.tonality.nextStart(start), c.tonality.keyAt(start)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SpanLane(
      controller: c,
      model: _model,
      header: ListenableBuilder(
        listenable: c,
        builder: (context, _) => LaneLabel(
          height: TonalityLane.height,
          color: colors.accentWash,
          trailing: Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              LaneButton(icon: AppIcon.add, tooltip: 'Add Key'.tr, onPressed: _add),
              LaneButton(icon: AppIcon.search, tooltip: 'Find Keys'.tr, onPressed: c.tonality.canFind ? c.tonality.find : null),
              LaneButton(
                icon: AppIcon.delete,
                tooltip: 'Remove Key'.tr,
                onPressed: c.tonality.selected == null ? null : c.tonality.remove,
              ),
            ]),
          ),
          child: Text('Tonality'.tr, style: TextStyle(fontWeight: FontWeight.w500)),
        ),
      ),
    );
  }
}

class _KeyAreas extends SpanLaneModel {
  _KeyAreas(this.c, this.context);
  final EditorController c;
  final BuildContext context;

  List<KeyArea> get _areas => c.tonality.areas;

  /// The areas as a drag found them: a move goes over these, an erase's pieces are of these.
  List<KeyArea> _before = const [];

  @override
  List<Span> get spans => [for (final a in _areas) (start: a.start, end: a.end)];

  @override
  int? get selected => c.tonality.selected;

  @override
  void select(int? index) => c.tonality.select(index);

  @override
  bool get live => true;

  @override
  bool get paints => true;

  @override
  void update(int index, double start, double end) {
    if (index < _before.length) c.tonality.reshape(index, _before[index].copyWith(start: start, end: end), from: _before);
  }

  @override
  void begin() => _before = _areas;

  @override
  void replaceAll(List<({int from, double start, double end})> pieces) => c.tonality.replaceAll(_before, pieces);

  @override
  void drawn(double start, double end) => showKeyDialog(context, c, draft: KeyArea(start, end, c.tonality.keyAt(start)));

  @override
  void open(int index) => showKeyDialog(context, c, index: index);

  @override
  String? label(int index) => TonalityEditing.labelOf(_areas[index]);

  @override
  InlineSpan labelSpan(String label, TextStyle style) => TextSpan(text: label, style: style);

  @override
  Color? color(int index) => _areas[index].key.color;
}
