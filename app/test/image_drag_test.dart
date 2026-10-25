import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/image_patch.dart';
import 'package:curated_score/score_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_project.dart';
import 'image_patch_test.dart' show greyPng;

void main() {
  testWidgets('cropping, an image dragged by its middle moves over the image, never off it', (tester) async {
    final c = EditorController(vsync: const TestVSync());
    addTearDown(c.dispose);
    await tester.runAsync(() => c.openFile(demoScore.path));
    c.setExtension('attachImage', true);
    await tester.runAsync(() => c.images.add(ImageKind.raster, greyPng(40, 20), quarter: 4, top: 4, extension: 'png'));
    tester.view
      ..physicalSize = const Size(1000, 500)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ScoreView(controller: c))));

    Rect shown() {
      final p = c.images.patches.single;
      return c.scene!.patchRect(p.scene(c.images.artOf(p)!), c.playback.time.value, const Size(1000, 500));
    }

    // Cropped to its left half, then that half dragged far right and far down.
    c.images.update(0, c.images.patches.single.copyWith(crop: const Rect.fromLTRB(0, 0, 0.5, 1)));
    c.images.select(0, crop: true);
    await tester.pump();
    final before = shown();
    final drag = await tester.startGesture(before.center);
    for (var i = 0; i < 4; i++) {
      await drag.moveBy(const Offset(400, 200));
      await tester.pump();
    }
    await drag.up();
    await tester.pump();

    final patch = c.images.patches.single;
    expect(patch.crop.left, closeTo(0.5, 1e-6)); // its right half: as far as it goes
    expect(patch.crop.right, closeTo(1, 1e-6));
    expect(patch.crop.top, closeTo(0, 1e-6)); // all of its height already
    expect(patch.crop.bottom, closeTo(1, 1e-6));
    expect(shown().left, closeTo(before.right, 0.01));
    expect(shown().size.width, closeTo(before.size.width, 0.01));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 1));
  });
}
