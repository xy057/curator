// The interface's translations: every text the code translates is in the template
// (assets/l10n/curator.pot), every language's file has the template's texts with the same
// placeholders, the languages the app ships are wholly translated, and choosing a language
// re-labels the open window at once.

import 'dart:io';

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/l10n/l10n.dart';
import 'package:curated_score/l10n/po.dart';
import 'package:curated_score/main.dart';
import 'package:flutter_test/flutter_test.dart';

import 'window.dart';

void main() {
  PoFile read(String path) => PoFile.parse(File(path).readAsStringSync());
  final template = read('assets/l10n/curator.pot');
  final keys = {for (final e in template.entries) e.key};

  test('every text the code translates is in the template, which tool/l10n.dart has synced', () {
    final missing = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart') || file.path.contains('l10n')) continue;
      for (final key in translatedLiterals(file.readAsStringSync())) {
        if (!keys.contains(key)) missing.add('${file.path}: $key');
      }
    }
    expect(missing, isEmpty, reason: 'run `make l10n`');
    expect(keys, hasLength(template.entries.length), reason: 'a text twice in curator.pot');
  });

  test("each language has the template's texts, with the same placeholders", () {
    final placeholder = RegExp(r'\{\w+\}');
    Set<String> placeholders(String text) => {for (final m in placeholder.allMatches(text)) m[0]!};
    for (final language in AppLanguage.values) {
      final file = language.file;
      if (file == null) continue;
      final po = read(file);
      expect({for (final e in po.entries) e.key}, keys, reason: '$file: run `make l10n`');
      for (final e in po.entries) {
        if (e.text.isNotEmpty) expect(placeholders(e.text), placeholders(e.id), reason: '$file: ${e.id}');
      }
      // The languages translated here are kept whole; one Crowdin adds may be partly translated.
      if (const {AppLanguage.chineseSimplified, AppLanguage.chineseTraditional, AppLanguage.japanese}.contains(language)) {
        expect([for (final e in po.entries) if (e.text.isEmpty || e.fuzzy) e.key], isEmpty, reason: '$file: untranslated');
      }
      expect(Strings.tableOf(language), po.table, reason: '$file: loaded');
    }
  });

  test('a catalog reads back as it was written', () {
    final po = read(AppLanguage.chineseTraditional.file!);
    expect(PoFile.parse(po.toString()).toString(), po.toString());
    expect(po.table['page\u0004Flags'], isNotNull);
    expect(po.table['Align\nSet the anchors from the recording'], contains('\n'));
  });

  testWidgets('choosing Chinese or Japanese re-labels the window, and English brings it back', (tester) async {
    desktopWindow(tester);
    addTearDown(() => Strings.use(AppLanguage.english));
    final settings = AppSettings.memory();
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Open Sample'), findsOneWidget);

    settings.language = AppLanguage.chineseSimplified;
    await tester.pump(const Duration(milliseconds: 400)); // past the cross-fade
    expect(find.text('打开示例'), findsOneWidget);
    expect(find.text('Open Sample'), findsNothing);

    settings.language = AppLanguage.chineseTraditional;
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('打開範例'), findsOneWidget);

    settings.language = AppLanguage.japanese;
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('サンプルを開く'), findsOneWidget);

    settings.language = AppLanguage.english;
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Open Sample'), findsOneWidget);
  });
}
