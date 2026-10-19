import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_score.dart';

void main() {
  test('a staff line keeps its weight through the fade into the frozen zone, light ink on dark paper', () async {
    final bytes = await File('assets/fonts/Bravura.otf').readAsBytes();
    await (FontLoader('packages/score_engine/Bravura')..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    final score = await LoadedScore.load(demoScore());
    final curation = Curation(score.metadata.parts.map((p) => p.id));
    for (final p in score.metadata.parts) {
      curation.setLane(p.id, [Region(0, score.timeline.measureStarts.last)]);
    }
    final scene = CuratedScene(score);
    addTearDown(scene.dispose);
    const width = 1280, height = 720, time = 30.0;
    const size = ui.Size(1280, 720);
    final image = scene.renderFrame(width, height,
        time: time,
        curation: curation,
        devicePixelRatio: 1,
        paper: const ui.Color(0xFF1B1C1F),
        ink: const ui.Color(0xFFE6E6E6));
    final pixels = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
    image.dispose();
    int at(int x, int y) => pixels[(y * width + x) * 4];
    const paper = 0x1B;
    // A row's pixels from x0 to x1 where nothing crosses it (paper just above and below).
    List<int> bare(int y, int x0, int x1) =>
        [for (var x = x0; x < x1; x++) if (at(x, y - 3) == paper && at(x, y + 3) == paper) at(x, y)];

    final musicLeft = scene.renderer.musicLeftFor(scene.keyColumnAt(time, curation, size)).round();
    const fade = 24;
    final placements = scene.layoutAt(time, curation, size).placements;
    var checked = 0;
    for (final placement in placements.where((p) => p.y > 10 && p.y < height - 60).take(6)) {
      final staff = scene.display.staves[placement.staffIndex];
      if (staff.info.lines != 5) continue;
      final top = placement.y.round();
      for (var y = top - 2; y <= top + 2; y++) {
        final zone = bare(y, musicLeft - 30, musicLeft - 5);
        if (zone.isEmpty || zone.first == paper) continue; // a row the line doesn't cross
        final stretches = [('the fade', musicLeft, musicLeft + fade), ('the music', musicLeft + fade, musicLeft + fade + 40)];
        for (final (where, x0, x1) in stretches) {
          for (final value in bare(y, x0, x1)) {
            expect(value, closeTo(zone.first, 2), reason: 'staff ${staff.info.n}, row $y: $where against the zone');
            checked++;
          }
        }
      }
    }
    expect(checked, greaterThan(100), reason: 'pixels on the top lines');
  });
}
