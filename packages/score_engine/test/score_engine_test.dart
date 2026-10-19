import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_score.dart';

Future<void> loadFont(String family, String path) async {
  final bytes = await File(path).readAsBytes();
  await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(bytes)))).load();
}

void main() {
  late LoadedScore score;

  setUpAll(() async {
    await loadFont('packages/score_engine/Bravura', 'assets/fonts/Bravura.otf');
    score = await LoadedScore.load(demoScore());
  });

  test('reads the part list', () {
    final parts = score.metadata.parts;
    expect(parts, hasLength(21));
    expect(parts.first.name, 'Piccolo');
    expect(parts.first.family, InstrumentFamily.woodwinds);
    expect(parts.last.name, 'Double Bass');
    expect(parts.last.family, InstrumentFamily.strings);
    expect(parts.last.staffNumbers, [21]);
    expect(score.metadata.tempo, 93);
  });

  test('scroll map puts every onset under the pointer as it sounds, and never runs backwards', () {
    final map = score.scrollMap;
    final measures = score.engraving.measures, starts = score.timeline.measureStarts;
    expect(map.duration, closeTo(44 * 3 * 60 / 93, 1e-6)); // 44 bars of 6/8 at ♩ = 93
    // An anchor on every onset in every staff (and the final barline), each on its notes.
    expect(map.times, hasLength(measures.fold(0, (n, m) => n + m.onsetTimes.length) + 1));
    for (var i = 0; i < measures.length; i++) {
      for (var j = 0; j < measures[i].onsetTimes.length; j++) {
        final t = score.timeline.secondsAtQuarter(starts[i] + measures[i].onsetTimes[j]);
        expect(map.xAt(t), closeTo(measures[i].onsetXs[j], 0.5), reason: 'bar ${i + 1}, onset $j');
      }
    }
    var previous = double.negativeInfinity;
    for (var t = -2.0; t < map.duration + 2; t += 0.01) {
      final x = map.xAt(t);
      expect(x, greaterThanOrEqualTo(previous - 1e-9));
      previous = x;
    }
  });

  test('at a warp the score jumps at once, and scrolls on smoothly on either side', () {
    final starts = score.timeline.measureStarts;
    // Bars 1–8 at the score's tempo, then back to bar 1.
    final repeatAt = score.timeline.secondsAtQuarter(starts[8]);
    final sync = SyncMap(measureStarts: starts, defaultTempo: 93, beats: score.beats)
      ..addAnchor(const SyncAnchor(0, 0))
      ..addAnchor(SyncAnchor(starts[8], repeatAt, jumpTo: 0));
    final map = ScrollMap(score.engraving, sync);
    final bar1 = map.xAt(0), bar9 = score.engraving.measures[8].onsetXs.first;
    expect(map.xAt(repeatAt - 1e-6), closeTo(bar9, 0.5));
    expect(map.xAt(repeatAt), closeTo(bar1, 0.5));
    expect(map.xAt(repeatAt + 2), closeTo(map.xAt(2), 0.5)); // the same music, the same place
    expect(map.duration, closeTo(repeatAt + score.timeline.secondsAtQuarter(starts.last), 1e-6));
    final range = map.xRange(repeatAt - 1, repeatAt + 1); // both sides of the jump
    expect(range.min, closeTo(bar1, 0.5));
    expect(range.max, closeTo(bar9, 0.5));
    var previous = double.negativeInfinity;
    for (var t = -2.0; t < map.duration + 2; t += 0.01) {
      final x = map.xAt(t);
      if (t < repeatAt || t - 0.01 >= repeatAt) expect(x, greaterThanOrEqualTo(previous - 1e-9));
      previous = x;
    }
  });

  test('staves stay still between transitions and only move while an instrument enters', () {
    final scene = CuratedScene(score);
    const size = ui.Size(1600, 900);
    final curation = Curation(score.metadata.parts.map((p) => p.id))..transition = 0.3;
    // Strings throughout; the piccolo enters at bar 33.
    for (final p in score.metadata.parts.skip(16)) {
      curation.setLane(p.id, [Region(0, score.timeline.measureStarts.last)]);
    }
    curation.setLane('P1', [Region(score.timeline.measureStarts[32], score.timeline.measureStarts.last)]);
    final entrance = score.timeline.secondsAtQuarter(score.timeline.measureStarts[32]);

    List<double> tops(double t) => [for (final p in scene.layoutAt(t, curation, size).placements) p.y];
    final steady = tops(5);
    for (var t = 5.0; t < entrance - 0.2; t += 0.25) {
      expect(tops(t), steady, reason: 'staves moved at $t s with no entrance nearby');
    }
    expect(tops(entrance), isNot(steady)); // the piccolo is entering: everything makes room
    final after = tops(entrance + 1);
    for (var t = entrance + 1; t < score.scrollMap.duration; t += 0.25) {
      expect(tops(t), after, reason: 'staves moved at $t s after the entrance settled');
    }
    scene.dispose();
  });

  test('grouped in sections, each family is bracketed and barred through, as printed', () {
    final scene = CuratedScene(score);
    const size = ui.Size(1600, 2400);
    final curation = Curation(score.metadata.parts.map((p) => p.id));
    for (final p in score.metadata.parts) {
      curation.setLane(p.id, [Region(0, score.timeline.measureStarts.last)]);
    }
    expect(scene.layoutAt(30, curation, size).brackets, isEmpty); // off by default

    scene.sections = true;
    var frame = scene.layoutAt(30, curation, size);
    // Woodwinds, brass, percussion, strings; the barlines break only between them. The snare
    // drum, outside the file's brackets, stands alone.
    expect(frame.brackets, hasLength(4));
    expect(frame.joins, hasLength(20)); // the starting line through all 21 staves
    expect([for (final (i, j) in frame.joins.indexed) if (!j.barlines) i], [8, 12, 14, 15]);
    expect(frame.brackets[2].bottom, frame.placements[14].y + 4 * scene.style.staffSpace); // down to the glockenspiel
    expect(frame.brackets.first.top, frame.placements.first.y);

    // Violin I moved to the top stands alone: no bracket, no barlines down into the woodwinds.
    scene.partOrder = ['P17'];
    frame = scene.layoutAt(30, curation, size);
    expect(frame.brackets, hasLength(4));
    expect(frame.brackets.first.top, frame.placements[1].y);
    expect(frame.joins.first.barlines, isFalse);
    scene.sectionOverrides = {'P17': 'bracket-1'}; // bracketed on its own by the user: it is
    expect(scene.layoutAt(30, curation, size).brackets.first.top, frame.placements.first.y);
    scene.sectionOverrides = const {};

    // A section down to one instrument keeps its bracket: Oboe 1 alone in the woodwinds.
    for (final p in score.metadata.parts.take(9)) {
      if (p.id != 'P4') curation.setLane(p.id, const []);
    }
    frame = scene.layoutAt(30, curation, size);
    final oboe = frame.placements[1]; // Violin I, then Oboe 1
    expect(frame.brackets, hasLength(4));
    expect((frame.brackets.first.top, frame.brackets.first.opacity), (oboe.y, 1.0));
    scene.dispose();
  });

  test('a video frame is the preview drawn offscreen, at any pixel size', () async {
    final scene = CuratedScene(score);
    final curation = Curation(score.metadata.parts.map((p) => p.id));
    for (final p in score.metadata.parts.skip(16)) {
      curation.setLane(p.id, [Region(0, score.timeline.measureStarts.last)]);
    }
    Future<ByteData> bytes(ui.Image image) async => (await image.toByteData())!;

    // The same pixels as painting the preview at that size and density.
    final frame = scene.renderFrame(1600, 900, time: 30, curation: curation, devicePixelRatio: 2);
    final recorder = ui.PictureRecorder();
    scene.paint(ui.Canvas(recorder)..scale(2), const ui.Size(800, 450),
        time: 30, curation: curation, devicePixelRatio: 2);
    final preview = recorder.endRecording().toImageSync(1600, 900);
    expect((await bytes(frame)).buffer.asUint8List(), (await bytes(preview)).buffer.asUint8List());

    // 720p laid out like a 540-point-high preview: a fractional density, whole pixels out.
    final hd = scene.renderFrame(1280, 720, time: 30, curation: curation, devicePixelRatio: 720 / 540);
    expect((hd.width, hd.height), (1280, 720));
    final pixels = await bytes(hd);
    final colours = {for (var i = 0; i < pixels.lengthInBytes; i += 4) pixels.getUint32(i)};
    expect(colours, contains(0xFFFFFFFF), reason: 'paper');
    expect(colours, contains(0x14171AFF), reason: 'ink');
    for (final image in [frame, preview, hd]) {
      image.dispose();
    }
    scene.dispose();
  });
}
