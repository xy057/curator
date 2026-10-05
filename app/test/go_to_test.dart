// Go to: the toolbar's readout typed (a click on it, or ⌘G) moves the playhead to a bar or a time.
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_project.dart';

void main() {
  test('a bar is where it first sounds; a time is read as m:ss or h:mm:ss', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final c = EditorController(vsync: const TestVSync());
    addTearDown(c.dispose);
    expect(c.playback.secondsOf('12'), isNull, reason: 'no score');
    await c.openFile(demoScore.path);
    final p = c.playback;
    final bar12 = c.timeline.secondsAtQuarter(c.beats.parse('12')!);
    expect(p.secondsOf('12'), closeTo(bar12, 1e-9));
    expect(p.secondsOf(' 12.2 '), closeTo(c.timeline.secondsAtQuarter(c.beats.parse('12.2')!), 1e-9));
    expect(p.secondsOf('12.3'), isNull, reason: '6/8 beats twice a bar');
    expect(p.secondsOf('1:10.5'), 70.5);
    expect(p.secondsOf('0:05'), 5);
    expect(p.secondsOf('1:00:05'), 3605);
    for (final bad in ['', 'x', '1:60', '1:60:00', '12a', ':5']) {
      expect(p.secondsOf(bad), isNull, reason: bad);
    }

    expect(p.goTo('20'), isTrue);
    expect(p.time.value, closeTo(p.secondsOf('20')!, 1e-9));
    expect(p.goTo('nope'), isFalse);
    expect(p.time.value, closeTo(p.secondsOf('20')!, 1e-9), reason: 'a bad entry stays put');
    p.goTo('99:00');
    expect(p.time.value, p.duration, reason: 'past the end is the end');
  });

  testWidgets('the readout types where to go: a click or ⌘G, Enter goes, Escape cancels', (tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CuratedScoreApp(settings: AppSettings.memory()));
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScore.path));
    await tester.pump();
    final field = find.byType(TextField);

    // A click on the bar: it is typed over, and Enter goes there.
    await tester.tap(find.text('1.1'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, '1.1');
    await tester.enterText(field, '20');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(field, findsNothing);
    expect(c.playback.time.value, closeTo(c.playback.secondsOf('20')!, 1e-9));
    expect(find.text('20.1'), findsOneWidget);

    // A wrong entry keeps the field open.
    await tester.tap(find.text('20.1'));
    await tester.pumpAndSettle();
    await tester.enterText(field, 'bar 3');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(field, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(field, findsNothing);

    // ⌘G, then a time.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(field, findsOneWidget);
    await tester.enterText(field, '0:30');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(c.playback.time.value, 30);

    // Space plays again once it is closed.
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(c.playback.isPlaying, isTrue);
    c.playback.pause();
  });

  testWidgets('after Starts at is typed, the keyboard goes back to what had it: Space plays', (tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final settings = AppSettings.memory()..addRecent(demoProject.absolute.path);
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Try the sample'));
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    for (var i = 0; i < 100 && c.score == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.graphic_eq_rounded));
    await tester.pumpAndSettle();

    final field = find.descendant(of: find.byTooltip('Silence before bar 1 (s)'), matching: find.byType(TextField));
    await tester.tap(field);
    await tester.pumpAndSettle();
    await tester.enterText(field, '1.5');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(c.sync!.startSeconds, 1.5);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(c.playback.isPlaying, isTrue);
    c.playback.pause();
  });
}
