import 'dart:convert';
import 'dart:ui' as ui;

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

  test('renaming an instrument reaches the name column; empty resets it', () {
    final clarinet = c.score!.metadata.parts.firstWhere((p) => p.name == 'Clarinet in B♭ 1');
    c.curation!.setLane(clarinet.id, [const Region(0, 1000)]); // make sure it is on screen
    c.renamePart(clarinet, name: 'Solo Clarinet', abbreviation: 'Solo Cl.');
    expect(c.partName(clarinet), 'Solo Clarinet');
    final labels = c.scene!.layoutAt(30, c.curation!, const ui.Size(1600, 2400)).labels;
    expect(labels.map((l) => l.text), contains('Solo Clarinet'));

    c.renamePart(clarinet, name: '', abbreviation: '');
    expect(c.partName(clarinet), 'Clarinet in B♭ 1');
  });

  test('editing a text re-engraves it and keeps curation and sync', () async {
    final curation = c.curation, sync = c.sync;
    final vivo = c.score!.texts.firstWhere((t) => t.text == 'Vivo');
    await c.editText(vivo.id, 'Vivo assai');

    String engraved() => utf8.decode(c.score!.engraving.text, allowMalformed: true);
    expect(engraved(), contains('Vivo assai'));
    expect(c.textById(vivo.id)!.current, 'Vivo assai');
    expect(identical(c.curation, curation) && identical(c.sync, sync), isTrue);

    // Several at once (the Texts list), including a removal; null restores the original.
    final arco = c.score!.texts.where((t) => t.text == 'arco').take(2).toList();
    await c.editTexts({arco[0].id: '', arco[1].id: 'arco (div.)', vivo.id: null});
    expect(c.textById(arco[0].id)!.current, '');
    expect(engraved(), contains('arco (div.)'));
    expect(c.textById(vivo.id)!.current, 'Vivo');
  });

  test('new engraving options re-engrave what is open, and are not an edit', () async {
    final curation = c.curation, sync = c.sync;
    final width = c.score!.engraving.width;
    final revision = c.editRevision.value;
    final spacing = EngraveOption.byKey('spacingLinear')!;
    c.engravingOptions = const EngravingOptions().withValue(spacing, 0.9);
    expect(c.isReengraving, isTrue);
    while (c.isReengraving) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(c.score!.options.valueOf(spacing), 0.9);
    expect(c.score!.engraving.width, greaterThan(width));
    expect(identical(c.curation, curation) && identical(c.sync, sync), isTrue);
    expect(c.editRevision.value, revision, reason: 'a setting, not part of the project');

    // A text edit keeps them.
    final vivo = c.score!.texts.firstWhere((t) => t.text == 'Vivo');
    await c.editText(vivo.id, 'Vivo assai');
    expect(c.score!.options.valueOf(spacing), 0.9);
  });

  test('resizing the score keeps its engraving, and a slider drag is one change', () {
    final display = c.scene!.display;
    final revision = c.editRevision.value;
    for (final size in [8.0, 7.0, 6.0]) {
      c.setStaffSpace(size, dragging: true);
    }
    expect(c.scene!.renderer.scale, closeTo(6 / c.score!.engraving.staffSpace, 1e-9));
    expect(c.editRevision.value, revision, reason: 'not an edit until the drag ends');
    c.setStaffSpace(6);
    expect(c.editRevision.value, revision + 1);
    expect(identical(c.scene!.display, display), isTrue, reason: 'nothing re-engraved or rebuilt');
  });

  group('instrument lane tools', () {
    late List<String> ids;
    late List<double> bars;
    setUp(() {
      ids = [for (final p in c.score!.metadata.parts) p.id];
      bars = c.timeline.measureStarts;
      c.curation!.clearAll();
    });

    test('positions read and write as bar.beat', () {
      // 6/8: two dotted-crotchet beats a bar.
      expect(c.beats.format(bars[11]), '12.1');
      expect(c.beats.format(bars[11] + 1.5), '12.2');
      expect(c.beats.format(bars[11] + 0.75), '12.1.50');
      expect(c.beats.parse('12'), bars[11]);
      expect(c.beats.parse('12.2'), bars[11] + 1.5);
      expect(c.beats.parse('12.1.50'), bars[11] + 0.75);
      expect(c.beats.parse('12.3'), isNull); // no third beat in 6/8
      expect(c.beats.parse('${bars.length}'), bars.last); // the end of the piece
      expect(c.beats.parse('0'), isNull);
      expect(c.beats.parse('12.99'), isNull); // no such beat
      expect(c.beats.parse('twelve'), isNull);
    });

    test('a selection across lanes moves, trims and deletes together', () {
      final a = Region(bars[4], bars[8]), b = Region(bars[6], bars[10]);
      c.curation!.setLane(ids[0], [a]);
      c.curation!.setLane(ids[1], [b]);
      c.lanes.select(ids[0], a);
      c.lanes.select(ids[1], b, add: true);
      expect(c.lanes.selectedPartIds, {ids[0], ids[1]});

      c.lanes.nudge(1); // a bar later
      expect(c.curation!.lane(ids[0]), [Region(bars[5], bars[9])]);
      expect(c.curation!.lane(ids[1]), [Region(bars[7], bars[11])]);
      expect(c.lanes.selected, hasLength(2)); // still selected after the edit

      c.playback.seek(c.timeline.secondsAtQuarter(bars[8] + 0.1)); // just after bar 9 starts
      c.lanes.trimToPlayhead(start: false);
      expect(c.curation!.lane(ids[0]), [Region(bars[5], bars[8])]);
      expect(c.curation!.lane(ids[1]), [Region(bars[7], bars[8])]);

      c.undo();
      expect(c.curation!.lane(ids[0]), [Region(bars[5], bars[9])]);
      c.lanes.selectAll();
      c.deleteSelection();
      expect(c.curation!.lane(ids[0]), isEmpty);
      expect(c.curation!.lane(ids[1]), isEmpty);
    });

    test('tidying acts on the selected lanes, or all of them', () {
      final lane = [Region(bars[0], bars[2]), Region(bars[3], bars[5])]; // a one-bar rest
      c.curation!.setLane(ids[0], lane);
      c.curation!.setLane(ids[1], lane);
      c.lanes.selectLane(ids[0]);
      c.lanes.fillGaps(1);
      expect(c.curation!.lane(ids[0]), [Region(bars[0], bars[5])]);
      expect(c.curation!.lane(ids[1]), lane);
      expect(c.lanes.selected.single.region, Region(bars[0], bars[5]));

      c.clearSelection();
      c.lanes.removeShort(3);
      expect(c.curation!.lane(ids[0]), [Region(bars[0], bars[5])]);
      expect(c.curation!.lane(ids[1]), isEmpty);
    });

    test('a region can have a transition of its own, kept through edits and undone like one', () {
      final r = Region(bars[4], bars[8]);
      c.curation!.setLane(ids[2], [r]);
      c.lanes.setRegion((partId: ids[2], region: r), r.withTransition(1.2));
      expect(c.curation!.lane(ids[2]), [Region(bars[4], bars[8], transition: 1.2)]);
      expect(c.lanes.selected.single.region.transition, 1.2);

      c.lanes.nudge(1);
      expect(c.curation!.lane(ids[2]), [Region(bars[5], bars[9], transition: 1.2)], reason: 'moved with it');
      c.undo();
      c.undo();
      expect(c.curation!.lane(ids[2]), [r], reason: 'back to the project\'s');
    });

    test('a region can be given exact bars', () {
      final r = Region(bars[4], bars[8]);
      c.curation!.setLane(ids[2], [r]);
      c.lanes.setRegion((partId: ids[2], region: r), Region(bars[1], bars[3] + 2));
      expect(c.curation!.lane(ids[2]), [Region(bars[1], bars[3] + 2)]);
      expect(c.lanes.selected.single.region, Region(bars[1], bars[3] + 2));
    });
  });
}
