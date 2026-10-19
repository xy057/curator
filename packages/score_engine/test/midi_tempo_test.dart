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
  test('anchors follow the map exactly, from the start given to the end of the score', () {
    final map = MidiTempoMap.read(midiFile([[(0, tempo(120)), (480 * 8, tempo(60)), (480 * 100, tempo(200))]]));
    final anchors = map.anchors(start: 1.5, totalQuarters: 16);
    expect([for (final a in anchors) a.quarter], [0, 8, 16], reason: 'a change past the end is left out');
    expect([for (final a in anchors) a.seconds], [1.5, 5.5, closeTo(13.5, 1e-6)]);
    final sync = SyncMap(measureStarts: [for (var i = 0; i <= 4; i++) i * 4.0], defaultTempo: 90)..load(anchors);
    expect(sync.secondsAtQuarter(10), closeTo(1.5 + map.secondsAt(10), 1e-6));
    expect(sync.segmentTempo(1), closeTo(60, 1e-6));
  });

  group('warps', () {
    MidiTempo t(double quarter, double qpm) => (quarter: quarter, quartersPerMinute: qpm);
    // A 16-quarter score whose first 8 are repeated: the file plays 24 quarters, at 60 a
    // minute, slowing to 30 on the way through the repeat.
    final measures = [for (var i = 0; i <= 4; i++) i * 4.0];
    final map = MidiTempoMap('r.mid', [t(0, 60), t(12, 30)], warps: [(at: 8, jumpTo: 0)]);

    test('the file runs on through a jump: its quarters are played quarters', () {
      expect(map.arrivals(16), [8]);
      final anchors = map.anchors(start: 1, totalQuarters: 16);
      expect(anchors, [
        const SyncAnchor(0, 1),
        const SyncAnchor(8, 9, jumpTo: 0),
        const SyncAnchor(4, 13), // the change at file quarter 12: bar 2 the second time
        const SyncAnchor(16, 13 + 12 * 2),
      ]);
      final sync = SyncMap(measureStarts: measures, defaultTempo: 90)..load(anchors);
      expect(sync.passes, hasLength(2));
      expect(sync.secondsAtQuarter(2, pass: 0), closeTo(3, 1e-9));
      expect(sync.secondsAtQuarter(2, pass: 1), closeTo(11, 1e-9));
      expect(sync.secondsAtQuarter(6, pass: 1), closeTo(13 + 2 * 2, 1e-9), reason: 'at 30 a minute');
    });
  });
}
