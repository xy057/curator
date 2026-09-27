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

  test('scroll map puts each beat under the pointer and never runs backwards', () {
    final map = score.scrollMap;
    expect(map.duration, closeTo(44 * 3 * 60 / 93, 1e-6)); // 44 bars of 6/8 at ♩ = 93
    expect(map.xAt(score.timeline.secondsAtQuarter(3)), closeTo(score.engraving.measures[1].onsetXs.first, 0.5));
    // 6/8 beats in dotted crotchets: two anchors a bar (and the end), each on its notes.
    expect(map.times, hasLength(44 * 2 + 1));
    final bar2 = score.engraving.measures[1];
    expect(map.xAt(score.timeline.secondsAtQuarter(4.5)), closeTo(bar2.onsetXs[bar2.onsetTimes.indexOf(1.5)], 0.5));
    var previous = double.negativeInfinity;
    for (var t = -2.0; t < map.duration + 2; t += 0.01) {
      final x = map.xAt(t);
      expect(x, greaterThanOrEqualTo(previous - 1e-9));
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
