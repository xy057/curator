// The Edit menu and the keys act through EditCommands: each acts on the tab showing, and the
// menu's items are enabled by the same checks the commands make.
import 'package:curated_score/editor_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('with nothing open there is nothing to copy, paste, delete or select', () {
    final c = EditorController(vsync: const TestVSync());
    addTearDown(c.dispose);
    final k = c.commands;
    expect((k.canCopy, k.canPaste, k.canDelete, k.canSelectAll), (false, false, false, false));
    k.delete(); // nothing happens
  });

  test('copy, paste and delete act on the tab showing', () async {
    final c = EditorController(vsync: const TestVSync());
    addTearDown(c.dispose);
    await c.openFile(demoScore.path);
    final k = c.commands, id = c.laneParts.first.id;
    final bars = c.timeline.measureStarts;
    c.curation!.setLane(id, [Region(bars[1], bars[3])]);
    expect(k.canCopy, isFalse, reason: 'nothing selected');
    c.lanes.selectLane(id);
    expect((k.canCopy, k.canDelete), (true, true));

    c.tab = BottomTab.audio; // the anchors' tab: the regions stay selected but aren't acted on
    expect((k.canCopy, k.canDelete), (false, false));
    k.copy();
    expect(c.lanes.canPaste, isFalse);

    c.tab = BottomTab.instruments;
    k.copy();
    expect((k.pastesRegions, k.pastesImage, k.canPaste), (true, false, true));
    c.images.enabled = true;
    expect(k.pastesImage, isFalse, reason: 'copied regions paste first in the Instruments tab');
    c.tab = BottomTab.audio;
    expect((k.pastesRegions, k.pastesImage), (false, true));

    c.tab = BottomTab.instruments;
    k.delete();
    expect(c.curation!.lane(id), isEmpty);
  });
}
