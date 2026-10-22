// At the window's minimum size (WindowChrome.minimumSize, which the runners set natively)
// nothing overflows, in either tab, with the selection-only buttons and every extension showing.

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/audio_track.dart';
import 'package:curated_score/caption_lane.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/window_chrome.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';

void main() {
  testWidgets('the editor fits the minimum window size', (tester) async {
    tester.view.physicalSize = WindowChrome.minimumSize * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(CuratedScoreApp(settings: AppSettings.memory()));
    await tester.pump(const Duration(seconds: 1));
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    await tester.tap(find.text('Open Sample'));
    for (var i = 0; i < 300 && c.score == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 500));

    // Every extension on: Attach Image's toolbar buttons and the pinned Captions lane.
    c.setExtensions({'attachImage': true, 'captions': true});
    final bar = c.score!.timeline.measureStarts;
    c.captions.add(Caption(bar[0], bar[4], 'A caption long enough to need more room than its lane has'));
    c.lanes.selectAll(); // trim / remove buttons and the selection summary
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(CaptionLane), findsOneWidget);
    expect(find.byTooltip('Manage assets…'), findsOneWidget);

    final recording = await tester.runAsync(demoWaveform);
    if (recording != null) {
      c.audio.debugTrack = AudioTrack.forTesting(name: 'a long recording name.flac', length: recording.length, waveform: recording.waveform);
    }
    c.tab = BottomTab.audio;
    c.anchors.tapArmed = true;
    c.anchors.selectAll(); // the anchor count chip
    await tester.pump(const Duration(milliseconds: 400));
    c.anchors.tapArmed = false;
    await tester.pump(const Duration(milliseconds: 400));
    // Any overflow fails the test with its report.
  });
}
