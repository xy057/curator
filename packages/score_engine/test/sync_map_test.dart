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

  test('the first tap is the start; the next is snapped at the score tempo', () {
    final m = map()..beginTapping();
    expect(m.tap(1.0).quarter, 0);
    // ♩ = 120 from the MusicXML: 4.1 s later is ~8.2 quarters, so bar 3 (bar 2 was skipped).
    expect(m.tap(5.1).quarter, 8);
    expect(m.segmentTempo(0), closeTo(8 / 4.1 * 60, 1e-9));
    // From here the tapped tempo predicts: ~2.05 s per bar, so 2.2 s later is bar 4.
    expect(m.tap(7.3).quarter, 12);
  });

  test('a tap too early for the next bar still moves on to it', () {
    final m = map()..beginTapping();
    m.tap(1.0);
    expect(m.tap(1.5).quarter, 4); // nearest bar would be bar 1 again
  });

  test('later taps snap to the nearest bar and re-time the previous segment', () {
    final m = map()..beginTapping();
    for (final t in [1.0, 3.0, 5.0]) {
      m.tap(t); // bars 1–3 at ♩ = 120
    }
    // A late tap (ritardando): predicted bar 4 is 2.4 s into the bar, still nearest to bar 4.
    final a = m.tap(7.4);
    expect(a.quarter, 12);
    expect(m.segmentTempo(2), closeTo(4 / 2.4 * 60, 1e-9)); // that bar slowed to 100
    // Skipping a bar: the tap lands near bar 6, so bar 5 is simply not anchored.
    expect(m.tap(7.4 + 2.4 * 2).quarter, 20);
  });

  test('beat grid anchors single beats', () {
    final m = map()..beginTapping();
    for (final t in [0.0, 0.5, 1.0, 1.5]) {
      m.tap(t, grid: SyncGrid.beat);
    }
    expect(m.anchors.map((a) => a.quarter), [0, 1, 2, 3]);
    expect(m.tap(2.05, grid: SyncGrid.beat).quarter, 4); // bar 2, beat 1
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

  test('an anchor can be redefined to point at another bar', () {
    final m = map()
      ..addAnchor(const SyncAnchor(0, 0))
      ..addAnchor(const SyncAnchor(4, 2))
      ..addAnchor(const SyncAnchor(8, 4));
    expect(m.setAnchorQuarter(1, 5), isTrue); // "that was beat 2 of bar 2"
    expect(m.anchors[1].quarter, 5);
    expect(m.setAnchorQuarter(1, 9), isFalse); // cannot jump past its neighbour
    expect(m.anchors[1].quarter, 5);
  });

  test('retapping overwrites the anchors it passes over', () {
    final m = map()..beginTapping();
    for (final t in [0.0, 2.0, 4.0, 6.0, 8.0]) {
      m.tap(t);
    }
    m.beginTapping();
    m.tap(4.1); // retap from bar 3
    expect(m.anchors.map((a) => a.seconds), [0.0, 2.0, 4.1, 6.0, 8.0]);
    m.tap(6.3);
    expect(m.anchors.map((a) => a.seconds), [0.0, 2.0, 4.1, 6.3, 8.0]);
  });

  test('moving the start keeps the rest of the anchors in place', () {
    final m = map()..beginTapping();
    for (final t in [1.0, 3.0, 5.0]) {
      m.tap(t);
    }
    m.startSeconds = 0.5;
    expect(m.anchors.map((a) => a.seconds), [0.5, 3.0, 5.0]);
  });

  group('batch editing', () {
    SyncMap fourBars() => map()
      ..addAnchor(const SyncAnchor(0, 0))
      ..addAnchor(const SyncAnchor(4, 2))
      ..addAnchor(const SyncAnchor(8, 4))
      ..addAnchor(const SyncAnchor(12, 6))
      ..addAnchor(const SyncAnchor(16, 8));

    test('a selection moves as a block, clamped by its unselected neighbours', () {
      final m = fourBars();
      expect(m.moveAnchors({1, 2}, 0.5), 0.5);
      expect(m.anchors.map((a) => a.seconds), [0, 2.5, 4.5, 6, 8]);
      // Only 1.49 s of room before the next anchor (6 s) — the block stops there.
      expect(m.moveAnchors({1, 2}, 5), closeTo(1.49, 1e-9));
      expect(m.anchors[2].seconds, closeTo(5.99, 1e-9));
    });

    test('a drag applies its delta from where the anchors started', () {
      final m = fourBars();
      final start = m.anchors;
      for (final d in [0.1, 0.2, 0.3]) {
        m.moveAnchors({2, 3}, d, from: start);
      }
      expect(m.anchors.map((a) => a.seconds), [0, 2, 4.3, 6.3, 8]);
    });

    test('a selection can be re-pointed one bar later when there is room', () {
      final m = fourBars()..removeAnchors({4});
      expect(m.shiftAnchors({2, 3}, 1, SyncGrid.bar), isTrue);
      expect(m.anchors.map((a) => a.quarter), [0, 4, 12, 16]);
      expect(m.shiftAnchors({1}, 1, SyncGrid.bar), isTrue); // bar 2 → bar 3
      expect(m.shiftAnchors({1}, 1, SyncGrid.bar), isFalse); // bar 4 is already taken
      expect(m.anchors.map((a) => a.quarter), [0, 8, 12, 16]);
    });

    test('box selection and deleting a selection', () {
      final m = fourBars();
      expect(m.anchorsBetween(3.5, 6.2), {2, 3});
      m.removeAnchors({2, 3});
      expect(m.anchors.map((a) => a.quarter), [0, 4, 16]);
    });
  });
}
