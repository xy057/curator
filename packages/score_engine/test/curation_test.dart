import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

void main() {
  // 8 bars of 4/4 at ♩ = 120: one bar = 2 s, one quarter = 0.5 s.
  final timeline = ConstantTempoTimeline(
    List.generate(8, (_) => MeasureLayout(left: 0, right: 0, duration: 4, onsetTimes: Float64List(0), onsetXs: Float64List(0))),
    quarterNotesPerMinute: 120,
  );

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
