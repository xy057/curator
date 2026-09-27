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

    test('a place in a repeat sounds once in each pass', () {
      final m = repeat();
      expect(m.secondsAtQuarter(8), closeTo(4, 1e-9));
      expect(m.secondsAtQuarter(8, pass: 1), closeTo(20, 1e-9));
      expect(m.timesOf(8).map((t) => t.seconds), [closeTo(4, 1e-9), closeTo(20, 1e-9)]);
      // Bar 9 starts where the first pass ends: it only sounds in the second.
      expect(m.timesOf(32).map((t) => t.pass), [1]);
      expect(m.spans(24, 40).map((s) => (s.startSeconds, s.endSeconds)), [(12, 16), (28, 36)]);
      expect(m.endSeconds, closeTo(48, 1e-9));
    });

    test('a warp forward skips a stretch', () {
      final m = map()
        ..addAnchor(const SyncAnchor(0, 0))
        ..addAnchor(const SyncAnchor(16, 8, jumpTo: 48)) // after bar 4, on to bar 13
        ..addAnchor(const SyncAnchor(64, 16));
      expect(m.quarterAtSeconds(12), closeTo(56, 1e-9));
      expect(m.spans(16, 48), isEmpty); // never played
      expect(m.segmentTempo(1), closeTo(120, 1e-9));
    });

    test('taps after a warp go on from where it jumps to, and never remove it', () {
      final m = map()
        ..addAnchor(const SyncAnchor(0, 0))
        ..addAnchor(const SyncAnchor(32, 16, jumpTo: 0));
      m.beginTapping();
      expect(m.tap(18).quarter, 4); // bar 2, second time
      m.beginTapping();
      m.tap(14);
      m.tap(20.1); // a retap passing over the warp
      expect(m.anchors.where((a) => a.isWarp), hasLength(1));
      expect(m.anchors.last.quarter, 8);
    });

    test('tapping on a warp re-times it', () {
      final m = repeat()..beginTapping();
      final tapped = m.tap(16.1);
      expect(tapped.isWarp, isTrue);
      expect(m.anchors.map((a) => a.seconds), [0, 16.1, 48]);
    });

    test('marking a warp moves the anchors after it by the jump, keeping their times', () {
      // Tapped straight through (bars 1–12), though the music went back to bar 1 after bar 8.
      final m = map();
      for (var bar = 0; bar < 12; bar++) {
        m.addAnchor(SyncAnchor(bar * 4.0, bar * 2.0));
      }
      final before = [for (var t = 0.0; t < 24; t += 0.5) m.quarterAtSeconds(t)];
      expect(m.setJump(8, 0), isTrue); // bar 9's anchor is really the repeat
      expect(m.anchors.map((a) => a.quarter).skip(8), [32, 4, 8, 12]);
      expect(m.anchors[8].jumpTo, 0);
      for (var i = 0; i < 11; i++) {
        expect(m.segmentTempo(i), closeTo(120, 1e-9));
      }
      // Undoing the jump puts them back.
      expect(m.setJump(8, null), isTrue);
      expect([for (var t = 0.0; t < 24; t += 0.5) m.quarterAtSeconds(t)], before);
    });

    test('a jump that would push anchors out of the score, or nowhere, is refused', () {
      final m = map()
        ..addAnchor(const SyncAnchor(0, 0))
        ..addAnchor(const SyncAnchor(8, 4))
        ..addAnchor(const SyncAnchor(60, 30));
      expect(m.setJump(1, 16), isFalse); // 60 + 8 is past the end
      expect(m.setJump(1, 8), isFalse); // to where it already is
      expect(m.anchors.every((a) => !a.isWarp), isTrue);
    });

    test('removing a warp takes its jump back', () {
      final m = repeat()..addAnchor(const SyncAnchor(8, 20));
      m.removeAnchors({1});
      expect(m.anchors.map((a) => a.quarter), [0, 40]); // bar 11 would be past the end: dropped
      final n = map()
        ..addAnchor(const SyncAnchor(0, 0))
        ..addAnchor(const SyncAnchor(16, 8, jumpTo: 0))
        ..addAnchor(const SyncAnchor(8, 12));
      n.removeAnchors({1});
      expect(n.anchors.map((a) => a.quarter), [0, 24]);
    });

    test('a warp\'s arrival is ordered against what comes before it, not after', () {
      final m = repeat()..addAnchor(const SyncAnchor(4, 18));
      expect(m.setAnchorQuarter(1, 36), isTrue); // the anchor after it is in the next pass
      expect(m.setAnchorQuarter(1, 0), isFalse); // …but it must come after bar 1
      expect(m.setAnchorQuarter(2, 0), isFalse); // and bar 2 (second time) comes after where it went on from
      expect(m.shiftAnchors({2}, -1, SyncGrid.bar), isFalse);
    });

    test('a warp\'s position and jump change together, as one', () {
      final m = map()
        ..addAnchor(const SyncAnchor(0, 0))
        ..addAnchor(const SyncAnchor(32, 16, jumpTo: 16))
        ..addAnchor(const SyncAnchor(20, 18));
      // One after the other, the first half would have the warp jump to where it is.
      expect(m.setAnchor(1, 16, jumpTo: 32), isTrue);
      expect(m.anchors.map((a) => (a.quarter, a.jumpTo)), [(0, null), (16, 32), (36, null)]);
    });

    test('loading drops anchors that are out of order', () {
      final m = map()
        ..load(const [SyncAnchor(0, 0), SyncAnchor(32, 16, jumpTo: 0), SyncAnchor(4, 18), SyncAnchor(2, 19)]);
      expect(m.anchors.map((a) => a.seconds), [0, 16, 18]);
    });
  });
}
