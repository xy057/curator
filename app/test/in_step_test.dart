// What is made or copied from elsewhere is in step with it: every text the code translates is in
// the template (assets/l10n/curator.pot, `make l10n`), every language's file has the template's
// texts with the same placeholders and the languages the app ships are wholly translated, the
// shortcuts' names are there too, docs/extension-api.md, docs/plugin-api.md, docs/lane-script.md
// and docs/web-plugin-api.md are the guides and the APIs as they are (`make extension-docs`,
// `make plugin-docs`, `make script-docs`, `make web-plugin-docs`), what is built from TypeScript is built from it
// as it is (`make web-plugins`), the commands plugins are told of are the app's, and the
// licence the app carries is the repository's.

import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:curated_score/key_bindings.dart';
import 'package:curated_score/l10n/l10n.dart';
import 'package:curated_score/l10n/po.dart';
import 'package:curated_score/web_player/player.dart' show pageIcons;
import 'package:flutter_test/flutter_test.dart';

import 'package:score_engine/score_engine.dart' show PluginApi;

import '../tool/extension_docs.dart';
import '../tool/plugin_docs.dart';
import '../tool/script_docs.dart';
import '../tool/web_plugin_docs.dart';

void main() {
  test('in step: the translations’ template and every language, the shortcuts’ names, the API docs, plugins’ commands, the licence', () {
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
    for (final file in [for (final folder in bundledScriptFolders) ...Directory(folder).listSync(recursive: true).whereType<File>()]) {
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
    final listed = {for (final l in AppLanguage.values) ?l.file};
    for (final file in Directory('assets/l10n').listSync().map((f) => f.path).where((p) => p.endsWith('.po'))) {
      final po = read(file), language = AppLanguage.of(file.split('/').last.replaceAll('.po', ''));
      expect({for (final e in po.entries) e.key}, keys, reason: '$file: run `make l10n`');
      for (final e in po.entries) {
        if (e.text.isNotEmpty) expect(placeholders(e.text), placeholders(e.id), reason: '$file: ${e.id}');
      }
      // The languages translated here are kept whole; one Crowdin adds may be partly translated.
      // Crowdin writes a translation that is the English as none, so a text of one word at most
      // (a name, a unit, a key: Carbon, ms, OK) may be empty; a phrase never is.
      if (const {'zh-Hans', 'zh-Hant', 'ja'}.contains(language.tag)) {
        bool asEnglish(PoEntry e) => e.text.isEmpty && RegExp('[A-Za-z]+').allMatches(e.id.replaceAll(placeholder, '')).length <= 1;
        expect([for (final e in po.entries) if ((e.text.isEmpty && !asEnglish(e)) || e.fuzzy) e.key], isEmpty, reason: '$file: untranslated');
      }
      // Each file with anything translated is a language of the menu's, found as the app starts.
      expect(listed.contains(file), po.table.isNotEmpty, reason: '$file: listed');
      expect(Strings.tableOf(language), po.table.isEmpty ? isEmpty : po.table, reason: '$file: loaded');
    }
    expect(AppLanguage.of('ko_KR').tag, 'ko-KR');
    expect(AppLanguage.named('chineseTraditional'), AppLanguage.of('zh-Hant')); // as kept before
    // A catalog reads back as it was written.
    final po = read(AppLanguage.of('zh-Hant').file!);
    expect(PoFile.parse(po.toString()).toString(), po.toString());
    expect(po.table['Align\nSet the anchors from the recording'], contains('\n'));
    // A guess (fuzzy) is left out with a context as without one, and its places are kept.
    final guessed = PoFile.parse('msgid ""\nmsgstr ""\n\n#: a.dart\n#, fuzzy\nmsgctxt "verb"\nmsgid "Record"\nmsgstr "x"\n#, fuzzy\nmsgid "Stop"\nmsgstr "y"\n');
    expect(guessed.table, isEmpty);
    expect([for (final e in guessed.entries) '${e.key} ${e.fuzzy} ${e.references}'], ['verb\u0004Record true [a.dart]', 'Stop true []']);

    // docs/extension-api.md is the guide and the API as they are now.
    final guide = File('assets/help/extensions.md').readAsStringSync();
    expect(File('../docs/extension-api.md').readAsStringSync(), extensionDocs(guide), reason: 'run `make extension-docs`');
    expect(File('../docs/plugin-api.md').readAsStringSync(), pluginDocs(File('assets/help/plugins.md').readAsStringSync()), reason: 'run `make plugin-docs`');
    expect(File('../docs/lane-script.md').readAsStringSync(), laneScriptDocs(File('assets/help/script.md').readAsStringSync()), reason: 'run `make script-docs`');

    // docs/web-plugin-api.md is the web plugins' guide and their API as TypeScript declares it;
    // what is built from TypeScript (the web player's plugin host, Curator's own web plugins'
    // main.js) was built from the sources as they are, and is as it was built.
    expect(File('../docs/web-plugin-api.md').readAsStringSync(),
        webPluginDocs(File('assets/help/web-plugins.md').readAsStringSync(), File('assets/web_plugins/curator-web.d.ts').readAsStringSync()),
        reason: 'run `make web-plugin-docs`');
    String seal(List<String> paths) => '${sha256.convert([
          for (final path in paths..sort()) ...'$path\n${sha256.convert(File('../$path').readAsBytesSync())}\n'.codeUnits,
        ])}';
    final folders = Directory('assets/web_plugins').listSync().whereType<Directory>().toList();
    final typescript = [
      'web_plugins/host.ts',
      for (final f in Directory('assets/web_plugins').listSync(recursive: true).whereType<File>())
        if (f.path.endsWith('.ts')) 'app/${f.path}',
    ];
    final built = ['app/web/plugin_host.js', for (final folder in folders) 'app/${folder.path}/main.js'];
    expect(File('../web_plugins/sources.sha256').readAsStringSync(), 'sources ${seal(typescript)}\nbuilt ${seal(built)}\n', reason: 'run `make web-plugins`');
    // Each icon and event the types name is one the host knows (`curator.has`), and the player draws the icons.
    final types = File('assets/web_plugins/curator-web.d.ts').readAsStringSync(), host = File('../web_plugins/host.ts').readAsStringSync();
    final icons = RegExp(r'"(\w+)"').allMatches(RegExp(r'export type Icon =([^;]+);').firstMatch(types)![1]!).map((m) => m[1]!).toSet();
    final events = RegExp(r'^  (\w+): ', multiLine: true).allMatches(RegExp(r'export interface Events \{(.+?)^\}', multiLine: true, dotAll: true).firstMatch(types)![1]!).map((m) => m[1]!).toSet();
    Set<String> known(String name) => RegExp(r'"([\w.]+)"').allMatches(RegExp('const $name[^=]*= \\[([^\\]]+)\\]').firstMatch(host)![1]!).map((m) => m[1]!).toSet();
    expect(known('icons'), icons);
    expect(known('events'), events);
    expect(pageIcons.keys.toSet(), icons);

    // The commands plugins are told of (PluginApi.commands) are the app's: each of the menus'
    // and the editor's own, by its name, its title and whether its key can be changed, with
    // About, which has no key.
    final told = {for (final c in PluginApi.commands) c.id: c};
    final own = [for (final c in KeyCommand.values) if (c.place == KeyPlace.menus || c.place == KeyPlace.editor) c];
    expect(told.keys.toSet().difference({for (final c in own) c.name}), {'about'});
    for (final c in own) {
      if (told[c.name] case final command?) {
        expect((command.title, command.rebind), (c.label, c.editable), reason: c.name);
        // (The tabs' two are in Window on macOS, where the API puts them, and in View elsewhere.)
        if (c.place == KeyPlace.menus && command.menu != 'Window') expect(command.menu, c.group, reason: c.name);
      }
    }

    // The licence the app carries (Settings ▸ About ▸ Licenses) is the repository's.
    expect(File('assets/LICENSE.txt').readAsStringSync(), File('../LICENSE').readAsStringSync());
  });
}
