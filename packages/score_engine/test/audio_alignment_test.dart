import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_score.dart';

void main() {
  test('a recording of the demo, its first eight bars repeated and quickening throughout, aligns to every bar', () {
    final starts = [for (var i = 0; i <= 44; i++) i * 3.0];
    final notes = soundingNotes(demoScore(), starts).toList();
    const passes = [ScorePass(0, 24), ScorePass(0, 132)];

    // Played: 1.5 s of silence, then 70 quarters a minute quickening to 110 by the end.
    const rate = 11025, played = 156.0;
    double secondsAt(double p) {
      const a = 70 / 60, k = (110 / 60 - a) / played;
      return 1.5 + math.log((a + k * p) / a) / k;
    }

    // Each note a tone of three harmonics, struck and settling to a sustain (a tie holds it).
    final samples = Float32List(((secondsAt(played) + 1) * rate).ceil());
    var offset = 0.0;
    for (final pass in passes) {
      final struck = <(String, int), double>{};
      for (final n in notes.where((n) => n.start >= pass.start && n.start < pass.end)) {
        final origin = n.tied ? struck[(n.partId, n.midi)] ?? n.start : n.start;
        struck[(n.partId, n.midi)] = origin;
        final hz = 440 * math.pow(2, (n.midi - 69) / 12), from = secondsAt(offset + origin), end = secondsAt(offset + n.end);
        for (var i = (secondsAt(offset + n.start) * rate).round(); i < math.min(samples.length, (end + 0.1) * rate); i++) {
          final t = i / rate;
          final level = (0.4 + 0.6 * math.exp(-2 * (t - from))) * (t > end ? math.exp(-30 * (t - end)) : 1);
          samples[i] += 0.02 * level * (math.sin(2 * math.pi * hz * t) + math.sin(4 * math.pi * hz * t) / 2 + math.sin(6 * math.pi * hz * t) / 3);
        }
      }
      offset += pass.end - pass.start;
    }

    final chroma = AudioChroma(rate.toDouble());
    final frames = [chroma.add(Float32List.sublistView(samples, 0, samples.length ~/ 2)), chroma.add(Float32List.sublistView(samples, samples.length ~/ 2)), chroma.finish()];
    final anchors = AudioAlignment.anchors(
      audio: Float32List.fromList([for (final f in frames) ...f]),
      frameRate: chroma.frameRate,
      notes: notes,
      measureStarts: starts,
      passes: passes,
    );

    expect([for (final a in anchors) if (a.isWarp) (a.quarter, a.jumpTo)], [(24.0, 0.0)]);
    final sync = SyncMap(measureStarts: starts, defaultTempo: 100)..load(anchors);
    for (final (k, (from, to, at)) in [(0.0, 24.0, 0.0), (0.0, 132.0, 24.0)].indexed) {
      for (final q in starts.where((q) => q >= from && q <= to)) {
        expect(sync.secondsAtQuarter(q, pass: k), closeTo(secondsAt(at + q - from), 0.35), reason: 'pass ${k + 1}, bar ${q ~/ 3 + 1}');
      }
    }
  });
}
