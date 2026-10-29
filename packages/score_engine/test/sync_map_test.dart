import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

void main() {
  // 16 bars of 4/4.
  final starts = [for (var i = 0; i <= 16; i++) i * 4.0];
  SyncMap map() => SyncMap(measureStarts: starts, defaultTempo: 120);

  test('the first tap is the start; later ones snap to the bar the tempo so far predicts, and re-time the one before', () {
    final m = map();
    var taps = TapPass(m);
    expect(taps.tap(1.0).quarter, 0);
    // ♩ = 120 from the MusicXML: 4.1 s later is ~8.2 quarters, so bar 3 (bar 2 was skipped).
    expect(taps.tap(5.1).quarter, 8);
    expect(m.segmentTempo(0), closeTo(8 / 4.1 * 60, 1e-9));
    // From here the tapped tempo predicts: ~2.05 s per bar, so 2.2 s later is bar 4.
    expect(taps.tap(7.3).quarter, 12);
    // A late tap (ritardando) still lands on the next bar, and slows the bar before it.
    expect(taps.tap(10.0).quarter, 16);
    expect(m.segmentTempo(2), closeTo(4 / 2.7 * 60, 1e-9));
    expect(taps.tap(10.5).quarter, 20, reason: 'too early for the next bar: still the next');
  });

  test('a time carried to another recording is the same place in the score, the same time over a repeat', () {
    // One plays bars 1–4 twice (a warp back at 8 s), the other straight through, slower.
    final twice = map()..load(const [SyncAnchor(0, 0), SyncAnchor(16, 8, jumpTo: 0), SyncAnchor(64, 40)]);
    final once = map()..load(const [SyncAnchor(0, 1), SyncAnchor(64, 65)]);
    expect(twice.carriedTo(once, 4), closeTo(9, 1e-9), reason: 'quarter 8, first time');
    expect(twice.carriedTo(once, 12), closeTo(9, 1e-9), reason: 'quarter 8 again: the only time it plays it');
    expect(once.carriedTo(twice, 9), closeTo(4, 1e-9));
    expect(twice.carriedTo(once, 41), closeTo(66, 1e-9), reason: 'after the end, as far after');
  });
}
