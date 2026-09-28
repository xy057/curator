// The first frame of a piece: the frozen zone's staff lines run on to where the music begins
// (no blank gap), and the scrolling staff lines are as crisp as the zone's.
import 'dart:ui' as ui;

import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/score_view.dart';
import 'package:curated_score/video_export.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('at the start the staff lines run unbroken from the frozen zone to the music', (tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const CuratedScoreApp());
    await tester.pump(const Duration(seconds: 1));
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    await tester.tap(find.text('Try the sample'));
    for (var i = 0; i < 300 && c.score == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 600));
    c.playback.seek(0);
    await tester.pump(const Duration(milliseconds: 50));

    final renderer = c.scene!.renderer;
    // The score is laid out like the video and scaled into the view (VideoFrame).
    final frame = VideoFrame.fit(tester.getSize(find.byType(ScoreView)), VideoResolution.hd1080.aspectRatio,
        devicePixelRatio: 2);
    final width = frame.layout.width;
    final zoneRight = renderer.musicLeft;
    final musicStart = renderer.pointerX(width) +
        (c.score!.engraving.measures.first.left - c.scene!.scrollMap.xAt(0)) * renderer.scale;
    expect(musicStart, greaterThan(zoneRight + 40), reason: 'the piece starts right of the zone');

    final pixels = await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.descendant(of: find.byType(ScoreView), matching: find.byType(RepaintBoundary)).first);
      final image = await boundary.toImage(pixelRatio: 2);
      return (image: image, bytes: (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!);
    });
    final image = pixels!.image;
    List<int> inkRows(double x) => [
          for (var y = 0; y < image.height; y++)
            if (pixels.bytes.getUint8((y * image.width + (x * frame.scale * 2).round()) * 4) < 160) y,
        ];

    final inZone = inkRows(zoneRight - 4);
    final inGap = inkRows((zoneRight + musicStart) / 2);
    final inMusic = inkRows(musicStart + 4);
    expect(inZone, isNotEmpty);
    expect(inGap, inZone); // the lines carry on through what used to be a blank gap…
    expect(inMusic, containsAll(inZone)); // …and meet the scrolling staff's lines, pixel for pixel

    // The toolbar counts bar.beat the way the 6/8 beats: two dotted crotchets a bar.
    expect(find.text('1.1'), findsOneWidget);
    c.playback.seek(c.timeline.secondsAtQuarter(c.beats.quarterAt(1, 1)! + 0.1));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('2.2'), findsOneWidget);
  });
}
