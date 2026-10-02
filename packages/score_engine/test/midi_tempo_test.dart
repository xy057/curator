import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

/// A Standard MIDI File of [tracks], each a list of (delta ticks, event bytes).
Uint8List midiFile(List<List<(int, List<int>)>> tracks, {int format = 1, int division = 480}) {
  List<int> number(int v) {
    final out = [v & 0x7f];
    while ((v >>= 7) > 0) {
      out.insert(0, 0x80 | (v & 0x7f));
    }
    return out;
  }

  List<int> u32(int v) => [v >> 24 & 0xff, v >> 16 & 0xff, v >> 8 & 0xff, v & 0xff];
  final bytes = [...'MThd'.codeUnits, ...u32(6), 0, format, 0, tracks.length, division >> 8, division & 0xff];
  for (final track in tracks) {
    final body = [
      for (final (delta, event) in track) ...[...number(delta), ...event],
      0, 0xff, 0x2f, 0, // end of track
    ];
    bytes.addAll([...'MTrk'.codeUnits, ...u32(body.length), ...body]);
  }
  return Uint8List.fromList(bytes);
}

List<int> tempo(double qpm) {
  final us = (60e6 / qpm).round();
  return [0xff, 0x51, 3, us >> 16 & 0xff, us >> 8 & 0xff, us & 0xff];
}

void main() {
  test('reads tempo changes from every track, in quarters', () {
    final map = MidiTempoMap.read(midiFile([
      [(0, tempo(100)), (960, tempo(150))], // a change after two quarters
      [(0, [0x90, 60, 100]), (480, [60, 0]), (0, [0xc0, 5]), (480, tempo(75))], // notes (running status), a program, a tempo
    ]), name: 'tempo.mid');
    expect(map.name, 'tempo.mid');
    expect([for (final t in map.tempos) t.quarter], [0, 2]);
    expect(map.tempos.first.quartersPerMinute, closeTo(100, 1e-3));
    expect(map.tempos.last.quartersPerMinute, closeTo(75, 1e-3), reason: 'the later track wins at the same tick');
    expect(map.secondsAt(2), closeTo(1.2, 1e-6));
    expect(map.secondsAt(4), closeTo(1.2 + 1.6, 1e-6));
  });

  test('no tempo is 120 a minute; a change past the start keeps 120 before it', () {
    expect(MidiTempoMap.read(midiFile([[]])).tempos, [(quarter: 0.0, quartersPerMinute: 120.0)]);
    final map = MidiTempoMap.read(midiFile([[(480 * 4, tempo(60))]]));
    expect(map.secondsAt(4), closeTo(2, 1e-9));
    expect(map.secondsAt(5), closeTo(3, 1e-6));
  });

  test('anchors follow the map exactly, from the start given to the end of the score', () {
    final map = MidiTempoMap.read(midiFile([[(0, tempo(120)), (480 * 8, tempo(60)), (480 * 100, tempo(200))]]));
    final anchors = map.anchors(start: 1.5, totalQuarters: 16);
    expect([for (final a in anchors) a.quarter], [0, 8, 16], reason: 'a change past the end is left out');
    expect([for (final a in anchors) a.seconds], [1.5, 5.5, closeTo(13.5, 1e-6)]);
    final sync = SyncMap(measureStarts: [for (var i = 0; i <= 4; i++) i * 4.0], defaultTempo: 90)..load(anchors);
    expect(sync.secondsAtQuarter(10), closeTo(1.5 + map.secondsAt(10), 1e-6));
    expect(sync.segmentTempo(1), closeTo(60, 1e-6));
  });

  test('rejects what has no tempo map', () {
    expect(() => MidiTempoMap.read(Uint8List.fromList('not midi at all'.codeUnits)), throwsFormatException);
    expect(() => MidiTempoMap.read(midiFile([[]], division: 0xE728)), throwsFormatException, reason: 'SMPTE time');
    final cut = midiFile([[(0, tempo(100))]]);
    expect(() => MidiTempoMap.read(Uint8List.sublistView(cut, 0, cut.length - 3)), throwsFormatException);
  });

  test('reads a MIDI file wrapped in RIFF (.rmi)', () {
    final smf = midiFile([[(0, tempo(90))]]);
    List<int> le32(int v) => [v & 0xff, v >> 8 & 0xff, v >> 16 & 0xff, v >> 24 & 0xff];
    final riff = Uint8List.fromList([...'RIFF'.codeUnits, ...le32(smf.length + 12), ...'RMID'.codeUnits, ...'data'.codeUnits, ...le32(smf.length), ...smf]);
    expect(MidiTempoMap.read(riff).tempos.single.quartersPerMinute, closeTo(90, 1e-3));
  });
}
