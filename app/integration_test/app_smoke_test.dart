// The built app, run as a user gets it (`make smoke`, or `flutter test integration_test -d macos`
// / `-d windows` in app/): the engine's library and Verovio's resources are found inside the
// app's own bundle, the sample opens with its recording, engraves, draws, engraves again in
// another music font, and (where FFmpeg is installed) exports a second of video.
import 'dart:io';

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/media_converter.dart';
import 'package:curated_score/scratch_space.dart';
import 'package:curated_score/video_export.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:score_engine/score_engine.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the built app opens the sample, engraves, draws and exports it', (tester) async {
    FontResources.workDirectory = ScratchSpace.folder('fonts').path; // as main() sets it
    addTearDown(ScratchSpace.close);

    // Verovio's metrics come from the bundle, not from a source tree beside it.
    final resources = engineResourceDirectory();
    expect(resources, contains('flutter_assets'));
    expect(File('$resources/Bravura.xml').existsSync(), isTrue, reason: resources);

    await tester.pumpWidget(CuratedScoreApp(settings: AppSettings.memory()));
    await tester.pump(const Duration(seconds: 1));
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    Future<void> waitFor(bool Function() done, String what) async {
      for (var i = 0; i < 600 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
      expect(done(), isTrue, reason: what);
    }

    await tester.tap(find.text('Try the sample'));
    await waitFor(() => c.score != null && !c.isLoadingAudio, 'the sample opens');
    expect(c.score!.engraving.measures, hasLength(44));
    expect(c.score!.warnings, isEmpty);
    expect(c.track, isNotNull, reason: 'its recording plays here');

    // A frame: paper with ink on it.
    final image = c.scene!.renderFrame(640, 360, time: 30, curation: c.curation!, devicePixelRatio: 360 / 540);
    final pixels = (await image.toByteData())!;
    image.dispose();
    var inked = 0;
    for (var i = 0; i < pixels.lengthInBytes; i += 4) {
      if (pixels.getUint8(i) < 128) inked++;
    }
    expect(inked, greaterThan(500));

    // Another music font: its metrics read from the bundle, engraved again.
    await c.setFonts(const ScoreFonts(music: MusicFont.leland));
    await waitFor(() => !c.isReengraving, 'engraved again');
    expect(c.score!.fonts.music, MusicFont.leland);

    // A second of video, where this machine has FFmpeg.
    if (MediaConverter.findFfmpeg() == null) return;
    final dir = Directory.systemTemp.createTempSync('curator-smoke-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final export = VideoExport.of(c);
    addTearDown(export.dispose);
    final out = '${dir.path}/smoke.mp4';
    await export.write(out, format: const VideoFormat(width: 320, height: 180, fps: 10), to: 1);
    expect(File(out).lengthSync(), greaterThan(1000));
  });
}
