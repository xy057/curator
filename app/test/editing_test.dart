
import 'package:curated_score/editor_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late EditorController c;

  setUp(() async {
    c = EditorController(vsync: const TestVSync());
    await c.openFile(demoScore.path);
  });

  tearDown(() => c.dispose());

  group('instrument lane tools', () {
    late List<String> ids;
    late List<double> bars;
    setUp(() {
      ids = [for (final p in c.score!.metadata.parts) p.id];
      bars = c.timeline.measureStarts;
      c.curation!.clearAll();
    });

    test('copied regions paste at the playhead, into their lanes or the lanes selected, as far apart', () {
      final a = Region(bars[4], bars[6], transitionIn: 1.2), b = Region(bars[5], bars[8]);
      c.curation!.setLane(ids[0], [a]);
      c.curation!.setLane(ids[2], [b]);
      c.lanes.select(ids[0], a, edges: RegionEdges.end);
      c.lanes.select(ids[2], b, add: true);
      final revision = c.editRevision.value;
      c.lanes.copy();
      expect(c.lanes.canPaste, isTrue);
      expect(c.editRevision.value, revision, reason: 'copying is not an edit');

      // Into the same lanes, from the beat nearest the playhead; the copies are selected.
      c.clearSelection();
      c.playback.seek(c.timeline.secondsAtQuarter(bars[20] + 0.1));
      c.lanes.paste();
      expect(c.curation!.lane(ids[0]), [a, Region(bars[20], bars[22], transitionIn: 1.2)], reason: 'whole, whatever edge was selected');
      expect(c.curation!.lane(ids[2]), [b, Region(bars[21], bars[24])]);
      expect(c.lanes.selected.map((r) => r.region.start), unorderedEquals([bars[20], bars[21]]));
      c.undo();
      expect(c.curation!.lane(ids[0]), [a]);

      // A lane selected by its name takes the top lane; the other keeps its distance below.
      c.lanes.selectLane(ids[5]);
      c.lanes.paste();
      expect(c.curation!.lane(ids[5]), [Region(bars[20], bars[22], transitionIn: 1.2)]);
      expect(c.curation!.lane(ids[7]), [Region(bars[21], bars[24])]);

      // Past the bottom lane is left out; past the end is cut off.
      final shown = [for (final p in c.laneParts) p.id];
      c.lanes.selectLane(shown.last);
      c.playback.seek(c.timeline.secondsAtQuarter(bars[bars.length - 2]));
      c.lanes.paste();
      expect(c.curation!.lane(shown.last), [Region(bars[bars.length - 2], bars.last, transitionIn: 1.2)]);
    });
  });
}
