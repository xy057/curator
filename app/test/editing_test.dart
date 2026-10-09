import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:curated_score/audio_track.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/project_state.dart';
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

  test('a recording that can\'t be read leaves the one loaded, and the project unchanged', () async {
    final loaded = AudioTrack.forTesting(name: 'take 1.flac', length: 60, waveform: await Waveform.analyze(Float32List(64), 64));
    c.audio.debugTrack = loaded;
    final revision = c.editRevision.value;
    final broken = File('${Directory.systemTemp.createTempSync('broken-').path}/take 2.mkv')..writeAsStringSync('not a video');
    addTearDown(() => broken.parent.deleteSync(recursive: true));

    await expectLater(c.loadAudio(broken.path), throwsA(anything));
    expect(c.track, same(loaded), reason: 'what was loaded stays, so a save keeps it');
    expect(c.editRevision.value, revision);
    expect(c.isLoadingAudio, isFalse);
  });

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

  test("the project's engraving options win over the app's, and are an edit Undo steps through", () async {
    Future<void> engraved() async {
      while (c.isReengraving) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    final spacing = EngraveOption.byKey('spacingLinear')!, curve = EngraveOption.byKey('slurCurveFactor')!;
    c.engravingOptions = const EngravingOptions().withValue(spacing, 0.9).withValue(curve, 2);
    await engraved();
    final revision = c.editRevision.value;
    await c.setProjectEngraving(const EngravingOptions().withValue(spacing, 0.7));
    await engraved();
    expect(c.score!.options.valueOf(spacing), 0.7);
    expect(c.score!.options.valueOf(curve), 2, reason: "the app's, where the project sets none");
    expect(c.editRevision.value, greaterThan(revision));
    expect(c.projectState.edits.engraving, c.projectEngraving);

    c.undo();
    await engraved();
    expect(c.projectEngraving.isEmpty, isTrue);
    expect(c.score!.options.valueOf(spacing), 0.9);
    c.redo();
    await engraved();
    expect(c.score!.options.valueOf(spacing), 0.7);

    // The app's change under it shows only where the project sets nothing.
    c.engravingOptions = const EngravingOptions().withValue(spacing, 0.5).withValue(curve, 3);
    await engraved();
    expect(c.score!.options.valueOf(spacing), 0.7);
    expect(c.score!.options.valueOf(curve), 3);
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

    test('a region can be selected by one edge: its transition there, and trims at that side, act on it alone', () {
      final a = Region(bars[4], bars[8]), b = Region(bars[6], bars[10]);
      c.curation!.setLane(ids[0], [a]);
      c.curation!.setLane(ids[1], [b]);
      c.lanes.select(ids[0], a, edges: RegionEdges.start);
      c.lanes.select(ids[1], b, add: true, edges: RegionEdges.end);
      expect(c.lanes.selection, {(partId: ids[0], region: a): RegionEdges.start, (partId: ids[1], region: b): RegionEdges.end});
      expect(c.lanes.selectedTransitions, {null});

      c.lanes.setTransition(0.8);
      final a2 = a.withTransition(0.8, atEnd: false), b2 = b.withTransition(0.8, atStart: false);
      expect(c.curation!.lane(ids[0]), [a2]);
      expect(c.curation!.lane(ids[1]), [b2]);
      expect(c.lanes.selection, {(partId: ids[0], region: a2): RegionEdges.start, (partId: ids[1], region: b2): RegionEdges.end},
          reason: 'still selected at the same edges');
      expect(c.lanes.selectedTransitions, {0.8});

      c.playback.seek(c.timeline.secondsAtQuarter(bars[5] + 0.1));
      c.lanes.trimToPlayhead(start: true);
      expect(c.curation!.lane(ids[0]).single.start, bars[5]);
      expect(c.curation!.lane(ids[1]), [b2], reason: 'selected by its end only');

      // ⇧ adds the other edge (the whole region); ⌘ takes one away again.
      final a3 = c.curation!.lane(ids[0]).single;
      c.lanes.select(ids[0], a3, add: true, edges: RegionEdges.end);
      expect(c.lanes.selection[(partId: ids[0], region: a3)], RegionEdges.both);
      c.lanes.select(ids[0], a3, toggle: true, edges: RegionEdges.start);
      expect(c.lanes.selection[(partId: ids[0], region: a3)], RegionEdges.end);
      c.lanes.select(ids[0], a3, toggle: true, edges: RegionEdges.end);
      expect(c.lanes.selected, {(partId: ids[1], region: b2)});
      c.lanes.select(ids[1], b2);
      expect(c.lanes.selection.values.single, RegionEdges.both, reason: 'a plain click: the whole region');
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

    test('a region can have transitions of its own, in and out apart, kept through edits and undone like one', () {
      final r = Region(bars[4], bars[8]);
      c.curation!.setLane(ids[2], [r]);
      c.lanes.setRegion((partId: ids[2], region: r), r.withTransition(1.2, atEnd: false));
      expect(c.curation!.lane(ids[2]), [Region(bars[4], bars[8], transitionIn: 1.2)]);
      expect(c.lanes.selected.single.region.transitionIn, 1.2);
      expect(c.lanes.selected.single.region.transitionOut, isNull, reason: 'its end is still the project\'s');

      c.lanes.nudge(1);
      expect(c.curation!.lane(ids[2]), [Region(bars[5], bars[9], transitionIn: 1.2)], reason: 'moved with it');
      c.undo();
      c.undo();
      expect(c.curation!.lane(ids[2]), [r], reason: 'back to the project\'s');
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

    test('cut removes the regions as one step, and pastes them back where they were', () {
      final a = Region(bars[4], bars[8]);
      c.curation!.setLane(ids[1], [a]);
      c.lanes.select(ids[1], a);
      c.lanes.cut();
      expect(c.curation!.lane(ids[1]), isEmpty);
      expect(c.lanes.selected, isEmpty);
      c.playback.seek(c.timeline.secondsAtQuarter(bars[4]));
      c.lanes.paste();
      expect(c.curation!.lane(ids[1]), [a]);
      c.undo();
      c.undo();
      expect(c.curation!.lane(ids[1]), [a]);
      expect(c.lanes.canPaste, isTrue, reason: 'Undo leaves what was copied');
    });

    test('a region can be given exact bars', () {
      final r = Region(bars[4], bars[8]);
      c.curation!.setLane(ids[2], [r]);
      c.lanes.setRegion((partId: ids[2], region: r), Region(bars[1], bars[3] + 2));
      expect(c.curation!.lane(ids[2]), [Region(bars[1], bars[3] + 2)]);
      expect(c.lanes.selected.single.region, Region(bars[1], bars[3] + 2));
    });
  });

  test('listeners never see a score half open: with a score, its curation, sync and scene are there too', () async {
    final half = <String>[];
    void check() {
      if (c.score != null && (c.curation == null || c.sync == null || c.scene == null)) half.add('${c.fileName}');
    }

    c.addListener(check);
    addTearDown(() => c.removeListener(check));
    await c.openFile(demoScore.path);
    await c.openProject(name: 'demo.musicxml', scoreBytes: demoScore.readAsBytesSync(), state: const ProjectState());
    expect(half, isEmpty);
  });

  test('a project still opening when its window closes stops there: its recording is never loaded', () async {
    final closing = EditorController(vsync: const TestVSync());
    final opening = closing.openProject(
        name: 'demo.musicxml', scoreBytes: demoScore.readAsBytesSync(), state: const ProjectState(), mediaPath: demoRecording.path);
    closing.dispose(); // while engraving
    expect(await opening, isNull);
    expect(closing.track, isNull);
  });

  test("an edit that can't be engraved keeps the score as it was, says why, and Undo steps back", () async {
    final failing = _FailingEngraver(vsync: const TestVSync());
    addTearDown(failing.dispose);
    await failing.openFile(demoScore.path);
    final before = failing.score;
    final vivo = before!.texts.firstWhere((t) => t.text == 'Vivo');

    failing.fail = true;
    await failing.editText(vivo.id, 'Presto'); // completes: nothing thrown at the caller
    expect(failing.score, same(before), reason: 'the score engraved before stays');
    expect(failing.engravingFailure.value, isA<EngraveException>());
    expect(failing.isReengraving, isFalse);

    failing.engravingOptions = const EngravingOptions().withValue(EngraveOption.byKey('measureMinWidth')!, 20);
    await pumpEventQueue(); // not awaited by anyone: still caught
    expect(failing.engravingFailure.value, isA<EngraveException>());

    failing.fail = false;
    failing.undo();
    while (failing.isReengraving) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(failing.currentText(vivo), 'Vivo');
    expect(failing.engravingFailure.value, isNull, reason: 'engraved again');
  });
}

class _FailingEngraver extends EditorController {
  _FailingEngraver({required super.vsync});

  bool fail = false;

  @override
  Future<LoadedScore> engraveAgain(LoadedScore score) async {
    if (fail) throw EngraveException('The score could not be engraved.');
    return super.engraveAgain(score);
  }
}
