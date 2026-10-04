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

  test('says what it left out of the score, each thing once', () async {
    expect(score.warnings, isEmpty, reason: 'the demo is read whole');
    // Verovio has no harp pedal diagrams: it leaves them out, and says so.
    final pedals = demoScore().replaceAll('<direction>', '<direction><direction-type><harp-pedals/></direction-type></direction><direction>');
    final harp = await LoadedScore.load(pedals);
    expect(harp.warnings, ["Unsupported direction-type 'harp-pedals'"]);
  });

  test('engraves one layer per staff, stacked in score order', () {
    final staves = score.engraving.staves;
    // The 21 parts' staves, then the six shared by pairs of players (see condensing_test).
    expect(staves.map((s) => s.n), List.generate(21 + 6, (i) => i + 1));
    final snare = score.metadata.parts.firstWhere((p) => p.name == 'Snare Drum').staffNumbers.single;
    for (final staff in staves) {
      expect(staff.lines, staff.n == snare ? 1 : 5); // the snare drum has a one-line staff
      if (staff.lines == 5) expect((staff.height - 4 * score.engraving.staffSpace).abs(), lessThan(1));
    }
    for (var i = 1; i < staves.length; i++) {
      expect(staves[i].top, greaterThan(staves[i - 1].top));
    }
  });

  test('measures carry onsets in quarter notes', () {
    final measures = score.engraving.measures;
    expect(measures, hasLength(44));
    expect(measures.every((m) => (m.duration - 3).abs() < 1e-9), isTrue); // 6/8
    expect(measures.first.onsetTimes, [0, 0.5, 0.75, 1, 1.25, 1.5, 2, 2.25, 2.5]);
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

  test('after the final barline the score eases to rest, its last bars on screen', () {
    final map = score.scrollMap, end = map.duration, last = map.xs.last;
    double speedAt(double t) => (map.xAt(t + 1e-4) - map.xAt(t - 1e-4)) / 2e-4;
    final speed = speedAt(end - 1e-3);
    expect(speedAt(end + 1e-3), closeTo(speed, 0.01 * speed), reason: 'no jolt at the barline');
    for (var t = end; t < end + ScrollMap.settle; t += 0.05) {
      expect(speedAt(t + 0.05), lessThanOrEqualTo(speedAt(t) + 1e-6), reason: 'slowing at $t s');
    }
    final rest = map.xAt(end + ScrollMap.settle);
    expect(rest - last, closeTo(speed * ScrollMap.settle / 3, 1e-3 * speed), reason: 'a third of a slide at full speed');
    expect(map.xAt(end + 60), rest, reason: 'at rest');
  });

  test('a frame fades to paper over the last seconds before its end', () async {
    final scene = CuratedScene(score);
    addTearDown(scene.dispose);
    final c = Curation(score.metadata.parts.map((p) => p.id))
      ..setLane(score.metadata.parts.first.id, [Region(0, score.timeline.measureStarts.last)]);
    final end = CuratedScene.endOf(score.timeline);
    expect(end, closeTo(score.timeline.endSeconds + ScrollMap.settle + CuratedScene.fadeOut, 1e-9));
    Future<int> inked(double t) async {
      final image = scene.renderFrame(400, 300, time: t, curation: c, devicePixelRatio: 1, end: end);
      final pixels = (await image.toByteData())!;
      image.dispose();
      var n = 0;
      for (var i = 0; i < pixels.lengthInBytes; i += 4) {
        if (pixels.getUint8(i) < 250) n++;
      }
      return n;
    }

    final atRest = await inked(end - CuratedScene.fadeOut);
    expect(atRest, greaterThan(500), reason: 'the last bars, still shown');
    expect(await inked(end - CuratedScene.fadeOut / 2), lessThan(atRest));
    expect(await inked(end), 0, reason: 'only paper');
  });

  test('the scroll speed follows the notes, smoothly, even at one tempo', () {
    final map = score.scrollMap;
    final times = map.times, xs = map.xs;
    double speedAt(double t) => (map.xAt(t + 1e-4) - map.xAt(t - 1e-4)) / 2e-4;
    // Between two onsets the score keeps moving: never slower than a quarter of its mean
    // speed there, and never jolting (the speed has no steps).
    final means = <double>[];
    for (var k = 0; k + 1 < times.length; k++) {
      final mean = (xs[k + 1] - xs[k]) / (times[k + 1] - times[k]);
      means.add(mean);
      for (var f = 0.0; f <= 1; f += 0.1) {
        final t = times[k] + f * (times[k + 1] - times[k]);
        expect(speedAt(t), greaterThanOrEqualTo(0.25 * mean - 1e-6), reason: 'at $t s');
        expect((speedAt(t + 1e-3) - speedAt(t)).abs(), lessThan(0.02 * mean), reason: 'a jolt at $t s');
      }
    }
    // The score's own tempo throughout, yet the speed isn't one constant: long notes are
    // engraved closer than their length would say, so the score slows through them.
    means.sort();
    expect(means.last / means.first, greaterThan(1.5));
  });

  test('the scroll can glide from beat to beat, follow the notes, or anything between', () {
    final starts = score.timeline.measureStarts;
    final notes = ScrollMap(score.engraving, score.timeline, beats: score.beats);
    final beats = notes.withFollow(0), half = notes.withFollow(0.5);
    expect(notes.follow, 1);
    expect(notes.withFollow(1), same(notes));
    // Beats (as before 0.2): two anchors a bar in 6/8 (and the end), each beat on its notes.
    expect(beats.times, hasLength(44 * 2 + 1));
    final bar2 = score.engraving.measures[1];
    expect(beats.xAt(score.timeline.secondsAtQuarter(starts[1] + 1.5)), closeTo(bar2.onsetXs[bar2.onsetTimes.indexOf(1.5)], 0.5));
    // Every beat is on time whatever the blend; between them, the blend is the mean.
    for (final q in [starts[1], starts[1] + 1.5, starts[20]]) {
      final t = score.timeline.secondsAtQuarter(q);
      expect(half.xAt(t), closeTo(notes.xAt(t), 0.5));
      expect(half.xAt(t), closeTo(beats.xAt(t), 0.5));
    }
    double speedAt(ScrollMap m, double t) => (m.xAt(t + 1e-4) - m.xAt(t - 1e-4)) / 2e-4;
    double spread(ScrollMap m) {
      final speeds = [for (var t = 1.0; t < m.duration - 1; t += 0.05) speedAt(m, t)]..sort();
      return speeds[(speeds.length * 0.95).floor()] / speeds[(speeds.length * 0.05).floor()];
    }
    var previous = double.negativeInfinity;
    for (var t = -1.0; t < half.duration + 1; t += 0.01) {
      final x = half.xAt(t);
      expect(x, greaterThanOrEqualTo(previous - 1e-9), reason: 'ran back at $t s');
      expect(x, closeTo(0.5 * notes.xAt(t) + 0.5 * beats.xAt(t), 1e-6));
      previous = x;
    }
    // Following the notes changes the speed most; gliding by the beats least.
    expect(spread(beats), lessThan(spread(half)));
    expect(spread(half), lessThan(spread(notes)));
    expect(ScrollMap(score.engraving, score.timeline, beats: score.beats, follow: double.nan).follow, 1);
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

  test('an entrance glides over its region\'s own transition', () {
    final scene = CuratedScene(score);
    const size = ui.Size(1600, 900);
    final starts = score.timeline.measureStarts;
    Curation withPiccolo({double? transition}) {
      final c = Curation(score.metadata.parts.map((p) => p.id))..transition = 0.3;
      for (final p in score.metadata.parts.skip(16)) {
        c.setLane(p.id, [Region(0, starts.last)]);
      }
      return c..setLane('P1', [Region(starts[32], starts.last, transitionIn: transition)]);
    }

    final quick = withPiccolo(), slow = withPiccolo(transition: 2);
    final entrance = score.timeline.secondsAtQuarter(starts[32]);
    List<double> tops(Curation c, double t) => [for (final p in scene.layoutAt(t, c, size).placements) p.y];
    expect(tops(quick, entrance - 0.5), tops(quick, entrance - 3), reason: '0.3 s: still half a second before');
    expect(tops(slow, entrance - 0.5), isNot(tops(slow, entrance - 3)), reason: '2 s: already making room');
    expect(tops(slow, entrance + 0.5), isNot(tops(slow, entrance + 1.1)), reason: 'still gliding');
    expect(tops(slow, entrance + 1.1), tops(slow, entrance + 3), reason: 'settled a second after');
    expect(slow.visibilityAt(entrance - 0.5, scene.timeline)['P1'], greaterThan(0));
    expect(quick.visibilityAt(entrance - 0.5, scene.timeline)['P1'], 0);
    scene.dispose();
  });

  test('hidden instruments never influence the spacing of the shown ones', () {
    final scene = CuratedScene(score);
    const size = ui.Size(1600, 900);
    final end = score.timeline.measureStarts.last;
    Curation strings() {
      final c = Curation(score.metadata.parts.map((p) => p.id));
      for (final p in score.metadata.parts.skip(16)) {
        c.setLane(p.id, [Region(0, end)]);
      }
      return c;
    }

    // The piccolo (a high, ledger-line-heavy part) is shown only from bar 33; in the other
    // curation the timpani enters there instead, so both split the piece at the same moment
    // (each stretch between entrances is spaced for its own tallest ink).
    final bar33 = score.timeline.measureStarts[32];
    final withPiccolo = strings()..setLane('P1', [Region(bar33, end)]);
    final withTimpani = strings()..setLane('P14', [Region(bar33, end)]);
    final entrance = score.timeline.secondsAtQuarter(bar33);
    List<double> tops(Curation c, double t) => [for (final p in scene.layoutAt(t, c, size).placements) p.y];

    // While hidden, the piccolo's dense part changes nothing: the strings sit exactly where
    // they do with the sparse timpani waiting instead.
    for (final t in [10.0, 30.0, entrance - 5]) {
      expect(tops(withPiccolo, t), tops(withTimpani, t));
    }
    // Once it has entered, the strings make room for it.
    expect(tops(withPiccolo, entrance + 10).skip(1).toList(), isNot(tops(strings(), entrance + 10)));
    scene.dispose();
  });

  test('an instrument on several staves moves as one: they stay as far apart as engraved, cross-staff notes and all', () async {
    final piano = await LoadedScore.load(flutePianoScore);
    final scene = CuratedScene(piano);
    const size = ui.Size(1200, 700);
    final end = piano.timeline.measureStarts.last;
    final [right, left] = [for (final s in scene.display.staves) if (s.info.n >= 2) s];
    final engraved = (left.info.top - right.info.top) * scene.renderer.scale;
    // The right hand's ink reaches down into the left hand's staff: a staff spaced on its own
    // would push the left hand away from the note written on it.
    expect(right.maxInk(0, 1e9).below + right.info.top + right.info.height, greaterThan(left.info.top + left.info.height));

    final c = Curation(piano.metadata.parts.map((p) => p.id))
      ..setLane('P2', [Region(0, end)])
      ..setLane('P1', [Region(piano.timeline.measureStarts[1], end)]); // the flute enters at bar 2
    for (final t in [0.5, piano.timeline.secondsAtQuarter(piano.timeline.measureStarts[1]), 7.0]) {
      final tops = {for (final p in scene.layoutAt(t, c, size).placements) p.staffIndex: p.y};
      final [rh, lh] = [for (final s in [right, left]) tops[scene.display.staves.indexOf(s)]!];
      expect(lh - rh, closeTo(engraved, 1e-6), reason: 'at $t s');
    }

    // Its barlines run on between its staves, but not up to the flute's: the first, just
    // before it reaches the pointer.
    final t = piano.timeline.secondsAtQuarter(piano.timeline.measureStarts[1]) - 0.5;
    c.setLane('P1', [Region(0, end)]);
    final image = scene.renderFrame(size.width.toInt(), size.height.toInt(), time: t, curation: c, devicePixelRatio: 1);
    final pixels = (await image.toByteData())!;
    final tops = {for (final p in scene.layoutAt(t, c, size).placements) scene.display.staves[p.staffIndex].info.n: p.y};
    final s = scene.renderer.scale, staffHeight = right.info.height * s;
    final barX = scene.display.barlines.items.map((b) => b.bounds.center.dx).reduce((a, b) => a < b ? a : b);
    final x = (scene.renderer.pointerX(size.width) + (barX - scene.scrollMap.xAt(t)) * s).round();
    bool inked(double y) => [x - 1, x, x + 1].any((x) => pixels.getUint8((y.round() * size.width.toInt() + x) * 4) < 128);
    expect(inked((tops[2]! + staffHeight + tops[3]!) / 2), isTrue, reason: 'between the hands');
    expect(inked((tops[1]! + staffHeight + tops[2]!) / 2), isFalse, reason: 'between the flute and the piano');
    image.dispose();
    scene.dispose();
  });

  test('instruments can be stacked in any order: Violin I on top, the rest as in the score', () {
    final scene = CuratedScene(score);
    const size = ui.Size(1600, 900);
    final end = score.timeline.measureStarts.last;
    final curation = Curation(score.metadata.parts.map((p) => p.id));
    for (final id in ['P1', 'P2', 'P17', 'P21']) {
      curation.setLane(id, [Region(0, end)]); // piccolo, flute 1, violin I, double bass
    }
    List<String> stacked() {
      final labels = scene.layoutAt(10, curation, size).labels.toList()..sort((a, b) => a.centerY.compareTo(b.centerY));
      return [for (final l in labels) l.partId];
    }

    expect(stacked(), ['P1', 'P2', 'P17', 'P21']);
    scene.partOrder = ['P17', 'nobody']; // unknown ids are dropped, missing ones follow in score order
    expect(scene.partOrder, ['P17', for (final p in score.metadata.parts) if (p.id != 'P17') p.id]);
    expect(stacked(), ['P17', 'P1', 'P2', 'P21']);
    final placements = scene.layoutAt(10, curation, size).placements;
    expect(placements.first.staffIndex, score.engraving.staves.indexWhere((s) => s.n == 17));
    expect(placements.first.y, lessThan(placements[1].y));
    scene.dispose();
  });

  test('the colours are chosen when drawing: dark paper and light ink, no re-rasterising', () async {
    final scene = CuratedScene(score);
    const size = ui.Size(800, 400);
    final curation = Curation(score.metadata.parts.map((p) => p.id));
    curation.setLane(score.metadata.parts.last.id, [Region(0, score.timeline.measureStarts.last)]);
    const paper = ui.Color(0xFF101010), ink = ui.Color(0xFFF0F0F0);

    Future<Set<int>> colours({ui.Color? paper, ui.Color? ink}) async {
      final recorder = ui.PictureRecorder();
      scene.paint(ui.Canvas(recorder), size, time: 30, curation: curation, devicePixelRatio: 1, paper: paper, ink: ink);
      final image = recorder.endRecording().toImageSync(800, 400);
      final bytes = (await image.toByteData())!;
      return {for (var i = 0; i < bytes.lengthInBytes; i += 4) bytes.getUint32(i)}; // RGBA
    }

    final light = await colours();
    expect(light, contains(0xFFFFFFFF), reason: 'white paper by default');
    final dark = await colours(paper: paper, ink: ink);
    expect(dark, contains(0x101010FF), reason: 'dark paper');
    expect(dark, contains(0xF0F0F0FF), reason: 'light ink, full strength in solid strokes');
    expect(dark.where((c) => c == 0xFFFFFFFF || (c >> 8) == 0x14171A), isEmpty, reason: 'nothing left in the light colours');
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

  test('renders a frame (set SCORE_SNAPSHOT_DIR to save it)', () async {
    final scene = CuratedScene(score);
    const size = ui.Size(1600, 900);
    const dpr = 2.0;
    final curation = Curation(score.metadata.parts.map((p) => p.id));
    for (final p in score.metadata.parts) {
      curation.setLane(p.id, [Region(0, score.timeline.measureStarts.last)]);
    }

    final stopwatch = Stopwatch()..start();
    late ui.Image image;
    for (var frame = 0; frame < 30; frame++) {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder)..scale(dpr);
      scene.paint(canvas, size, time: 60 + frame / 60, curation: curation, devicePixelRatio: dpr);
      final picture = recorder.endRecording();
      if (frame == 0) image = picture.toImageSync((size.width * dpr).round(), (size.height * dpr).round());
      picture.dispose();
    }
    // ignore: avoid_print
    print('30 frames recorded in ${stopwatch.elapsedMilliseconds} ms (first frame includes tile rasterising)');

    final dir = Platform.environment['SCORE_SNAPSHOT_DIR'];
    if (dir != null) {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$dir/flutter-frame.png').writeAsBytesSync(png!.buffer.asUint8List());
    }
    scene.dispose();
  });
}
