// The playhead is a layer of its own: playback moves it every frame without repainting the
// lanes, the ruler or the audio lanes under it.
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_project.dart';

void main() {
  testWidgets('a new time repaints the playhead, not the lanes', (tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CuratedScoreApp(settings: AppSettings.memory()));
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScore.path));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    Iterable<RenderCustomPaint> painted(String painter) => find
        .byWidgetPredicate((w) => w is CustomPaint && w.painter.runtimeType.toString() == painter)
        .evaluate()
        .map((e) => e.renderObject! as RenderCustomPaint);

    Future<void> check(List<String> lanes) async {
      await tester.pump();
      for (final name in lanes) {
        expect(painted(name), isNotEmpty, reason: name);
      }
      c.playback.seek(c.playback.time.value + 3);
      for (final name in lanes) {
        for (final r in painted(name)) {
          expect(r.debugNeedsPaint, isFalse, reason: '$name repainted for the time');
        }
      }
      expect(painted('_PlayheadPainter').where((r) => r.debugNeedsPaint), isNotEmpty);
    }

    await check(['_LanesPainter', '_RulerPainter']);
    c.tab = BottomTab.audio;
    await tester.pumpAndSettle();
    await check(['_AnchorPainter', '_WaveformPainter', '_TempoPainter', '_RulerPainter']);
  });

  testWidgets('scrubbing while playing holds the music at the pointer and goes on from where it is let go', (tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CuratedScoreApp(settings: AppSettings.memory()));
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScore.path));
    await tester.pump(const Duration(milliseconds: 200));
    final p = c.playback..play();
    await tester.pump(const Duration(milliseconds: 100));
    p.scrub(10);
    p.scrub(12);
    // The clock is real time (a Stopwatch), not the test's.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump(const Duration(milliseconds: 16));
    expect(p.time.value, 12, reason: 'held where the pointer is');
    expect(p.isPlaying, isTrue);
    p.endScrub();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump(const Duration(milliseconds: 16));
    expect(p.time.value, greaterThan(12.1), reason: 'goes on from there');
    p.pause();
  });
}

