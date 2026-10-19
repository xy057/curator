import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

void main() {
  // 16 bars of 4/4.
  final starts = [for (var i = 0; i <= 16; i++) i * 4.0];
  SyncMap map() => SyncMap(measureStarts: starts, defaultTempo: 120);

  test('without anchors the score tempo applies, after the lead-in', () {
    final m = map()..startSeconds = 2;
    expect(m.secondsAtQuarter(0), 2);
    expect(m.secondsAtQuarter(4), 4); // one bar at ♩ = 120 is 2 s
    expect(m.quarterAtSeconds(4), closeTo(4, 1e-9));
  });

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

  test('scroll time follows a ritardando between anchors', () {
    final m = map()
      ..addAnchor(const SyncAnchor(0, 0))
      ..addAnchor(const SyncAnchor(4, 2)) // ♩ = 120
      ..addAnchor(const SyncAnchor(8, 5)); // ♩ = 80
    expect(m.secondsAtQuarter(6), closeTo(3.5, 1e-9));
    expect(m.quarterAtSeconds(3.5), closeTo(6, 1e-9));
    expect(m.secondsAtQuarter(12), closeTo(8, 1e-9)); // continues at the last tempo
  });

  group('warps', () {
    // Bars 1–8 (32 quarters) at ♩ = 120, then back to bar 1 and on to the end (bar 16).
    SyncMap repeat() => map()
      ..addAnchor(const SyncAnchor(0, 0))
      ..addAnchor(const SyncAnchor(32, 16, jumpTo: 0))
      ..addAnchor(const SyncAnchor(64, 48));

    test('a warp back plays the score again from where it points', () {
      final m = repeat();
      expect(m.passes, [const ScorePass(0, 32), const ScorePass(0, 64)]);
      expect(m.segmentTempo(0), closeTo(120, 1e-9));
      expect(m.segmentTempo(1), closeTo(120, 1e-9)); // the tempo runs on through the jump
      expect(m.quarterAtSeconds(10), closeTo(20, 1e-9));
      expect(m.quarterAtSeconds(15.99), closeTo(31.98, 1e-9));
      expect(m.quarterAtSeconds(16), 0); // touching the warp jumps at once
      expect(m.quarterAtSeconds(20), closeTo(8, 1e-9));
      expect(m.passAt(15.99), 0);
      expect(m.passAt(16), 1);
    });
  });
}
