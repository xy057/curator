import 'dart:io';

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('removing a missing recent file leaves the next one as it was', (tester) async {
    final dir = Directory.systemTemp.createTempSync('curator_recent');
    addTearDown(() => dir.deleteSync(recursive: true));
    final missing = '${dir.path}/Gone.curator';
    final present = File('${dir.path}/Here.curator')..writeAsStringSync('');
    final settings = AppSettings.memory()
      ..addRecent(present.path)
      ..addRecent(missing); // most recent first: the missing one on top

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListenableBuilder(
          listenable: settings,
          builder: (context, _) => HomeScreen(
            settings: settings,
            recentFiles: settings.recentFiles,
            onOpen: () {},
            onImport: () {},
            onOpenRecent: (_) {},
            onRemoveRecent: settings.removeRecent,
            onClearRecent: settings.clearRecent,
            onOpenSample: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('Not found'), findsOneWidget);

    await tester.tap(find.byTooltip('Remove from Recent').first);
    await tester.pumpAndSettle();

    expect(settings.recentFiles, [present.path]);
    expect(find.text('Here.curator'), findsOneWidget);
    // The row that showed the missing file doesn't pass "not found" on to the one that took its place.
    expect(find.textContaining('Not found'), findsNothing);
  });
}
