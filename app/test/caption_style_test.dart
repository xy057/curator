import 'dart:async';

import 'package:curated_score/app_extensions.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/project_state.dart';
import 'package:curated_score/score_view.dart';
import 'package:curated_score/settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'test_fonts.dart';
import 'window.dart';

void main() {
  testWidgets('Captions settings style every project; Project Settings ▸ Fonts has a caption font while Captions is on', (tester) async {
    await tester.runAsync(loadTestFonts);
    desktopWindow(tester);
    Future<void> settle() async {
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 150));
      }
    }

    final settings = AppSettings.memory();
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Open Sample'));
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    for (var i = 0; i < 100 && c.score == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    await tester.runAsync(TextFonts.installed);

    // Off: no caption font.
    unawaited(showProjectSettingsDialog(tester.element(find.byType(HomePage)), settings, c, page: 'Fonts'));
    await settle();
    expect(find.text('Caption'), findsNothing);
    Navigator.of(tester.element(find.text('Music'))).pop();
    await settle();

    settings.captions = true;
    await tester.pump();
    final bar = c.score!.timeline.measureStarts;
    c.captions.add(Caption(bar[1], bar[5], 'The horns answer, softly'));
    final span = captionSpans(c.captions.captions, c.timeline).first;
    c.playback.seek((span.start + span.end) / 2);
    await tester.pump();
    final bottomTop = c.scene!.layoutAt(c.playback.time.value, c.curation!, tester.getSize(find.byType(ScoreView))).placements.first.y;

    // The app's settings: on top, a ring, large.
    settings
      ..captionPosition = CaptionPosition.top
      ..captionCountdown = CaptionCountdown.ring
      ..captionSize = CaptionSize.large;
    await settle();
    expect(c.scene!.captionStyle.position, CaptionPosition.top);
    expect(c.scene!.captionStyle.countdown, CaptionCountdown.ring);
    expect(c.scene!.captionStyle.size, CaptionSize.large);
    final topTop = c.scene!.layoutAt(c.playback.time.value, c.curation!, tester.getSize(find.byType(ScoreView))).placements.first.y;
    expect(topTop, greaterThan(bottomTop), reason: 'the staves make room above them');
    await screenshot(tester, 'caption-top-ring', inside: find.byType(ScoreView));

    // The project's own font, an Undo step, saved.
    unawaited(showProjectSettingsDialog(tester.element(find.byType(HomePage)), settings, c, page: 'Fonts'));
    await settle();
    expect(find.text('Caption'), findsOneWidget);
    await tester.tap(find.byType(DropdownMenu<String>).last);
    await settle();
    await tester.tap(find.text(TextFonts.academico).last);
    await settle();
    expect(c.captions.font, TextFonts.academico);
    expect(c.scene!.captionStyle.fontFamily, TextFonts.familyOf(TextFonts.academico));
    await screenshot(tester, 'fonts-caption', inside: find.text('Music'));
    Navigator.of(tester.element(find.text('Music'))).pop();
    await settle();
    expect(ProjectState.fromJson(c.projectState.toJson()).edits.captionFont, TextFonts.academico);
    expect(AppExtension.usedBy(c), [AppExtension.captions]);
    c.undo();
    await settle();
    expect(c.captions.font, isNull);
    expect(c.scene!.captionStyle.fontFamily, isNull, reason: 'the app\'s: the score\'s text font');

    // The settings page.
    settings.captionFont = TextFonts.academico;
    await settle();
    expect(c.scene!.captionStyle.fontFamily, TextFonts.familyOf(TextFonts.academico));
  });
}
