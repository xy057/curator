// Importing a score that has things Curator leaves out lists them in a dialog, instead of only
// in the log. With SCREENSHOT_DIR set, also saves a PNG of the dialog for visual review.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:curated_score/edit_dialogs.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_project.dart';
import 'test_fonts.dart';

void main() {
  testWidgets('what an imported score loses is listed in a dialog', (tester) async {
    final dir = Platform.environment['SCREENSHOT_DIR'];
    if (dir != null) await tester.runAsync(loadTestFonts);
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const CuratedScoreApp());
    final state = tester.state(find.byType(HomePage)) as dynamic;
    final c = state.controller as EditorController;

    // The demo is read whole.
    await tester.runAsync(() => c.openFile(demoScore.path));
    expect(c.score!.warnings, isEmpty);

    // Harp pedal diagrams (one before every direction) are left out, and said once.
    final temp = await tester.runAsync(() => Directory.systemTemp.createTemp('import-warnings'));
    addTearDown(() => temp!.deleteSync(recursive: true));
    final harp = File('${temp!.path}/Harp.musicxml')
      ..writeAsStringSync(demoScore.readAsStringSync().replaceAll(
          '<direction>', '<direction><direction-type><harp-pedals/></direction-type></direction><direction>'));
    await tester.runAsync(() => c.openFile(harp.path));
    expect(c.score!.warnings, ["Unsupported direction-type 'harp-pedals'"]);

    final context = tester.element(find.byType(HomePage));
    showImportWarnings(context, 'Harp.musicxml', [...c.score!.warnings, 'Clef change at measure 3, staff 2, time 0 not inserted']);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Some of “Harp.musicxml” isn’t shown'), findsOneWidget);
    expect(find.text('These 2 things were left out or aren’t supported:'), findsOneWidget);
    expect(find.text("Unsupported direction-type 'harp-pedals'"), findsOneWidget);

    if (dir != null) {
      await tester.runAsync(() async {
        // The whole window, the dialog included (its layer is in physical pixels).
        final view = tester.binding.renderViews.first;
        final image = await (view.debugLayer! as OffsetLayer).toImage(Offset.zero & tester.view.physicalSize);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/import_warnings.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    await tester.tap(find.text('OK'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('isn’t shown'), findsNothing);
  });
}
