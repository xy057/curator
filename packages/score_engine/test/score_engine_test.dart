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
    expect(score.metadata.barNumbers, [for (var m = 1; m <= 44; m++) '$m']);
    // Numbered as printed: no number on an upbeat or a split bar's second half.
    final measures = ['number="0" implicit="yes"', 'number="1"', 'number="2"', 'number="2" implicit="yes"', 'number="3" text="3a"', ''];
    final xml = '<score-partwise><part-list><score-part id="P1"><part-name>A</part-name></score-part></part-list>'
        '<part id="P1">${measures.map((m) => '<measure $m/>').join()}</part></score-partwise>';
    expect(ScoreMetadata.read(xml).barNumbers, [null, '1', '2', null, '3a', '4']);
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

    // After the final barline it comes to rest over the settle: by default a third as far as it
    // would go at its last speed; a linear curve keeps that speed all the way, then stops.
    final end = map.duration, v = (map.xAt(end) - map.xAt(end - 1e-3)) / 1e-3;
    expect(map.xAt(end + 10) - map.xAt(end), closeTo(v * 2.5 / 3, 0.05));
    final linear = map.withMotion(const ScoreMotion(settle: 1, settleCurve: MotionCurve.linear));
    expect(linear.xAt(end + 0.5) - linear.xAt(end), closeTo(v * 0.5, 0.05));
    expect(linear.xAt(end + 10) - linear.xAt(end), closeTo(v, 0.05));
    expect(linear.xAt(2), map.xAt(2), reason: 'only the ending moves differently');
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
