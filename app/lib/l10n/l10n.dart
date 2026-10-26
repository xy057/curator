import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

import 'zh_hans.dart';
import 'zh_hant.dart';

/// The interface's language (Settings ▸ General ▸ Language).
///
/// Text is written in US English in the code, and translated where it is shown: `'Open Sample'.tr`,
/// or `'Bar {n}'.fill({'n': 12})` for text with values in it (the placeholders are the
/// translation's to place). Labels that also name things (a settings page, an enum's label) stay
/// English where they are kept and are translated where they are drawn, so a string can go through
/// [tr] twice; one a language has no entry for stays English.
enum AppLanguage {
  system('System'),
  english('English'),
  chineseSimplified('简体中文'),
  chineseTraditional('繁體中文');

  const AppLanguage(this.label);

  /// Its name in its own language (the menu shows each so); [system]'s is translated.
  final String label;

  static const englishLocale = Locale('en');
  static const chineseLocale = Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans');
  static const traditionalLocale = Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');
  static const locales = [englishLocale, chineseLocale, traditionalLocale];

  /// The language it means now: [system] is the first of the system's preferred languages
  /// that the app has (Traditional Chinese for zh-Hant, zh-TW, zh-HK and zh-MO; Simplified for
  /// the other Chinese).
  AppLanguage get resolved {
    if (this != system) return this;
    for (final l in PlatformDispatcher.instance.locales) {
      if (l.languageCode == 'en') return english;
      if (l.languageCode == 'zh') {
        final hant = l.scriptCode == 'Hant' ||
            (l.scriptCode == null && const {'TW', 'HK', 'MO'}.contains(l.countryCode));
        return hant ? chineseTraditional : chineseSimplified;
      }
    }
    return english;
  }

  Locale get locale => switch (resolved) {
        chineseSimplified => chineseLocale,
        chineseTraditional => traditionalLocale,
        _ => englishLocale,
      };
}

/// The translations in use: [use] switches them.
abstract final class Strings {
  static AppLanguage _language = AppLanguage.english;
  static Map<String, String> _table = const {};

  /// The language shown now ([AppLanguage.system] already resolved).
  static AppLanguage get language => _language;

  static void use(AppLanguage language) {
    _language = language.resolved;
    _table = switch (_language) {
      AppLanguage.chineseSimplified => zhHans,
      AppLanguage.chineseTraditional => zhHant,
      _ => const {},
    };
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
