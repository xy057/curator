// Settings ▸ General ▸ Hide AI features, read as the app starts: hidden, nothing offers AI (no AI
// for PDF import in General, no Read with AI in the PDF import) and Settings ▸ AI lies under a
// cover, the page drawn but out of reach; the switch, General's or the cover's, applies from the
// next launch.

import 'dart:io';

import 'package:curated_score/app_colors.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/pdf_import.dart';
import 'package:curated_score/settings_dialog.dart';
import 'package:curated_score/ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_fonts.dart';
import 'window.dart';

void main() {
  testWidgets('AI hidden from the next launch: General without it, Settings ▸ Remote AI Provider under a cover, no Read with AI', (tester) async {
    await tester.runAsync(loadTestFonts);
    desktopWindow(tester);
    SharedPreferences.setMockInitialValues({});
    final before = (await tester.runAsync(AppSettings.load))!;
    expect((before.hideAi, before.aiHidden, before.aiRestartPending), (false, false, false));
    before.hideAi = true; // nothing changes until the app is opened again
    expect((before.aiHidden, before.aiRestartPending), (false, true));
    final settings = (await tester.runAsync(AppSettings.load))!; // the next launch
    expect((settings.hideAi, settings.aiHidden, settings.aiRestartPending), (true, true, false));

    final pages = (await tester.runAsync(() async => PdfPages.open(await File('assets/exam/pdf-ai-exam.pdf').readAsBytes())))!;
    addTearDown(pages.close);
    final layout = PdfScoreLayout(
      pages: pages.sizes,
      instruments: const [PdfInstrument(id: 'P1', name: 'Flute')],
      systems: [
        PdfSystem.cut(
            page: 0, top: 80, bottom: 150, left: 100, right: 420, //
            staves: const [PdfStaff(top: 100, space: 6, part: 'P1')], barlines: const [PdfBarline(420)]),
      ],
    );

    await tester.pumpWidget(MaterialApp(
      theme: AppColors.theme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Column(children: [
            for (final page in ['General', 'Remote AI Provider'])
              TextButton(onPressed: () => showSettingsDialog(context, settings, page: page), child: Text('Open $page')),
            // As main.dart opens it: with no model and no way to choose one while AI is hidden.
            for (final hidden in [true, false])
              TextButton(
                  onPressed: () => showPdfImport(context, pages,
                      name: 'Exam.pdf', layout: layout, chooseAi: hidden ? null : () async => null),
                  child: Text('Import ${hidden ? 'hidden' : 'shown'}')),
          ]),
        ),
      ),
    ));
    Future<void> settle() async {
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    Future<void> close() async {
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await settle();
    }

    // General: the switch, no AI for PDF import; changed, it asks for a restart, changed back, not.
    await tester.tap(find.text('Open General'));
    await settle();
    final row = find.ancestor(of: find.text('Hide AI features'), matching: find.byWidgetPredicate((w) => '${w.runtimeType}' == '_SettingRow'));
    final toggle = find.descendant(of: row, matching: find.byType(AppSwitch));
    expect(tester.widget<AppSwitch>(toggle).value, isTrue);
    expect(find.text('AI for PDF import'), findsNothing);
    expect(find.text('Restart to apply.'), findsNothing);
    await tester.tap(toggle);
    await settle();
    expect((settings.hideAi, settings.aiHidden), (false, true));
    expect(find.descendant(of: row, matching: find.text('Restart to apply.')), findsOneWidget);
    expect(find.text('AI for PDF import'), findsNothing); // still hidden: not until a restart
    await tester.tap(toggle);
    await settle();
    expect((settings.hideAi, settings.aiRestartPending), (true, false));
    expect(find.text('Restart to apply.'), findsNothing);
    await close();

    // Settings ▸ Remote AI Provider: the page drawn under the cover, nothing on it reached; the cover's switch.
    await tester.tap(find.text('Open Remote AI Provider'));
    await settle();
    final cover = find.byKey(const ValueKey('aiHidden'));
    expect(find.descendant(of: cover, matching: find.text('AI features are hidden')), findsOneWidget);
    expect(find.text('Anthropic'), findsWidgets);
    expect(find.text('Anthropic').hitTestable(), findsNothing);
    expect(find.text('Add Provider…').hitTestable(), findsNothing);
    await screenshot(tester, 'ai-hidden', inside: cover, outermost: true);
    await tester.tap(find.descendant(of: cover, matching: find.byType(AppSwitch)));
    await settle();
    expect((settings.hideAi, settings.aiHidden), (false, true));
    expect(find.descendant(of: cover, matching: find.text('Restart to apply.')), findsOneWidget);
    await screenshot(tester, 'ai-hidden-restart', inside: cover, outermost: true);
    await close();

    // The PDF import: no Read with AI while hidden; offered, it is there.
    for (final (hidden, found) in [(true, findsNothing), (false, findsOneWidget)]) {
      await tester.tap(find.text('Import ${hidden ? 'hidden' : 'shown'}'));
      await settle();
      expect(find.byTooltip('Read with AI…'), found, reason: hidden ? 'AI hidden' : 'AI shown');
      await close();
    }

    // Shown at launch: the page as ever, no cover.
    settings.hideAi = false;
    final shown = (await tester.runAsync(AppSettings.load))!;
    expect(shown.aiHidden, isFalse);
    await tester.pumpWidget(MaterialApp(
      theme: AppColors.theme(),
      home: Scaffold(
        body: Builder(
            builder: (context) => TextButton(
                onPressed: () => showSettingsDialog(context, shown, page: 'Remote AI Provider'), child: const Text('Open'))),
      ),
    ));
    await tester.tap(find.text('Open'));
    await settle();
    expect(find.byKey(const ValueKey('aiHidden')), findsNothing);
    expect(find.text('Anthropic').hitTestable(), findsWidgets);
    await close();
  });
}
