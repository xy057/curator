import 'package:curated_score/app_extensions.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/image_patch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_project.dart';
import 'image_patch_test.dart' show png;

void main() {
  testWidgets('a project using an extension that is off asks to turn it on; the switch is the app\'s', (tester) async {
    final settings = AppSettings.memory();
    final c = EditorController(vsync: const TestVSync());
    addTearDown(c.dispose);
    await tester.runAsync(() => c.openFile(demoScore.path));
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (ctx) {
      context = ctx;
      return const SizedBox();
    })));

    // Nothing used: no dialog.
    promptForExtensions(context, settings, c);
    await tester.pumpAndSettle();
    expect(find.byType(ExtensionsDialog), findsNothing);

    // A project with an image, opened with Attach Image off (as another user's file would be).
    c.images.enabled = true;
    await tester.runAsync(() => c.images.add(ImageKind.raster, png, quarter: 3, top: 2));
    final state = c.projectState;
    c.images.enabled = false;
    await tester.runAsync(() => c.openProject(name: 'demo.musicxml', scoreBytes: demoScore.readAsBytesSync(), state: state));
    expect(AppExtension.usedBy(c), [AppExtension.attachImage], reason: 'kept, though off');

    promptForExtensions(context, settings, c);
    await tester.pumpAndSettle();
    expect(find.text('Extensions in this project'), findsOneWidget);
    expect(find.text('Attach Image'), findsOneWidget);
    expect(find.text('All'), findsNothing, reason: 'one extension needs no "All"');
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(settings.attachImage, isTrue, reason: 'a global setting, not the project\'s');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    // Already on: not asked again.
    promptForExtensions(context, settings, c);
    await tester.pumpAndSettle();
    expect(find.byType(ExtensionsDialog), findsNothing);
  });

  testWidgets('with several extensions, "All" turns every one on or off', (tester) async {
    final settings = AppSettings.memory();
    final list = [AppExtension.attachImage, AppExtension.attachImage]; // stands for several
    await tester.pumpWidget(MaterialApp(home: Material(child: ExtensionsDialog(settings: settings, extensions: list))));
    expect(find.text('All'), findsOneWidget);
    await tester.tap(find.text('All'));
    await tester.pump();
    expect(settings.attachImage, isTrue);
    await tester.tap(find.text('All'));
    await tester.pump();
    expect(settings.attachImage, isFalse);
  });
}
