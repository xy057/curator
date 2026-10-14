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

  group('editing', () {
    MidiTempo t(double quarter, double qpm) => (quarter: quarter, quartersPerMinute: qpm);
    final map = MidiTempoMap('a.mid', [t(0, 120), t(8, 60), t(16, 90)]);

    test('quarterAt is the inverse of secondsAt', () {
      for (final q in const <double>[0, 3, 8, 11.5, 16, 40]) {
        expect(map.quarterAt(map.secondsAt(q)), closeTo(q, 1e-9));
      }
    });

    test('secondsAt adds up the tempos before it, at and between the changes, and before the start', () {
      double walked(double q) {
        var seconds = 0.0, at = 0.0, qpm = map.tempos.first.quartersPerMinute;
        for (final t in map.tempos.skip(1)) {
          if (t.quarter >= q) break;
          seconds += (t.quarter - at) * 60 / qpm;
          (at, qpm) = (t.quarter, t.quartersPerMinute);
        }
        return seconds + (q - at) * 60 / qpm;
      }

      for (final q in const <double>[-2, 0, 0.5, 8, 8.25, 15.9, 16, 16.1, 100]) {
        expect(map.secondsAt(q), closeTo(walked(q), 1e-9), reason: 'at $q');
        expect(map.quarterAt(map.secondsAt(q)), closeTo(q, 1e-9), reason: 'back from $q');
      }
    });

    test('a change moves between its neighbours only; the first stays at 0', () {
      expect(map.moved(1, quarter: 10, quartersPerMinute: 72).tempos[1], t(10, 72));
      expect(map.moved(1, quarter: 16, quartersPerMinute: 72).tempos[1], t(8, 72), reason: 'onto the next');
      expect(map.moved(1, quarter: 0, quartersPerMinute: 72).tempos[1], t(8, 72), reason: 'onto the previous');
      expect(map.moved(0, quarter: 3, quartersPerMinute: 100).tempos.first, t(0, 100));
      expect(map.moved(1, quarter: 8, quartersPerMinute: 120).tempos, hasLength(3), reason: 'kept while dragged');
      expect(map.moved(1, quarter: 8, quartersPerMinute: 120).name, 'a.mid');
    });

    test('drawing replaces the changes it covers; the last drawn holds to the next change', () {
      final drawn = map.drawn([t(6, 100), t(7, 110), t(8, 110), t(9, 120)], until: 10);
      expect(drawn.tempos, [t(0, 120), t(6, 100), t(7, 110), t(9, 120), t(16, 90)]);
      expect(map.drawn([t(4, 120)], until: 5).tempos, map.tempos, reason: 'the tempo it had: nothing added');
    });

    test('removing keeps the first change, and the others as they are', () {
      expect(map.removed({0, 1}).tempos, [t(0, 120), t(16, 90)]);
      expect(MidiTempoMap('', [t(0, 90), t(4, 60), t(8, 90)]).removed({1}).tempos, [t(0, 90), t(8, 90)]);
    });

    test('inserting keeps the tempo there, as a change of its own', () {
      expect(map.inserted(12).tempos, [t(0, 120), t(8, 60), t(12, 60), t(16, 90)]);
      expect(map.inserted(8), map, reason: 'already a change there');
      expect(map.inserted(0), map);
      final kept = map.inserted(4).drawn([t(10, 70)], until: 11);
      expect(kept.tempos, contains(t(4, 120)), reason: 'drawing elsewhere keeps it');
    });
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

    test('warps that don\'t fit the score are left out', () {
      expect(map.withWarps([(at: 20, jumpTo: 0)]).arrivals(16), isEmpty, reason: 'arrives past the end');
      expect(map.withWarps([(at: 8, jumpTo: 16)]).arrivals(16), isEmpty, reason: 'goes on from the end');
      expect(map.withWarps([(at: 8, jumpTo: 8)]).arrivals(16), isEmpty, reason: 'goes on from where it is');
      expect(map.fits(16), isTrue);
      // Those that fit, from the first, are followed; the rest left out.
      final some = map.withWarps([(at: 8, jumpTo: 0), (at: 30, jumpTo: 0)]);
      expect(some.arrivals(16), [8]);
      expect(some.fits(16), isFalse);
      expect(some.anchors(start: 0, totalQuarters: 16).where((a) => a.isWarp), hasLength(1));
      final straight = map.withWarps([(at: 20, jumpTo: 0)]).anchors(start: 0, totalQuarters: 16);
      expect(straight.any((a) => a.isWarp), isFalse);
      expect(straight.last.quarter, 16);
    });

    test('hand-set warps carry over as where a file would jump; edits keep the warps', () {
      final hand = [const SyncAnchor(0, 0), const SyncAnchor(8, 8, jumpTo: 0), const SyncAnchor(12, 20, jumpTo: 14)];
      expect(MidiTempoMap.warpsOf(hand), [(at: 8.0, jumpTo: 0.0), (at: 20.0, jumpTo: 14.0)]);
      expect(map.moved(1, quarter: 10, quartersPerMinute: 40).warps, map.warps);
      expect(map.inserted(4).drawn([t(5, 50)], until: 6).removed({1}).warps, map.warps);
      expect(MidiTempoMap('x.mid', map.tempos).withWarpsOf(map).warps, map.warps, reason: 'another file read in its place');
      expect(map.withWarps(const []), isNot(map), reason: 'warps count in equality');
    });
  });
}
