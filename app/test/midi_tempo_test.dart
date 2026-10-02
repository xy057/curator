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
    expect(state.midi, c.midiTempo);
    expect(state.anchors, const [SyncAnchor(0, 2), SyncAnchor(6, 5)]);

    final other = EditorController(vsync: const TestVSync());
    addTearDown(other.dispose);
    await other.openProject(name: 'x', scoreBytes: await demoScore.readAsBytes(), state: state);
    expect(other.sync!.anchors, c.sync!.anchors);
    other.useMidiTempo(null);
    expect(other.sync!.anchors, const [SyncAnchor(0, 2), SyncAnchor(6, 5)]);

    expect(ProjectState.fromJson({'sync': {'anchors': <Object?>[]}}, savedVersion: 6).midi, isNull);
    expect(() => ProjectState.fromJson({'sync': {'midi': {'tempos': [[1, 90]]}}}), throwsFormatException);
  });

  test('a file that is not MIDI changes nothing', () async {
    expect(() => c.loadMidiTempo(demoScore.path), throwsFormatException);
    expect(c.usesMidiTempo, isFalse);
    expect(c.canUndo, isFalse);
  });
}
