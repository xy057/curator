// Keeps the interface's translations in step with the code: every `'…'.tr`, `'…'.fill(…)` and
// `'…'.trIn('…')` text in lib/, and every text of Curator's own extensions (assets/extensions:
// `tr("…")` in their Lua, their connectors' titles, their names), goes into the template, assets/l10n/curator.pot (the English
// Crowdin translates from), with the files using it; then every language's .po gets the
// template's entries in its order, untranslated where it has none, and loses those the
// template no longer has. Text translated other than as a literal (an enum's label) is added
// to curator.pot by hand, and stays.
// Run from app/: `dart run tool/l10n.dart` (`make l10n` does).
import 'dart:io';

import 'package:curated_score/l10n/po.dart';

void main() {
  final used = <String, Set<String>>{}; // key → the files using it
  final files = Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    if (file.path.contains('${Platform.pathSeparator}l10n${Platform.pathSeparator}')) continue;
    for (final key in translatedLiterals(file.readAsStringSync())) {
      (used[key] ??= {}).add(file.path.replaceAll(r'\', '/'));
    }
  }
  // Curator's own extensions: their Lua and their connectors' titles.
  final extensions = Directory('assets/extensions').listSync(recursive: true).whereType<File>().toList()..sort((a, b) => a.path.compareTo(b.path));
  for (final file in extensions) {
    final path = file.path.replaceAll(r'\', '/');
    if (!path.endsWith('.lua') && !path.endsWith('.json')) continue;
    for (final key in extensionTexts(path, file.readAsStringSync())) {
      (used[key] ??= {}).add(path);
    }
  }

  final potFile = File('assets/l10n/curator.pot');
  final pot = PoFile.parse(potFile.readAsStringSync());
  final known = {for (final e in pot.entries) e.key};
  var added = 0;
  for (final key in used.keys) {
    if (known.contains(key)) continue;
    final sep = key.indexOf('\u0004');
    pot.entries.add(sep < 0 ? PoEntry(key) : PoEntry(key.substring(sep + 1), context: key.substring(0, sep)));
    added++;
  }
  for (final e in pot.entries) {
    e.references = [...?used[e.key]];
  }
  potFile.writeAsStringSync(pot.toString());
  stdout.writeln('${potFile.path}: ${pot.entries.length} texts${added > 0 ? ', $added new' : ''}');

  for (final file in Directory('assets/l10n').listSync().whereType<File>().where((f) => f.path.endsWith('.po'))) {
    final po = PoFile.parse(file.readAsStringSync());
    final had = {for (final e in po.entries) e.key: e};
    final entries = [
      for (final t in pot.entries)
        PoEntry(t.id, context: t.context, text: had[t.key]?.text ?? '', references: t.references, fuzzy: had[t.key]?.fuzzy ?? false),
    ];
    final dropped = had.keys.where((k) => !known.contains(k) && !used.containsKey(k)).length;
    po.entries
      ..clear()
      ..addAll(entries);
    file.writeAsStringSync(po.toString());
    final untranslated = entries.where((e) => e.text.isEmpty).length;
    stdout.writeln('${file.path}: ${untranslated == 0 ? 'all translated' : '$untranslated untranslated'}'
        '${dropped > 0 ? ', $dropped no longer used removed' : ''}');
  }
}
