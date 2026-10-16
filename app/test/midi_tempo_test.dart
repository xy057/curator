import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/project_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';

/// A one-track MIDI file (480 ticks a quarter): ♩ = 90, then ♩ = 60 from quarter 12.
File _midiFile() {
  List<int> tempo(double qpm) {
    final us = (60e6 / qpm).round();
    return [0xff, 0x51, 3, us >> 16 & 0xff, us >> 8 & 0xff, us & 0xff];
  }

  final body = [0, ...tempo(90), 0xad, 0x00, ...tempo(60), 0, 0xff, 0x2f, 0]; // 12 × 480 = 5760 = 0xAD 0x00
  final bytes = [
    ...'MThd'.codeUnits, 0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xe0, //
    ...'MTrk'.codeUnits, 0, 0, 0, body.length, ...body,
  ];
  final file = File('${Directory.systemTemp.createTempSync('midi-').path}/tempo.mid')..writeAsBytesSync(Uint8List.fromList(bytes));
  return file;
}

/// A one-track MIDI file (480 ticks a quarter) at ♩ = 90 that ends after [quarters].
File _midiFileOf(double quarters) {
  final ticks = (quarters * 480).round();
  final length = [for (var shift = 21; shift > 0; shift -= 7) 0x80 | (ticks >> shift & 0x7f), ticks & 0x7f];
  final body = [0, 0xff, 0x51, 3, 0x0a, 0x2c, 0x2b, ...length, 0xff, 0x2f, 0]; // 666 667 µs a quarter
  final bytes = [
    ...'MThd'.codeUnits, 0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xe0, //
    ...'MTrk'.codeUnits, 0, 0, 0, body.length, ...body,
  ];
  return File('${Directory.systemTemp.createTempSync('midi-').path}/played.mid')..writeAsBytesSync(Uint8List.fromList(bytes));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late EditorController c;

  setUp(() async {
    c = EditorController(vsync: const TestVSync());
    await c.openFile(demoScore.path);
  });
  tearDown(() => c.dispose());

  test('a MIDI file sets the sync from its tempo map, in one Undo step, and gives the tapped anchors back', () async {
    c.sync!.load(const [SyncAnchor(0, 2), SyncAnchor(6, 5)]);
    final tapped = c.sync!.anchors;
    c.tab = BottomTab.instruments;

    await c.loadMidiTempo(_midiFile().path);
    expect(c.tab, BottomTab.audio);
    expect(c.midiTempo!.name, 'tempo.mid');
    final sync = c.sync!;
    expect(sync.startSeconds, 2, reason: 'the file starts where bar 1 did');
    expect(sync.secondsAtQuarter(12), closeTo(2 + 12 * 60 / 90, 1e-4)); // µs a quarter are whole numbers in a MIDI file
    expect(sync.secondsAtQuarter(15), closeTo(2 + 8 + 3, 1e-4)); // µs a quarter are whole numbers in a MIDI file

    c.undo();
    expect(c.usesMidiTempo, isFalse);
    expect(sync.anchors, tapped);
    c.redo();
    expect(c.usesMidiTempo, isTrue);

    c.useMidiTempo(null);
    expect(sync.anchors, tapped, reason: 'the anchors set by hand come back');
  });

  test('following a MIDI file turns tapping and editing anchors off; Starts at moves the whole map', () async {
    await c.loadMidiTempo(_midiFile().path);
    final anchors = c.sync!.anchors;
    c.anchors.tapArmed = true;
    expect(c.anchors.tapArmed, isFalse);
    c.anchors.selectAll();
    c.anchors.delete();
    c.anchors.nudge(1);
    c.anchors.add(const SyncAnchor(3, 9));
    expect(c.sync!.anchors, anchors);

    c.anchors.setStart(1);
    expect(c.sync!.startSeconds, 1);
    expect(c.sync!.secondsAtQuarter(12), closeTo(9, 1e-4)); // µs a quarter are whole numbers in a MIDI file
  });

  test('a project keeps the MIDI tempo map, and the anchors behind it', () async {
    c.sync!.load(const [SyncAnchor(0, 2), SyncAnchor(6, 5)]);
    await c.loadMidiTempo(_midiFile().path);
    final json = jsonDecode(jsonEncode(c.projectState.toJson())) as Map<String, Object?>;
    final state = ProjectState.fromJson(json);
    expect(state.edits.midi, c.midiTempo);
    expect(state.edits.anchors, const [SyncAnchor(0, 2), SyncAnchor(6, 5)]);

    final other = EditorController(vsync: const TestVSync());
    addTearDown(other.dispose);
    await other.openProject(name: 'x', scoreBytes: await demoScore.readAsBytes(), state: state);
    expect(other.sync!.anchors, c.sync!.anchors);
    other.useMidiTempo(null);
    expect(other.sync!.anchors, const [SyncAnchor(0, 2), SyncAnchor(6, 5)]);

    expect(ProjectState.fromJson({'sync': {'anchors': <Object?>[]}}, savedVersion: 6).edits.midi, isNull);
    expect(() => ProjectState.fromJson({'sync': {'midi': {'tempos': [[1, 90]]}}}), throwsFormatException);
  });

  test('warps stay with a MIDI file: the score jumps where the file, playing on, reaches them', () async {
    // Hand-set: bar 3 (quarter 6 in 6/8) jumps back to bar 1.
    final starts = c.sync!.measureStarts;
    c.sync!.load([SyncAnchor(0, 2), SyncAnchor(starts[2], 5, jumpTo: 0), SyncAnchor(starts[4], 9)]);
    await c.loadMidiTempo(_midiFile().path);
    expect(c.midiTempo!.warps, [(at: starts[2], jumpTo: 0.0)], reason: 'the warps set by hand carry over');
    final sync = c.sync!;
    expect(sync.passes, hasLength(2));
    // ♩ = 90 throughout the first 12 quarters the file plays: bar 1 again at file quarter 6.
    expect(sync.secondsAtQuarter(0, pass: 1), closeTo(2 + starts[2] * 60 / 90, 1e-4));
    expect(sync.secondsAtQuarter(starts[2], pass: 1), closeTo(2 + 8 + (2 * starts[2] - 12), 1e-4),
        reason: 'the file\'s change at quarter 12 lands in the second pass');

    await c.loadMidiTempo(_midiFile().path);
    expect(c.midiTempo!.warps, [(at: starts[2], jumpTo: 0.0)], reason: 'a file read in place of another keeps them');

    expect(c.setMidiWarps([(at: starts[2], jumpTo: c.sync!.totalQuarters)]), isFalse, reason: 'goes on from the end');
    expect(c.setMidiWarps(const []), isTrue);
    expect(c.sync!.passes, hasLength(1));
    c.undo();
    expect(c.midiTempo!.warps, hasLength(1), reason: 'one Undo step');

    final state = ProjectState.fromJson(jsonDecode(jsonEncode(c.projectState.toJson())) as Map<String, Object?>);
    expect(state.edits.midi, c.midiTempo, reason: 'saved with the map');
    expect(ProjectState.fromJson({'sync': {'midi': {'tempos': [[0, 90]]}}}, savedVersion: 14).edits.midi!.warps, isEmpty);
    expect(() => ProjectState.fromJson({'sync': {'midi': {'tempos': [[0, 90]], 'warps': [[0, 4]]}}}), throwsFormatException);
  });

  test('a MIDI file as long as the score with its repeats takes the score’s warps; one played straight doesn’t', () async {
    await c.openFile(demoScoreRepeated().path);
    final starts = c.sync!.measureStarts;
    expect(c.scoreWarps, [(at: starts[4], jumpTo: 0.0)]);
    final played = starts.last + starts[4];

    await c.loadMidiTempo(_midiFileOf(played).path);
    expect(c.midiTempo!.warps, c.scoreWarps);
    expect(c.sync!.passes, hasLength(2));
    c.undo();
    expect(c.usesMidiTempo, isFalse, reason: 'with its warps, one Undo step');

    await c.loadMidiTempo(_midiFileOf(starts.last).path);
    expect(c.midiTempo!.warps, isEmpty, reason: 'played straight through');
    expect(c.useScoreWarps(), isTrue);
    expect(c.midiTempo!.warps, c.scoreWarps);
    c.undo();
    expect(c.midiTempo!.warps, isEmpty, reason: 'one Undo step');

    c.useMidiTempo(null);
    c.sync!.load([SyncAnchor(0, 2), SyncAnchor(starts[2], 5, jumpTo: 0), SyncAnchor(starts[4], 9)]);
    await c.loadMidiTempo(_midiFileOf(played).path);
    expect(c.midiTempo!.warps, [(at: starts[2], jumpTo: 0.0)], reason: 'warps set by hand win');
  });

  test('the score’s warps need a score with repeats and a MIDI tempo map', () async {
    expect(c.scoreWarps, isEmpty, reason: 'the demo plays straight through');
    expect(c.useScoreWarps(), isFalse);
    await c.openFile(demoScoreRepeated().path);
    expect(c.useScoreWarps(), isFalse, reason: 'no MIDI tempo map');
  });

  test('a file that is not MIDI changes nothing', () async {
    expect(() => c.loadMidiTempo(demoScore.path), throwsFormatException);
    expect(c.usesMidiTempo, isFalse);
    expect(c.canUndo, isFalse);
  });
}
