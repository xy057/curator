// A video frame is the preview's frame: everything the editor's scene draws is copied into
// the export (VideoExport.of), so the same time paints the same pixels in both.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/image_patch.dart';
import 'package:curated_score/video_export.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';
import 'image_patch_test.dart' show png;
import 'test_fonts.dart';

void main() {
  testWidgets('every frame of a video is the preview\'s, with every kind of edit made', (tester) async {
    await tester.runAsync(loadTestFonts);
    final c = EditorController(vsync: const TestVSync());
    addTearDown(c.dispose);
    await tester.runAsync(() => c.openFile(demoScore.path));
    final starts = c.score!.timeline.measureStarts;
    final parts = c.score!.metadata.parts;

    // Everything that changes the picture, each away from its default.
    c.images.enabled = true;
    c.captions.enabled = true;
    await tester.runAsync(() => c.images.add(ImageKind.raster, png, quarter: starts[2], top: 2));
    c.images.update(0, c.images.patches[0].copyWith(ink: true));
    c.captions.add(Caption(starts[1], starts[6], 'The horns answer'));
    c.captions.configure(
        font: '', position: CaptionPosition.top, countdown: CaptionCountdown.ring, size: CaptionSize.large);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50))); // the style is applied
    c.renamePart(parts.last, name: 'Basses', abbreviation: 'Cb.');
    c.setStaffSpace(9);
    c.scrollFollow = 0.8;
    c.setCondensed(['cond-P2-P3'], on: true);
    c.moveLane('P17', 0);
    c.curation!.transition = 0.7;
    c.curation!.setLane('P1', [Region(starts[3], starts[9], transitionIn: 2, transitionOut: 0.2)]);
    c.beginEdit();
    c.sync!.load([for (var bar = 0; bar <= 20; bar++) SyncAnchor(starts[bar], 1.0 + bar * 2)]);
    c.anchors.setAnchor(12, starts[12], jumpTo: starts[4]); // after bar 12, back to bar 5
    c.endEdit();
    expect(c.scene!.captions, isNotEmpty);
    expect(c.scene!.captionStyle.countdown, CaptionCountdown.ring);

    final export = VideoExport.of(c);
    addTearDown(export.dispose);
    const size = ui.Size(960, 540); // VideoFormat.layoutShortSide points high: drawn at 1:1
    final paper = VideoPaper.light;

    Future<Uint8List> pixels(void Function(ui.Canvas canvas) paint) async {
      final recorder = ui.PictureRecorder();
      paint(ui.Canvas(recorder));
      final image = recorder.endRecording().toImageSync(size.width.toInt(), size.height.toInt());
      final bytes = (await tester.runAsync(() => image.toByteData()))!;
      image.dispose();
      return bytes.buffer.asUint8List();
    }

    final passes = c.timeline.passes;
    final times = [
      0.5,
      c.timeline.secondsAtQuarter(starts[2]) + 0.3, // the image, a caption fading in
      c.timeline.secondsAtQuarter(starts[3]) - 0.5, // the piccolo gliding in over its own 2 s
      c.timeline.secondsAtQuarter(starts[6], pass: 1) - 0.4, // a caption running out, second time round
      c.timeline.secondsAtQuarter(starts[12], pass: 0) - 0.05, // just before the warp
      c.playback.duration - CuratedScene.fadeOut / 2, // fading to paper
    ];
    expect(passes, hasLength(2));
    for (final t in times) {
      final preview = await pixels((canvas) => c.scene!.paint(canvas, size,
          time: t,
          curation: c.curation!,
          devicePixelRatio: 1,
          end: c.playback.duration,
          paper: paper.paper,
          ink: paper.ink));
      final video = await pixels((canvas) => export.paintPreview(canvas, size, time: t, paper: paper, devicePixelRatio: 1));
      expect(video, preview, reason: 'at $t s');
      final colours = {for (var i = 0; i < preview.length; i += 4) ByteData.sublistView(preview).getUint32(i)};
      expect(colours.length, greaterThan(1), reason: 'not only paper at $t s');
    }
  });
}
