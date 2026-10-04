import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';
import 'package:score_engine/src/score_renderer.dart' show ScoreRenderer;

import 'demo_score.dart';

void main() {
  late LoadedScore score;
  late Curation curation;
  const size = ui.Size(1600, 900), dpr = 2.0;

  setUpAll(() async {
    final bytes = await File('assets/fonts/Bravura.otf').readAsBytes();
    await (FontLoader('packages/score_engine/Bravura')..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    score = await LoadedScore.load(demoScore());
    curation = Curation(score.metadata.parts.map((p) => p.id));
    for (final p in score.metadata.parts) {
      curation.setLane(p.id, [Region(0, score.timeline.measureStarts.last)]); // every staff
    }
  });

  Future<List<int>> frame(CuratedScene scene, double time) async {
    final image = scene.renderFrame(1600 * 2, 900 * 2, time: time, curation: curation, devicePixelRatio: dpr);
    final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return pixels!.buffer.asUint8List();
  }

  test('the tile cache stays within its bytes through the whole piece', () {
    final scene = CuratedScene(score);
    addTearDown(scene.dispose);
    var most = 0;
    for (var t = 0.0; t < score.duration; t += 0.25) {
      final recorder = ui.PictureRecorder();
      scene.paint(ui.Canvas(recorder), size, time: t, curation: curation, devicePixelRatio: dpr);
      recorder.endRecording().dispose();
      expect(scene.renderer.tileBytes, lessThanOrEqualTo(scene.renderer.maxTileBytes), reason: 'at $t s');
      if (scene.renderer.tileBytes > most) most = scene.renderer.tileBytes;
    }
    expect(most, greaterThan(scene.renderer.maxTileBytes ~/ 2), reason: 'the demo fills it: the limit is what held it');
  });

  test('a frame needing more than the cache holds still draws whole, and keeps only its own tiles', () async {
    final roomy = CuratedScene(score), tight = CuratedScene(score);
    addTearDown(roomy.dispose);
    addTearDown(tight.dispose);
    tight.renderer.dispose();
    tight.renderer = ScoreRenderer(tight.display, tight.style,
        frozen: FrozenZone(score.engraving, tight.style), barlinesThrough: tight.renderer.barlinesThrough, maxTileBytes: 1);
    for (final t in [10.0, 60.0]) {
      expect(await frame(tight, t), await frame(roomy, t), reason: 'the same frame at $t s');
    }
    expect(tight.renderer.tileBytes, greaterThan(0));
    expect(tight.renderer.tileBytes, lessThan(roomy.renderer.tileBytes), reason: "the first frame's tiles are gone");
  });
}
