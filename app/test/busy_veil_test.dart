// The veil shown while a score is engraved fades out as it fades in, then lets go of its spinner.
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_project.dart';

void main() {
  testWidgets('the Engraving… veil fades out, then is gone', (tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CuratedScoreApp(settings: AppSettings.memory()));
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    late Future<void> opening;
    await tester.runAsync(() {
      opening = c.openFile(demoScore.path); // started in real time, not awaited
      return Future<void>.value();
    });
    var seen = false;
    for (var i = 0; i < 300 && c.score == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      seen |= find.text('Engraving…').evaluate().isNotEmpty;
    }
    await tester.runAsync(() => opening);
    expect(seen, isTrue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Engraving…'), findsOneWidget, reason: 'still fading out');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.text('Engraving…'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing, reason: 'no spinner turning unseen');
  });
}
