import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

void main() {
  // 8 bars of 4/4 at ♩ = 120: one bar = 2 s, one quarter = 0.5 s.
  final timeline = ConstantTempoTimeline(
    List.generate(8, (_) => MeasureLayout(left: 0, right: 0, duration: 4, onsetTimes: Float64List(0), onsetXs: Float64List(0))),
    quarterNotesPerMinute: 120,
  );

  test('overlapping and touching regions merge', () {
    final c = Curation(['vn'])..setLane('vn', const [Region(8, 12), Region(0, 4), Region(4, 6), Region(10, 16)]);
    expect(c.lane('vn'), const [Region(0, 6), Region(8, 16)]);
  });

  test('a drag may overlap regions live; normalizing merges them', () {
    final c = Curation(['vn'])..setLane('vn', const [Region(0, 4), Region(6, 8)]);
    c.updateLanes({'vn': const [Region(0, 4), Region(3, 7), Region(6, 8)]});
    expect(c.lane('vn'), hasLength(3), reason: 'passing over each other');
    c.normalize();
    expect(c.lane('vn'), const [Region(0, 8)]);
  });

  test('drawing joins regions; erasing trims, splits and removes them', () {
    final c = Curation(['vn', 'va'])..setLane('vn', const [Region(0, 8), Region(12, 16)]);
    c.paint(['vn', 'va'], const Region(6, 14));
    expect(c.lane('vn'), const [Region(0, 16)]);
    expect(c.lane('va'), const [Region(6, 14)]);

    c.paint(['vn'], const Region(4, 13), shown: false);
    expect(c.lane('vn'), const [Region(0, 4), Region(13, 16)]);
    c.paint(['vn'], const Region(0, 5), shown: false);
    expect(c.lane('vn'), const [Region(13, 16)]);
  });

  test('bars are counted by their own length', () {
    const starts = <double>[0, 4, 6, 10, 14]; // 4/4, 2/4, 4/4, 4/4
    expect(Curation.barsBetween(starts, 4, 6), 1);
    expect(Curation.barsBetween(starts, 5, 8), closeTo(1, 1e-9)); // half of 2/4 + half of 4/4
    expect(Curation.barsBetween(starts, 0, 14), 4);
  });

  test('tidying fills short rests and drops short flashes', () {
    const starts = <double>[0, 4, 8, 12, 16, 20, 24, 28, 32];
    final c = Curation(['vn', 'fl'])
      ..setLane('vn', const [Region(0, 4), Region(8, 12), Region(24, 28)])
      ..setLane('fl', const [Region(0, 4), Region(8, 12)]);
    c.fillGaps(starts, 1, partIds: ['vn']);
    expect(c.lane('vn'), const [Region(0, 12), Region(24, 28)]); // 3-bar rest kept
    expect(c.lane('fl'), const [Region(0, 4), Region(8, 12)]); // other lane untouched

    c.removeShort(starts, 2);
    expect(c.lane('vn'), const [Region(0, 12)]);
    expect(c.lane('fl'), isEmpty);
  });

  test('a lane can be copied to others', () {
    final c = Curation(['vn1', 'vn2', 'va'])..setLane('vn1', const [Region(0, 4), Region(8, 12)]);
    c.copyLane('vn1', ['vn2', 'va']);
    expect(c.lane('vn2'), c.lane('vn1'));
    expect(c.lane('va'), c.lane('vn1'));
  });

  test('joined lanes (a condensed pair) are one: an edit of either is an edit of both', () {
    final c = Curation(['fl1', 'fl2', 'ob'])
      ..setLane('fl1', const [Region(0, 4)])
      ..setLane('fl2', const [Region(2, 8)]);
    c.join({'fl2': 'fl1'});
    expect(c.lane('fl1'), const [Region(0, 8)], reason: 'shown wherever either was');
    expect(c.lane('fl2'), const [Region(0, 8)]);

    c.paint(['fl1'], const Region(2, 4), shown: false);
    expect(c.lane('fl2'), const [Region(0, 2), Region(4, 8)]);
    c.setLane('fl2', const [Region(12, 16)]);
    expect(c.lane('fl1'), const [Region(12, 16)]);
    c.updateLanes({'fl1': const [Region(12, 16), Region(14, 20)], 'fl2': const [Region(12, 16)], 'ob': const []});
    expect(c.lane('fl2'), hasLength(2), reason: 'a drag writing every lane: the one that changed wins');
    c.normalize();
    expect(c.lane('fl2'), const [Region(12, 20)]);

    c.join(const {});
    c.setLane('fl1', const []);
    expect(c.lane('fl2'), const [Region(12, 20)], reason: 'apart again, each keeps its regions');
  });

  test('visibility ramps smoothly around region edges', () {
    final c = Curation(['vn'])
      ..transition = 0.4
      ..addRegion('vn', const Region(4, 12)); // bar 2–3 → 2 s … 6 s
    double v(double t) => c.visibilityAt(t, timeline)['vn']!;
    expect(v(1.0), 0);
    expect(v(2.0), closeTo(0.5, 1e-9)); // half-way through the fade, on the edge
    expect(v(4.0), 1);
    expect(v(6.0), closeTo(0.5, 1e-9));
    expect(v(7.0), 0);
    // Continuous: no jumps between neighbouring frames.
    for (var t = 0.0; t < 8; t += 1 / 240) {
      expect((v(t + 1 / 240) - v(t)).abs(), lessThan(0.05));
    }
  });

  test('no fade before the first bar or after the last', () {
    final end = timeline.measureStarts.last;
    final c = Curation(['vn', 'fl'])
      ..transition = 0.4
      ..addRegion('vn', Region(0, end)) // the whole piece
      ..addRegion('fl', const Region(0, 4)); // bar 1 only
    double v(String id, double t) => c.visibilityAt(t, timeline)[id]!;
    final last = timeline.secondsAtQuarter(end);
    for (final t in [-1.0, 0.0, 0.1, last - 0.1, last, last + 1]) {
      expect(v('vn', t), 1, reason: 'at $t s');
    }
    expect(v('fl', -1), 1); // shown through any lead-in…
    expect(v('fl', 2.0), closeTo(0.5, 1e-9)); // …but still fades out where bar 1 ends
    expect(c.isShownAt('vn', last + 1, timeline), isTrue);
    expect(c.edgesInSeconds(timeline), [2.0]); // the piece's own ends don't move anything
  });

  test('staff stack centres a few staves and never exceeds maxGap', () {
    const slot = StaffSlot(height: 36, inkAbove: 0, inkBelow: 0, visibility: 1);
    const hidden = StaffSlot(height: 36, inkAbove: 0, inkBelow: 0, visibility: 0);
    final tops = StaffStack.layout(const [slot, hidden, slot],
        const StackMetrics(availableHeight: 600, minGap: 24, maxGap: 140));
    expect(tops[2] - (tops[0] + 36), 140); // gap capped
    expect(tops[0] - 0, closeTo(600 - (tops[2] + 36), 1e-9)); // centred
  });

  test('instrument names read like an engraved score', () {
    expect(prettyInstrumentName('Clarinet (B Flat) 1'), 'Clarinet in B♭ 1');
    expect(prettyInstrumentName('Horn (F) 2'), 'Horn in F 2');
    expect(prettyInstrumentName('Cl. (B Flat) 1'), 'Cl. in B♭ 1');
    expect(prettyInstrumentName('Trumpet in Bb'), 'Trumpet in B♭');
    expect(prettyInstrumentName('Violin I'), 'Violin I');
  });

  test('auto-curation shows a staff where its part plays, through rests of a bar', () {
    //                  bar: 1     2     3      4      5     6      7      8     9
    expect(autoCurateMeasures([true, true, false, true, false, false, true, true, false]), [(0, 4), (6, 8)]);
    expect(autoCurateMeasures([false, true, false, true], bridge: 0), [(1, 2), (3, 4)]);
    expect(autoCurateMeasures([false, false]), isEmpty);

    final c = Curation(['vn', 'va']);
    c.autoCurate({'vn': [true, false, true], 'va': [true, false, false]}, [0, 4, 8, 12], partIds: ['vn']);
    expect(c.lane('vn'), const [Region(0, 12)]);
    expect(c.lane('va'), isEmpty, reason: 'only the lanes asked for');
  });
}
