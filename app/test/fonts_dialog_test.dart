// Drives Score ▸ Fonts… with real taps, and Undo through font changes.
// With SCREENSHOT_DIR set, also saves a PNG of the dialog for visual review.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/fonts_dialog.dart';
import 'package:curated_score/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';
import 'test_fonts.dart';

void main() {
  testWidgets('the Fonts dialog engraves the score in another music and text font, each an Undo step', (tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const CuratedScoreApp());
    final state = tester.state(find.byType(HomePage)) as dynamic;
    final c = state.controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScore.path));
    await tester.pump();
    await tester.pump();
    Future<void> settle() async {
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
    }

    Future<void> engraved() async {
      while (c.isReengraving) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
    }

    expect(c.fonts, ScoreFonts.standard);
    unawaited(showFontsDialog(tester.element(find.byType(HomePage)), c));
    await settle();
    expect(find.text('Fonts'), findsOneWidget);

    // Music: Leland, from the list.
    await tester.tap(find.byType(DropdownMenu<String>).first);
    await settle();
    await tester.tap(find.text('Leland').last);
    await settle();
    await engraved();
    expect(c.fonts.music, MusicFont.leland);
    expect(c.score!.fonts.music, MusicFont.leland);
    expect(c.scene!.style.musicFontFamily, 'packages/score_engine/Leland');

    // Text: an installed family, typed into the filter.
    await tester.enterText(find.byType(DropdownMenu<String>).last, 'Helvet');
    await settle();
    await tester.tap(find.text('Helvetica').last);
    await settle();
    await engraved();
    expect(c.fonts, const ScoreFonts(music: MusicFont.leland, text: 'Helvetica'));
    expect(c.score!.textFontFamily, 'Helvetica');
    expect(c.projectState.fonts, c.fonts);
    final dir = Platform.environment['SCREENSHOT_DIR'];
    if (dir != null) {
      await tester.runAsync(() async {
        await loadTestFonts();
        final helvetica = File('/System/Library/Fonts/Helvetica.ttc').readAsBytesSync();
        await (FontLoader('Helvetica')..addFont(Future.value(ByteData.sublistView(helvetica)))).load();
      });
      c.setStaffSpace(6); // a new scene, drawn with the fonts just loaded
      await settle();
      await tester.runAsync(() async {
        // The whole window, the dialog included (its layer is in physical pixels).
        final view = tester.binding.renderViews.first;
        final image = await (view.debugLayer! as OffsetLayer).toImage(Offset.zero & tester.view.physicalSize);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/fonts-dialog.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    // Each was its own Undo step.
    c.undo();
    await engraved();
    expect(c.fonts, const ScoreFonts(music: MusicFont.leland));
    c.undo();
    await engraved();
    expect(c.fonts, ScoreFonts.standard);
    expect(c.score!.fonts, ScoreFonts.standard);
    c.redo();
    await engraved();
    expect(c.score!.fonts.music, MusicFont.leland);

    await tester.tap(find.text('Done'));
    await settle();
    expect(find.text('Fonts'), findsNothing);
  });
}
