import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

void main() {
  // 16 bars of 4/4.
  final starts = [for (var i = 0; i <= 16; i++) i * 4.0];
  SyncMap map() => SyncMap(measureStarts: starts, defaultTempo: 120);

  test('tapping, recordings carried and spliced, markers over a repeat, automation in time, tempo maps and back, a DAW\'s tempo map', () {
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

    // Automation: the View lane painted, in time over the repeat (each stretch once a pass, eased
    // changes centred on its edges, a cut, nothing changing at the start), saved and read; a curve; where views go.
    const inset = SceneView(ViewKind.inset, corner: MapCorner.topLeft);
    var views = StepLane(SceneViews.target, const [AutoStretch(8, 24, SceneView.map), AutoStretch(32, 40, inset, fade: 0)]);
    final painted = views.painted(const AutoStretch(12, 20, inset));
    expect(painted.stretches.map((s) => (s.start, s.end, s.value.kind)),
        [(8, 12, ViewKind.map), (12, 20, ViewKind.inset), (20, 24, ViewKind.map), (32, 40, ViewKind.inset)]);
    expect(painted.indexOf(const AutoStretch(12, 20, inset)), 1);
    final timed = views.inTime(twice);
    expect(timed.changes.map((c) => (c.seconds, c.to.kind)),
        [(4, ViewKind.map), (8, ViewKind.score), (12, ViewKind.map), (20, ViewKind.score), (24, ViewKind.inset), (28, ViewKind.score)]);
    expect([timed.at(3.4).mix, timed.at(4).mix, timed.at(6).mix, timed.at(24).mix],
        [0, closeTo(0.5, 1e-9), 0, 0]);
    expect([timed.valueAt(6).kind, timed.valueAt(10).kind, timed.valueAt(24), timed.valueAt(30).kind], [ViewKind.map, ViewKind.score, inset, ViewKind.score]);
    expect(StepLane(SceneViews.target, const [AutoStretch(0, 4, SceneView.map)]).inTime(once).changes.map((c) => c.seconds), [5],
        reason: 'from the start, so shown from before it');
    expect(StepLane(SceneViews.target, const [AutoStretch(16, 17, SceneView.map, fade: 2)]).inTime(once).changes.map((c) => c.fade), [1, 1],
        reason: 'no longer than the time between changes');
    views = views.reshaped(0, views.stretches[0].withValue(const SceneView(ViewKind.split, side: MapSide.bottom, size: 0.3)));
    final saved = Automation.none.withSteps(views).toJson()..['later'] = {'kind': 'unknown', 'kept': true};
    final read = Automation.fromJson(saved, 'lanes', targets: automationTargets);
    expect(read.steps(SceneViews.target), views);
    expect(read.toJson(), saved, reason: 'a lane of a later Curator kept as it came');
    expect(() => Automation.fromJson({'view': {'kind': 'steps', 'stretches': [{'from': 4, 'to': 2, 'value': {'kind': 'map'}}]}}, 'lanes', targets: automationTargets),
        throwsFormatException);
    final curve = CurveLane(const _Level(), const [AutoPoint(8, 3), AutoPoint(0, 1, shape: CurveShape.smooth)]);
    expect([curve.valueAt(-1), curve.valueAt(2), curve.valueAt(20), CurveLane(const _Level()).valueAt(5), curve.valueInTime(once, 3)], [1, 1.3125, 3, 0.5, 1.3125]);
    const frame = ui.Size(960, 540);
    expect(SceneView(ViewKind.split, size: 0.4).place(frame), (score: const ui.Rect.fromLTWH(0, 0, 576, 540), scoreLayout: const ui.Size(576, 540), rows: false, map: const ui.Rect.fromLTWH(576, 0, 384, 540), inset: false));
    // The MIDI view: the score's notes in rows where the score is, kept as JSON; the score itself where there are none to draw (as a map's view is with no map).
    expect(SceneView.midi.place(frame), (score: ui.Offset.zero & frame, scoreLayout: frame, rows: true, map: null, inset: false));
    expect((SceneView.fromJson(SceneView.midi.toJson(), 'view'), SceneView.midi.showsMap), (SceneView.midi, false));
    expect([SceneView.midi.where(map: false, rows: true), SceneView.midi.where(map: true, rows: false), SceneView.map.where(map: false, rows: true)], [SceneView.midi, SceneView.score, SceneView.score]);
    final below = const SceneView(ViewKind.split, side: MapSide.bottom, size: 0.4).place(frame);
    expect((below.score, below.scoreLayout.width, below.map), (const ui.Rect.fromLTWH(0, 0, 960, 324), 1600, const ui.Rect.fromLTWH(0, 324, 960, 216)));

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

    // A DAW's document as Attacca sends it (the song of daw_link/test/link_host.cpp): 120 to
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
    // What isn't a document is refused; in one, an entry that can't be read is passed over and
    // the rest kept: a tempo entry not after the one before (two at one moment, as ARA lets a
    // DAW give them), a bar signature of no beats, a region placed nowhere.
    expect(() => DawDocument.fromJson({'contexts': <Object>[]}), throwsFormatException);
    expect(() => DawDocument.fromJson({'id': 'x', 'contexts': 'none'}), throwsFormatException);
    final rough = DawDocument.fromJson({
      'id': 'x',
      'contexts': [{'tempo': [[0, 0], [2, 4], [2, 4], [1, 5], [6, 10]], 'bars': [[4, 4, 0], [0, 4, 8]]}],
      'regions': [{'id': 'r', 'source': 's', 'start': 1, 'length': 2, 'from': 0, 'span': 2}, {'id': 'nowhere', 'source': 's', 'start': null}],
    });
    expect(rough.contexts.single.tempo, [(seconds: 0.0, quarter: 0.0), (seconds: 2.0, quarter: 4.0), (seconds: 6.0, quarter: 10.0)]);
    expect((rough.contexts.single.bars.length, rough.regions.single.id), (1, 'r'));
    expect(dawTransportOf({'playing': true, 'seconds': 2.5, 'quarters': -1, 'tempo': 0}), (playing: true, seconds: 2.5, quarters: null, tempo: 0.0));
  });
}

/// A number automated along a curve, for the test: 0.5 where nothing says.
final class _Level extends AutomationTarget<double> {
  const _Level() : super('level');

  @override
  double get base => 0.5;

  @override
  Object? encode(double value) => value;

  @override
  double decode(Object? json, String where) => json is num ? json.toDouble() : throw FormatException('$where is not a number.');
}
