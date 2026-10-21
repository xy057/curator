
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/extensions/extension.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/project_state.dart';
import 'package:curated_score/score_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'test_fonts.dart';
import 'finders.dart';
import 'window.dart';

void main() {
  testWidgets('Captions: added from the score\'s menu, shown in the bar, edited, undone and saved', (tester) async {
    await tester.runAsync(loadTestFonts);
    desktopWindow(tester);
    final settings = AppSettings.memory();
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Open Sample'));
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    for (var i = 0; i < 100 && c.score == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 500));
    final view = tester.getRect(find.byType(ScoreView));
    final spot = view.center + const Offset(0, -60);

    Future<void> rightClick(Offset at) async {
      await tester.tapAt(at, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
    }

    await rightClick(spot);
    expect(find.text('Add Caption…'), findsNothing, reason: 'Captions is off');

    c.setExtension('captions', true); // the project's
    await tester.pump();
    await rightClick(spot);
    expect(find.text('Add Caption…'), findsOneWidget);
    expect(find.text('Add Image…'), findsNothing, reason: 'Attach Image is still off');
    await tester.tap(find.text('Add Caption…'));
    await tester.pumpAndSettle();
    expect(find.text('Add Caption'), findsOneWidget);
    await tester.enterText(appField('Text'), 'The horns answer, softly');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    final caption = c.captions.captions.single;
    expect(caption.text, 'The horns answer, softly');
    expect(caption.end, greaterThan(caption.start));
    expect(c.canUndo, isTrue);

    // Half-way through it shows, with its time half run out.
    final span = captionSpans(c.captions.captions, c.timeline).first;
    c.playback.seek((span.start + span.end) / 2);
    await tester.pump();
    expect(c.captions.at(c.playback.time.value), 0);
    await screenshot(tester, 'caption');

    // Double-click it: its dialog. Change the text.
    final rect = c.scene!.captionRect(0, view.size).shift(view.topLeft);
    await tester.tapAt(rect.center);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(rect.center);
    await tester.pumpAndSettle();
    expect(find.text('Caption'), findsOneWidget);
    await screenshot(tester, 'caption-dialog');
    await tester.enterText(appField('Text'), 'Horns');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(c.captions.captions.single.text, 'Horns');

    // Saved and read back.
    final state = ProjectState.fromJson(c.projectState.toJson());
    expect(state.edits.captions, c.captions.captions);
    expect(Extensions.usedBy(c), [Extensions.captions]);

    // Off: kept, not drawn; an Undo step.
    c.setExtension('captions', false);
    await tester.pump();
    expect(c.scene!.captions, isEmpty);
    expect(c.captions.captions, hasLength(1));
    c.undo();
    await tester.pump();
    expect(c.scene!.captions, hasLength(1));

    c.undo();
    expect(c.captions.captions.single.text, 'The horns answer, softly');
    c.undo();
    expect(c.captions.captions, isEmpty);
    expect(c.scene!.captions, isEmpty);
  });
}
