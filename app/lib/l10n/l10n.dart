import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

import 'po.dart';

/// The interface's language (Settings ▸ General ▸ Language): [system], [english], and one for
/// each translations file the app carries, `assets/l10n/<tag>.po` (Crowdin writes them), found
/// as the app starts ([Strings.load]); a file with nothing translated yet isn't one.
///
/// Text is written in US English in the code, and translated where it is shown: `'Open Sample'.tr`,
/// or `'Bar {n}'.fill({'n': 12})` for text with values in it (the placeholders are the
/// translation's to place). Labels that also name things (a settings page, an enum's label) stay
/// English where they are kept and are translated where they are drawn, so a string can go through
/// [tr] twice; one a language has no entry for stays English.
final class AppLanguage {
  const AppLanguage._(this.tag);

  /// The one [tag] names (`ja`, `ko-KR`, `zh-Hans`; `_` as Crowdin's files have it is read as
  /// `-`), whether or not the app has it now.
  factory AppLanguage.of(String tag) => tag == '' ? system : AppLanguage._(_parse(tag).toLanguageTag());

  /// Its BCP 47 tag ('' for [system]).
  final String tag;

  static const system = AppLanguage._('');
  static const english = AppLanguage._('en');

  /// [system], [english], then each language the app has translations for, by tag.
  static List<AppLanguage> get values => [system, english, ...Strings._files.keys];

  /// The locales of the languages the interface has.
  static List<Locale> get locales => [for (final l in values) if (l != system) l._locale];

  /// How it is kept in the settings: [tag], `system` for [system]. Read by [named], which also
  /// reads the names the languages had when they were a fixed list.
  String get name => this == system ? 'system' : tag;

  static AppLanguage named(String? name) => switch (name) {
        null || 'system' => system,
        'english' => english,
        'chineseSimplified' => AppLanguage.of('zh-Hans'),
        'chineseTraditional' => AppLanguage.of('zh-Hant'),
        'japanese' => AppLanguage.of('ja'),
        final tag => AppLanguage.of(tag),
      };

  Locale get _locale => _parse(tag);

  /// Its name in its own language (the menu shows each so; [system]'s is translated where it is
  /// drawn), told apart by country or script where two would read the same.
  String get label {
    final own = _ownName;
    if (this == system || this == english) return own;
    final twin = values.any((l) => l != this && l._ownName == own);
    return twin ? '$own (${_locale.countryCode ?? _locale.scriptCode ?? tag})' : own;
  }

  String get _ownName {
    if (this == system) return 'System';
    final l = _locale;
    return _autonyms[tag] ??
        _autonyms['${l.languageCode}-${l.scriptCode ?? l.countryCode}'] ??
        _autonyms[l.languageCode] ??
        Strings._teams[this] ?? // the file's Language-Team (in English)
        tag;
  }

  /// Its translations' file (`assets/l10n/ko_KR.po`), or null for English and for a language
  /// the app hasn't.
  String? get file => Strings._files[this];

  /// The language it means now: [system] is the first of the system's preferred languages that
  /// the app has (by language, then by script or country where it has more than one: Chinese
  /// written in Taiwan, Hong Kong and Macau is Traditional); one the app no longer has is
  /// [system]'s.
  AppLanguage get resolved {
    if (this != system) return this == english || file != null ? this : system.resolved;
    for (final l in PlatformDispatcher.instance.locales) {
      final same = [for (final a in values) if (a != system && a._locale.languageCode == l.languageCode) a];
      if (same.isEmpty) continue;
      final script = l.scriptCode ??
          (l.languageCode == 'zh' ? (const {'TW', 'HK', 'MO'}.contains(l.countryCode) ? 'Hant' : 'Hans') : null);
      return same.firstWhere((a) => script != null && a._locale.scriptCode == script,
          orElse: () => same.firstWhere((a) => l.countryCode != null && a._locale.countryCode == l.countryCode,
              orElse: () => same.first));
    }
    return english;
  }

  Locale get locale => resolved._locale;

  @override
  bool operator ==(Object other) => other is AppLanguage && other.tag == tag;

  @override
  int get hashCode => tag.hashCode;

  @override
  String toString() => 'AppLanguage($name)';

  /// `ko_KR`, `zh-Hans`, `pt-BR` → its locale: a 4-letter part is the script, a 2-letter or
  /// 3-digit one the region.
  static Locale _parse(String tag) {
    final parts = tag.split(RegExp('[-_]'));
    String? script, country;
    for (final p in parts.skip(1)) {
      if (p.length == 4) script ??= p[0].toUpperCase() + p.substring(1).toLowerCase();
      if (p.length == 2 || RegExp(r'^\d{3}$').hasMatch(p)) country ??= p.toUpperCase();
    }
    return Locale.fromSubtags(languageCode: parts.first.toLowerCase(), scriptCode: script, countryCode: country);
  }
}

/// Languages by their names in themselves: by tag where a language comes in variants, else by
/// language. One not here is named by its file's Language-Team.
const _autonyms = {
  'en': 'English',
  'zh': '中文',
  'zh-Hans': '简体中文',
  'zh-Hant': '繁體中文',
  'zh-CN': '简体中文',
  'zh-SG': '简体中文（新加坡）',
  'zh-TW': '繁體中文',
  'zh-HK': '繁體中文（香港）',
  'zh-MO': '繁體中文（澳門）',
  'ja': '日本語',
  'ko': '한국어',
  'es': 'Español',
  'es-419': 'Español (Latinoamérica)',
  'es-MX': 'Español (México)',
  'pt': 'Português',
  'pt-BR': 'Português (Brasil)',
  'pt-PT': 'Português (Portugal)',
  'fr': 'Français',
  'fr-CA': 'Français (Canada)',
  'de': 'Deutsch',
  'it': 'Italiano',
  'nl': 'Nederlands',
  'ru': 'Русский',
  'uk': 'Українська',
  'be': 'Беларуская',
  'pl': 'Polski',
  'cs': 'Čeština',
  'sk': 'Slovenčina',
  'sl': 'Slovenščina',
  'hr': 'Hrvatski',
  'sr': 'Српски',
  'bs': 'Bosanski',
  'bg': 'Български',
  'mk': 'Македонски',
  'ro': 'Română',
  'hu': 'Magyar',
  'el': 'Ελληνικά',
  'tr': 'Türkçe',
  'sv': 'Svenska',
  'da': 'Dansk',
  'no': 'Norsk',
  'nb': 'Norsk bokmål',
  'nn': 'Norsk nynorsk',
  'fi': 'Suomi',
  'is': 'Íslenska',
  'et': 'Eesti',
  'lv': 'Latviešu',
  'lt': 'Lietuvių',
  'ga': 'Gaeilge',
  'cy': 'Cymraeg',
  'eu': 'Euskara',
  'ca': 'Català',
  'gl': 'Galego',
  'eo': 'Esperanto',
  'la': 'Latina',
  'af': 'Afrikaans',
  'sq': 'Shqip',
  'hy': 'Հայերեն',
  'ka': 'ქართული',
  'az': 'Azərbaycan',
  'kk': 'Қазақ',
  'uz': 'Oʻzbek',
  'mn': 'Монгол',
  'ar': 'العربية',
  'he': 'עברית',
  'fa': 'فارسی',
  'ur': 'اردو',
  'hi': 'हिन्दी',
  'bn': 'বাংলা',
  'pa': 'ਪੰਜਾਬੀ',
  'gu': 'ગુજરાતી',
  'mr': 'मराठी',
  'ta': 'தமிழ்',
  'te': 'తెలుగు',
  'kn': 'ಕನ್ನಡ',
  'ml': 'മലയാളം',
  'si': 'සිංහල',
  'ne': 'नेपाली',
  'th': 'ไทย',
  'lo': 'ລາວ',
  'km': 'ខ្មែរ',
  'my': 'မြန်မာ',
  'vi': 'Tiếng Việt',
  'id': 'Bahasa Indonesia',
  'ms': 'Bahasa Melayu',
  'fil': 'Filipino',
  'tl': 'Tagalog',
  'sw': 'Kiswahili',
  'am': 'አማርኛ',
};

/// The translations in use: [load] reads them all as the app starts, [use] switches them.
abstract final class Strings {
  static AppLanguage _language = AppLanguage.english;
  static Map<String, String> _table = const {};
  static final _tables = <AppLanguage, Map<String, String>>{};

  /// Each language the interface has, by tag, to its file; and the file's Language-Team.
  static Map<AppLanguage, String> _files = const {};
  static Map<AppLanguage, String> _teams = const {};

  /// `assets/l10n/<tag>.po`.
  static final _poFile = RegExp(r'(?:^|/)assets/l10n/([A-Za-z]{2,3}(?:[-_][A-Za-z0-9]+)*)\.po$');

  /// Reads the translations files among [paths] (the app's assets, or a folder's files in a
  /// test) with [read] (`rootBundle.loadString`; a file's contents): each with something
  /// translated is a language the interface has. One that can't be read or parsed is left out,
  /// and says so.
  static Future<void> load(Iterable<String> paths, Future<String> Function(String path) read) async {
    final files = <AppLanguage, String>{}, teams = <AppLanguage, String>{}, tables = <AppLanguage, Map<String, String>>{};
    await Future.wait([
      for (final path in paths)
        if (_poFile.firstMatch(path.replaceAll(r'\', '/')) case final m?)
          read(path).then((s) {
            final po = PoFile.parse(s), table = po.table, language = AppLanguage.of(m[1]!);
            if (table.isEmpty || language == AppLanguage.english) return;
            files[language] = path;
            tables[language] = table;
            if (po.header['Language-Team'] case final team? when team.isNotEmpty) teams[language] = team;
          }).catchError((Object e) => debugPrint('Couldn’t read $path: $e')),
    ]);
    final order = files.keys.toList()..sort((a, b) => a.tag.compareTo(b.tag));
    _files = {for (final l in order) l: files[l]!};
    _teams = teams;
    _tables
      ..clear()
      ..addAll(tables);
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
