import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../extension/package.dart';
import '../script.dart';
import '../words.dart';

/// A setting of a web plugin's the exporter sets (plugin.json's `settings`): a text, a switch
/// or a choice among [options], [value] until it is set.
@immutable
class WebPluginSetting {
  const WebPluginSetting({required this.id, required this.label, required this.type, required this.value, this.options = const []});
  final String id, label;

  /// "text", "switch" or "choice".
  final String type;

  /// A text's and a choice's: a String (a choice's, one of its options' values); a switch's: a bool.
  final Object value;
  final List<({String value, String label})> options;

  /// [given] if it is a value this setting can have, else its own.
  Object valid(Object? given) => switch (type) {
        'switch' => given is bool ? given : value,
        'choice' => given is String && options.any((o) => o.value == given) ? given : value,
        _ => given is String ? given : value,
      };

  /// The setting [json] writes; null when it writes none.
  static WebPluginSetting? read(Object? json) {
    if (json case {'id': final String id, 'label': final String label} when RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(id)) {
      final type = switch (json['type']) { 'switch' => 'switch', 'choice' => 'choice', _ => 'text' };
      final options = [
        if (json['options'] case final List<Object?> list)
          for (final o in list)
            if (o case {'value': final String value}) (value: value, label: switch (o['label']) { final String l => l, _ => value }),
      ];
      final value = json['value'];
      return switch (type) {
        'switch' => WebPluginSetting(id: id, label: label, type: type, value: value is bool && value),
        'choice' when options.isNotEmpty => WebPluginSetting(
            id: id, label: label, type: type, value: value is String && options.any((o) => o.value == value) ? value : options.first.value, options: options),
        'choice' => null,
        _ => WebPluginSetting(id: id, label: label, type: type, value: value is String ? value : ''),
      };
    }
    return null;
  }
}

/// A web plugin as it travels: a `.cwp` file (Curator Web Plugin), a zip archive holding
///
///     mimetype          application/x-curator-web-plugin (stored first, uncompressed)
///     plugin.json       what it is: id, name, version, summary, the API level it needs, its settings ([manifest])
///     main.js           its code as a page runs it: an ES module whose default export the player calls ([main])
///     src/*             what main.js is built from, its TypeScript ([sources]): for those who read it
///     locales/*.json    its texts in other languages, `{"English": "translation"}` ([locales])
///     assets/*          files of its own a page can fetch ([assets])
///     README.md         what it does ([readme])
///
/// Where a plugin (a `.cgp`) changes the app, a web plugin changes the pages File ▸ Export to
/// Web… writes: the app keeps it, and the export puts it beside a page's score ([pageFiles]),
/// where the web player runs it. A browser runs JavaScript, so the package carries its code
/// built; nothing here reads it. Everything is read as it is and written back as it was.
@immutable
class WebPluginPackage with PackageManifest implements ScriptPackage {
  WebPluginPackage({
    required Map<String, Object?> manifest,
    required this.main,
    Map<String, String> sources = const {},
    Map<String, Map<String, String>> locales = const {},
    Map<String, Uint8List> assets = const {},
    this.readme,
  })  : manifest = Map.unmodifiable(manifest),
        sources = Map.unmodifiable(sources),
        locales = Map.unmodifiable(locales),
        assets = Map.unmodifiable(assets);

  static const mimeType = 'application/x-curator-web-plugin';
  static const fileExtension = 'cwp';

  /// The file a page runs.
  static const entry = 'main.js';

  /// `plugin.json`, whole.
  @override
  final Map<String, Object?> manifest;

  /// [entry], as text.
  final String main;

  /// Each file under `src/` by its path there ("main.ts").
  @override
  final Map<String, String> sources;
  @override
  final Map<String, Map<String, String>> locales;
  @override
  final Map<String, Uint8List> assets;
  @override
  final String? readme;

  /// What the exporter sets for it, in the order written; one that isn't a setting is left out.
  late final List<WebPluginSetting> settings = List.unmodifiable([
    if (manifest['settings'] case final List<Object?> list)
      for (final s in list) ?WebPluginSetting.read(s),
  ]);

  /// Its settings by id: each as [given] has it where that is a value it can have, else its own.
  Map<String, Object> settingsWith(Object? given) => {
        for (final s in settings) s.id: s.valid(given is Map<String, Object?> ? given[s.id] : null),
      };

  static bool isThirdPartyId(String id) => ExtensionPackage.isThirdPartyId(id);
  static bool isBuiltInId(String id) => ExtensionPackage.isBuiltInId(id);

  // MARK: Files

  static const _encoder = JsonEncoder.withIndent('  ');

  /// Every file of it by its path in the archive, in the order written (the mimetype aside).
  @override
  late final Map<String, Uint8List> files = Map.unmodifiable({
    'plugin.json': PackageFiles.bytes('${_encoder.convert(manifest)}\n'),
    if (readme != null) 'README.md': PackageFiles.bytes(readme!),
    ...pageFiles,
    for (final path in sources.keys.toList()..sort()) 'src/$path': PackageFiles.bytes(sources[path]!),
  });

  /// What a page carries of it, by path in its folder there: its code, its texts, its assets.
  late final Map<String, Uint8List> pageFiles = Map.unmodifiable({
    entry: PackageFiles.bytes(main),
    for (final locale in locales.keys.toList()..sort()) 'locales/$locale.json': PackageFiles.bytes('${_encoder.convert(locales[locale])}\n'),
    for (final path in assets.keys.toList()..sort()) 'assets/$path': assets[path]!,
  });

  /// What it holds, as one number: two packages holding the same have the same.
  late final String digest = PackageFiles.digest(files);

  @override
  bool operator ==(Object other) => other is WebPluginPackage && other.digest == digest;
  @override
  int get hashCode => digest.hashCode;

  /// A package from its files by path, as [files] lists them. What is wrong with it is a
  /// [FormatException] that says so.
  factory WebPluginPackage.fromFiles(Map<String, Uint8List> files) {
    final notOne = WordsFormatException(PackageKind.webPlugin.notOne);
    if (!files.containsKey('plugin.json')) throw notOne;
    final manifest = PackageFiles.json(files, 'plugin.json');
    if (manifest is! Map<String, Object?> || (manifest['format'] ?? mimeType) != mimeType) throw notOne;
    final id = manifest['id'];
    if (id is! String || !(isThirdPartyId(id) || isBuiltInId(id))) throw const WordsFormatException(Words('The plugin has no id Curator can use.'));
    if (!files.containsKey(entry)) throw const WordsFormatException(Words('The plugin has no main.js: build it first.'));
    final (sources: _, :locales, :assets) = PackageFiles.sorted(files, what: PackageKind.webPlugin);
    return WebPluginPackage(
      manifest: manifest,
      main: PackageFiles.text(files, entry),
      sources: {
        for (final path in files.keys)
          if (path.startsWith('src/')) path.substring(4): PackageFiles.text(files, path),
      },
      locales: locales,
      assets: assets,
      readme: files.containsKey('README.md') ? PackageFiles.text(files, 'README.md') : null,
    );
  }

  /// The package a `.cwp` file's [bytes] hold. A [FormatException] says what is wrong with one.
  factory WebPluginPackage.read(Uint8List bytes) => WebPluginPackage.fromFiles(PackageFiles.unzip(bytes, what: PackageKind.webPlugin));

  /// It as a `.cwp` file: the same bytes for the same package, whenever it is written.
  Uint8List write() => _written;

  late final Uint8List _written = PackageFiles.zip(mimeType, files);
}
