import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

import 'po.dart';

/// The interface's language (Settings ▸ General ▸ Language).
///
/// Text is written in US English in the code, and translated where it is shown: `'Open Sample'.tr`,
/// or `'Bar {n}'.fill({'n': 12})` for text with values in it (the placeholders are the
/// translation's to place). Labels that also name things (a settings page, an enum's label) stay
/// English where they are kept and are translated where they are drawn, so a string can go through
/// [tr] twice; one a language has no entry for stays English.
enum AppLanguage {
  system('System', Locale('en')),
  english('English', Locale('en')),
  chineseSimplified('简体中文', Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans')),
  chineseTraditional('繁體中文', Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')),
  japanese('日本語', Locale('ja'));

  const AppLanguage(this.label, this._locale);

  /// Its name in its own language (the menu shows each so); [system]'s is translated.
  final String label;
  final Locale _locale;

  /// The languages the interface has, by their locales.
  static final locales = [for (final l in values) if (l != system) l._locale];

  /// Its translations' file, `assets/l10n/<tag>.po` (Crowdin writes them; English is the
  /// template, curator.pot), or null for English.
  String? get file => this == system || this == english ? null : 'assets/l10n/${_locale.toLanguageTag()}.po';

  /// The language it means now: [system] is the first of the system's preferred languages
  /// that the app has (Traditional Chinese for zh-Hant, zh-TW, zh-HK and zh-MO; Simplified for
  /// the other Chinese; otherwise by language, then by script or country where it has both).
  AppLanguage get resolved {
    if (this != system) return this;
    for (final l in PlatformDispatcher.instance.locales) {
      if (l.languageCode == 'zh') {
        final hant = l.scriptCode == 'Hant' ||
            (l.scriptCode == null && const {'TW', 'HK', 'MO'}.contains(l.countryCode));
        return hant ? chineseTraditional : chineseSimplified;
      }
      final same = [for (final a in values) if (a != system && a._locale.languageCode == l.languageCode) a];
      if (same.isEmpty) continue;
      return same.firstWhere(
        (a) => (a._locale.scriptCode ?? a._locale.countryCode) == (l.scriptCode ?? l.countryCode),
        orElse: () => same.first,
      );
    }
    return english;
  }

  Locale get locale => resolved._locale;
}

/// The translations in use: [load] reads them all as the app starts, [use] switches them.
abstract final class Strings {
  static AppLanguage _language = AppLanguage.english;
  static Map<String, String> _table = const {};
  static final _tables = <AppLanguage, Map<String, String>>{};

  /// Reads every language's file with [read] (`rootBundle.loadString` in the app; a file in a
  /// test). One that can't be read or parsed leaves its language English, and says so.
  static Future<void> load(Future<String> Function(String path) read) async {
    await Future.wait([
      for (final l in AppLanguage.values)
        if (l.file case final file?)
          read(file).then((s) => _tables[l] = PoFile.parse(s).table).catchError((Object e) {
            debugPrint('Couldn’t read $file: $e');
            return const <String, String>{};
          }),
    ]);
    use(_language);
  }

  /// The translations [language] has: its key ([Translated.tr]'s English) to its text.
  static Map<String, String> tableOf(AppLanguage language) => _tables[language.resolved] ?? const {};

  /// The language shown now ([AppLanguage.system] already resolved).
  static AppLanguage get language => _language;

  static void use(AppLanguage language) {
    _language = language.resolved;
    _table = tableOf(_language);
  }

  /// What debug runs have shown untranslated, each once.
  static final _missing = <String>{};

  static String of(String english) {
    final found = _table[english];
    if (found != null) return found;
    // (Text already in the language, translated where it was made, isn't reported.)
    if (kDebugMode && _table.isNotEmpty && !_translated.hasMatch(english) && _missing.add(english)) {
      debugPrint('Untranslated (${_language.name}): $english');
    }
    return english;
  }
}

extension Translated on String {
  /// This text in the interface's language.
  String get tr => Strings.of(this);

  /// This text as [context] uses it, where one English word stands for two things ("Flags": a
  /// settings page, or a note's): the `context\u0004text` entry, else [tr]'s.
  String trIn(String context) => Strings._table['$context\u0004$this'] ?? tr;

  /// This text in the interface's language, each `{name}` replaced by its value in [values].
  String fill(Map<String, Object?> values) =>
      tr.replaceAllMapped(_placeholder, (m) => values.containsKey(m[1]) ? '${values[m[1]]}' : m[0]!);
}

final _placeholder = RegExp(r'\{(\w+)\}');

/// Ideographs and their punctuation: text that has been translated, or has no letters to.
final _translated = RegExp(r'[\u3000-\u9fff\uff00-\uffef]|^[^A-Za-z]*$');
