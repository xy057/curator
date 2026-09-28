// The toolbar's ratio menu: a preset, or Custom… (any ratio, typed); choosing one shows the
// video's frame at it, and Export Video uses it.
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/video_export.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_project.dart';

void main() {
  testWidgets('the toolbar picks the video ratio: a preset, or any typed', (tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final settings = AppSettings.memory();
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScore.path));
    await tester.pump();
    expect(settings.previewVideoFrame, isFalse);

    Future<void> menu(String item) async {
      await tester.tap(find.byTooltip('Video ratio'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(item).last);
      await tester.pumpAndSettle();
    }

    // A preset: chosen, and shown (the frame turns on).
    await menu('9:16');
    expect(settings.videoRatio, const VideoRatio(9, 16));
    expect(settings.previewVideoFrame, isTrue);
    expect(find.text('9:16'), findsOneWidget, reason: 'the button names it');

    // Custom…: a bad entry keeps Set off; a good one is chosen, tidied to the ratio it means.
    await menu('Custom…');
    expect(find.text('Video Ratio'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '9:1');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Set')).onPressed, isNull,
        reason: 'wider than 4:1');
    await tester.enterText(find.byType(TextField), '2.39');
    await tester.pump();
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();
    expect(settings.videoRatio, const VideoRatio(2.39, 1));
    expect(find.text('2.39:1'), findsOneWidget);

    // The menu then offers it again as the custom one; Enter sets what was typed.
    await menu('Custom (2.39:1)…');
    await tester.enterText(find.byType(TextField), '1080x1350');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(settings.videoRatio, const VideoRatio(4, 5));
    await menu('Custom (4:5)…');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(settings.videoRatio, const VideoRatio(4, 5), reason: 'cancelling keeps it');
    await menu('21:9');

    // The export uses it.
    expect((settings.videoFormat.width, settings.videoFormat.height), (2520, 1080));
  });
}
