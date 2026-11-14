// What is made or copied from elsewhere is in step with it: every text the code translates is in
// the template (assets/l10n/curator.pot, `make l10n`), every language's file has the template's
// texts with the same placeholders and the languages the app ships are wholly translated, the
// shortcuts' names are there too, docs/extension-api.md is the guide and the API as they are
// (`make extension-docs`), and the licence the app carries is the repository's.

import 'dart:io';

import 'package:curated_score/key_bindings.dart';
import 'package:curated_score/l10n/l10n.dart';
import 'package:curated_score/l10n/po.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/extension_docs.dart';

void main() {
  test('in step: the translations’ template and every language, the shortcuts’ names, docs/extension-api.md, the licence', () {
    PoFile read(String path) => PoFile.parse(File(path).readAsStringSync());
    final template = read('assets/l10n/curator.pot');
    final keys = {for (final e in template.entries) e.key};

    // Every text the code translates is in the template, which tool/l10n.dart has synced.
    final missing = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart') || file.path.contains('l10n')) continue;
      for (final key in translatedLiterals(file.readAsStringSync())) {
        if (!keys.contains(key)) missing.add('${file.path}: $key');
      }
    }
    for (final file in Directory('assets/extensions').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.lua') && !file.path.endsWith('.json')) continue;
      for (final key in extensionTexts(file.path, file.readAsStringSync())) {
        if (!keys.contains(key)) missing.add('${file.path}: $key');
      }
    }
    expect(missing, isEmpty, reason: 'run `make l10n`');
    expect(keys, hasLength(template.entries.length), reason: 'a text twice in curator.pot');

    // Each command's name, help and heading too (enum data, put in by hand).
    for (final command in KeyCommand.values) {
      expect(keys, contains(command.label), reason: command.name);
      if (command.help case final help?) expect(keys, contains(help), reason: '${command.name}: help');
      final group = command.group;
      if (group != 'Curator') expect(keys.contains(group) || keys.contains('heading\u0004$group'), isTrue, reason: group);
    }

    // Each language has the template's texts, with the same placeholders.
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
    // A catalog reads back as it was written.
    final po = read(AppLanguage.chineseTraditional.file!);
    expect(PoFile.parse(po.toString()).toString(), po.toString());
    expect(po.table['Align\nSet the anchors from the recording'], contains('\n'));

    // docs/extension-api.md is the guide and the API as they are now.
    final guide = File('assets/help/extensions.md').readAsStringSync();
    expect(File('../docs/extension-api.md').readAsStringSync(), extensionDocs(guide), reason: 'run `make extension-docs`');

    // The licence the app carries (Settings ▸ About ▸ Licenses) is the repository's.
    expect(File('assets/LICENSE.txt').readAsStringSync(), File('../LICENSE').readAsStringSync());
  });
}
