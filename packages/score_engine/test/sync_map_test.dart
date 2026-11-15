import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

void main() {
  // 16 bars of 4/4.
  final starts = [for (var i = 0; i <= 16; i++) i * 4.0];
  SyncMap map() => SyncMap(measureStarts: starts, defaultTempo: 120);

  test('tapping, recordings carried and spliced, markers over a repeat, tempo maps and back, a DAW\'s tempo map', () {
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

    // A DAW's document as Curator Link sends it (the song of daw_link/test/link_host.cpp): 120 to
    // quarter 4, then 90; 4/4, then 3/4 from quarter 8; the recording from 0.5 s in, at 1 s in the song.
    final daw = DawDocument.fromJson({
      'id': 'd1', 'name': 'Symphony',
      'contexts': [
        {'id': 'c', 'tempo': [[0, 0], [2, 4], [6, 10]], 'bars': [[4, 4, 0], [3, 4, 8]],
         'keys': [{'root': -3, 'at': 0, 'name': 'C minor', 'intervals': [1, 0, 1, 1, 0, 1, 0, 1, 1, 0, 1, 0]}], 'later': {'ignored': true}},
      ],
      'tracks': [{'id': 't', 'name': 'Strings', 'color': '#ff8000', 'context': 'c'}],
      'sources': [{'id': 'take-1', 'name': 'Take 1', 'rate': 44100, 'frames': 220500, 'channels': 1, 'access': true}],
      'regions': [{'id': 'r', 'track': 't', 'context': 'c', 'source': 'take-1', 'start': 1, 'length': 3, 'from': 0.5, 'span': 3}],
    });
    final song = daw.contexts.single, region = daw.regionAt('take-1', 2)!;
    expect((daw.tracks.single.color, daw.sources.single.seconds, song.keys.single.minor), (0xffff8000, 5.0, true));
    expect([song.secondsAt(4), song.secondsAt(7), song.secondsAt(12), song.quarterAt(-1), song.quarterAt(7)],
        [2, closeTo(4, 1e-9), closeTo(7 + 1 / 3, 1e-9), -2, closeTo(11.5, 1e-9)]);
    expect([for (final b in [1, 2, 3, 4]) song.barStart(b)], [0, 4, 8, 11], reason: 'bar 3 is the first of 3/4');
    // The score's bar 1 at the DAW's bar 2, an upbeat of one quarter: the score starts at quarter 3.
    final followed = song.tempoFor(region, name: 'Strings', bar: 2, pickup: 1)!;
    expect(followed.map.tempos, [(quarter: 0.0, quartersPerMinute: 120.0), (quarter: 1.0, quartersPerMinute: 90.0)]);
    expect(followed.start, closeTo(1.5 - 1 + 0.5, 1e-9), reason: 'song 1.5 s is 1.0 s in the recording');
    final dawSync = map()..load(followed.map.anchors(start: followed.start, totalQuarters: 64));
    for (final q in [0.0, 1.0, 5.0, 9.0]) {
      expect(dawSync.secondsAtQuarter(q), closeTo(region.sourceAt(song.secondsAt(q + 3)), 1e-9), reason: 'score quarter $q');
    }
    expect(() => DawDocument.fromJson({'id': 'x', 'contexts': [{'tempo': [[1, 1], [0, 2]]}]}), throwsFormatException);
    expect(dawTransportOf({'playing': true, 'seconds': 2.5, 'quarters': -1, 'tempo': 0}), (playing: true, seconds: 2.5, quarters: null, tempo: 0.0));
  });
}
