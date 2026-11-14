import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

void main() {
  // 16 bars of 4/4.
  final starts = [for (var i = 0; i <= 16; i++) i * 4.0];
  SyncMap map() => SyncMap(measureStarts: starts, defaultTempo: 120);

  test('tapping, recordings carried and spliced, markers over a repeat, tempo maps and back', () {
    // The first tap is the start; later ones snap to the bar the tempo so far predicts, and re-time the one before.
    final m = map();
    final taps = TapPass(m);
    expect(taps.tap(1.0).quarter, 0);
    expect(taps.tap(5.1).quarter, 8, reason: '♩ = 120 from the MusicXML: ~8.2 quarters, so bar 3 (bar 2 skipped)');
    expect(m.segmentTempo(0), closeTo(8 / 4.1 * 60, 1e-9));
    expect(taps.tap(7.3).quarter, 12, reason: 'the tapped tempo predicts from here');
    expect(taps.tap(10.0).quarter, 16, reason: 'a late tap still lands on the next bar');
    expect(m.segmentTempo(2), closeTo(4 / 2.7 * 60, 1e-9));

    // One plays bars 1–4 twice (a warp back at 8 s), the other straight through, slower: a
    // time carried across is the same place in the score.
    final twice = map()..load(const [SyncAnchor(0, 0), SyncAnchor(16, 8, jumpTo: 0), SyncAnchor(64, 40)]);
    final once = map()..load(const [SyncAnchor(0, 1), SyncAnchor(64, 65)]);
    expect([twice.carriedTo(once, 4), twice.carriedTo(once, 12), once.carriedTo(twice, 9), twice.carriedTo(once, 41)],
        [closeTo(9, 1e-9), closeTo(9, 1e-9), closeTo(4, 1e-9), closeTo(66, 1e-9)]);

    // Markers in time: a repeat back into one is that one again; a video's chapters as FFmpeg reads them.
    expect(markerSpans(const [0.0, 8.0, 32.0], twice).map((s) => (s.marker, s.start, s.end)), [(0, 0, 4), (1, 4, 8), (0, 8, 12), (1, 12, 24), (2, 24, 40)]);
    expect(markerSpans(const [8.0, 32.0], twice).map((s) => s.marker), [-1, 0, -1, 0, 1]);
    const cues = [(start: 0.0, end: 2.0, name: 'A'), (start: 2.0, end: 6.0, name: 'B = 2')];
    expect(chapterTimestamps(cues), '0:00 A\n0:02 B = 2\n');
    expect(chapterMetadata(cues), contains('[CHAPTER]\nTIMEBASE=1/1000\nSTART=2000\nEND=6000\ntitle=B \\= 2\n'));

    // Recordings spliced by their lanes: each at its own tempo where its region is, crossfaded, silent between.
    final quick = map()..load(const [SyncAnchor(0, 0), SyncAnchor(64, 32)]);
    final slow = map()..load(const [SyncAnchor(0, 1), SyncAnchor(64, 65)]);
    final splice = TakeSplice(takes: [quick, slow], lanes: [
      [const Region(0, 16)],
      [const Region(16, 32, transitionIn: 0.5)],
    ]);
    expect([splice.secondsAtQuarter(16), splice.secondsAtQuarter(32), splice.secondsAtQuarter(64), splice.quarterAtSeconds(16)],
        [closeTo(8, 1e-9), closeTo(24, 1e-9), closeTo(56, 1e-9), closeTo(24, 1e-9)]);
    final [first, second] = splice.chunks;
    expect((first.take, first.from, first.at, first.fadeOut), (0, 0.0, 0.0, 0.3));
    expect((second.take, second.at, second.from), (1, 7.75, 16.75));
    expect([gainAt(second, 8), gainAt(second, 20), gainAt(second, 30)], [closeTo(0.5, 1e-9), 1, 0]);

    // Anchors as a tempo map and back are where they were, over a repeat, before the first and after the last.
    final hand = map()..load(const [SyncAnchor(4, 2), SyncAnchor(8, 4.5), SyncAnchor(16, 9, jumpTo: 0), SyncAnchor(10, 15), SyncAnchor(40, 31)]);
    final tempo = MidiTempoMap.ofSync(hand);
    expect(tempo.warps, [(at: 16.0, jumpTo: 0.0)]);
    expect(tempo.tempos, hasLength(6));
    final back = map()..load(tempo.anchors(start: hand.startSeconds, totalQuarters: 64));
    for (var s = 0.0; s < 50; s += 0.7) {
      expect(back.quarterAtSeconds(s), closeTo(hand.quarterAtSeconds(s), 1e-9), reason: '$s s');
    }
  });
}
