import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_project.dart';
import 'window.dart';


void main() {
  testWidgets('Recent files open from the home screen; missing ones say so', (tester) async {
    desktopWindow(tester);
    final settings = AppSettings.memory()
      ..addRecent('/nowhere/Gone.ccs')
      ..addRecent(demoScore.absolute.path);
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    await tester.pumpAndSettle();

    // One Open for projects and scores, and the recent files, newest first.
    expect(find.text('Open…'), findsOneWidget);
    expect(find.textContaining('Import'), findsNothing);
    expect(find.text('WI275 - 01 Intro.musicxml'), findsWidgets);
    expect(find.textContaining('Not found'), findsOneWidget);

    // Open Recent is in the File menu too.
    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open Recent'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(MenuItemButton, 'Gone.ccs'), findsOneWidget);
    await tester.tapAt(const Offset(700, 700));
    await tester.pumpAndSettle();

    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    await tester.tap(find.text('WI275 - 01 Intro.musicxml').last);
    for (var i = 0; i < 100 && c.score == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(c.score, isNotNull);
    expect(settings.recentFiles.first, demoScore.absolute.path);
  });

  testWidgets('with the mascot on, Home shows it and the running app takes it as its icon; off, the icon comes back', (tester) async {
    desktopWindow(tester);
    const window = MethodChannel('curated_score/window');
    final icons = <Uint8List?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(window, (call) async {
      if (call.method == 'setAppIcon') icons.add((call.arguments as Map)['png'] as Uint8List?);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(window, null));
    bool showing(String asset) => tester
        .widgetList<Image>(find.byType(Image))
        .any((i) => i.image is AssetImage && (i.image as AssetImage).assetName == 'assets/icon/$asset.png');

    final settings = AppSettings.memory()..mascotIcon = true;
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    await tester.pumpAndSettle();
    expect(showing('mascot'), isTrue);
    expect(icons, hasLength(1));
    expect(icons.single, isNotNull);
    expect(icons.single!.sublist(1, 4), 'PNG'.codeUnits);

    settings.mascotIcon = false;
    await tester.pumpAndSettle();
    expect(showing('app_icon'), isTrue);
    expect(showing('mascot'), isFalse);
    expect(icons, hasLength(2));
    expect(icons.last, isNull, reason: "the bundle's icon again");
  });
}
