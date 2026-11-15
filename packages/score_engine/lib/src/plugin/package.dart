import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../extension/package.dart';
import '../script.dart';

/// A plugin as it travels: a `.cgp` file (Curator Global Plugin), a zip archive holding
///
///     mimetype          application/x-curator-plugin (stored first, uncompressed)
///     plugin.json       what it is: id, name, version, summary, the API level it needs ([manifest])
///     src/main.lua      its code: run once as the app starts, or as it is turned on
///     src/*.lua         more of it, each a module `require` gives ([sources], by path under src/)
///     locales/*.json    its texts in other languages, `{"English": "translation"}` ([locales])
///     assets/*          files of its own it can read ([assets])
///     README.md         what it does, shown in the editor ([readme])
///
/// Where an extension (a `.cpe`) belongs to a project, a plugin belongs to the app: it adds to
/// and changes the app itself, in every project. Everything is read as it is and written back
/// as it was: a key this build doesn't know stays in the file.
@immutable
class PluginPackage with PackageManifest implements ScriptPackage {
  PluginPackage({
    required Map<String, Object?> manifest,
    Map<String, String> sources = const {},
    Map<String, Map<String, String>> locales = const {},
    Map<String, Uint8List> assets = const {},
    this.readme,
  })  : manifest = Map.unmodifiable(manifest),
        sources = Map.unmodifiable(sources),
        locales = Map.unmodifiable(locales),
        assets = Map.unmodifiable(assets);

  static const mimeType = 'application/x-curator-plugin';
  static const fileExtension = 'cgp';

  /// The file that is run: the rest are its to `require`.
  static const entry = 'main.lua';

  /// A new plugin: one file that adds one command, in a menu of its own.
  factory PluginPackage.blank({required String id, required String name}) => PluginPackage(
        manifest: {'format': mimeType, 'id': id, 'name': name, 'version': '1.0.0', 'summary': '', 'api': 1},
        sources: const {
          entry: '-- Runs when Curator starts, and when this plugin is turned on.\n'
              'app.command{\n'
              '  title = "Hello",\n'
              '  menu = "Plugins",\n'
              '  run = function()\n'
              '    ui.message("Hello from " .. curator.name)\n'
              '  end,\n'
              '}\n',
        },
        readme: '# $name\n',
      );

  /// `plugin.json`, whole.
  @override
  final Map<String, Object?> manifest;
  @override
  final Map<String, String> sources;
  @override
  final Map<String, Map<String, String>> locales;
  @override
  final Map<String, Uint8List> assets;
  @override
  final String? readme;

  /// Whether [id] is one a plugin from elsewhere may have, or one of Curator's own may.
  static bool isThirdPartyId(String id) => ExtensionPackage.isThirdPartyId(id);
  static bool isBuiltInId(String id) => ExtensionPackage.isBuiltInId(id);

  PluginPackage copyWith({Map<String, Object?>? manifest, Map<String, String>? sources, Map<String, Map<String, String>>? locales, Map<String, Uint8List>? assets, String? readme}) =>
      PluginPackage(
        manifest: manifest ?? this.manifest,
        sources: sources ?? this.sources,
        locales: locales ?? this.locales,
        assets: assets ?? this.assets,
        readme: readme ?? this.readme,
      );

  // MARK: Files

  static const _encoder = JsonEncoder.withIndent('  ');

  /// Every file of it by its path in the archive, in the order written (the mimetype aside).
  @override
  late final Map<String, Uint8List> files = Map.unmodifiable({
    'plugin.json': PackageFiles.bytes('${_encoder.convert(manifest)}\n'),
    if (readme != null) 'README.md': PackageFiles.bytes(readme!),
    for (final path in sources.keys.toList()..sort()) 'src/$path': PackageFiles.bytes(sources[path]!),
    for (final locale in locales.keys.toList()..sort()) 'locales/$locale.json': PackageFiles.bytes('${_encoder.convert(locales[locale])}\n'),
    for (final path in assets.keys.toList()..sort()) 'assets/$path': assets[path]!,
  });

  /// What it holds, as one number: two packages holding the same have the same.
  late final String digest = PackageFiles.digest(files);

  @override
  bool operator ==(Object other) => other is PluginPackage && other.digest == digest;
  @override
  int get hashCode => digest.hashCode;

  /// A package from its files by path, as [files] lists them. What is wrong with it is a
  /// [FormatException] that says so.
  factory PluginPackage.fromFiles(Map<String, Uint8List> files) {
    if (!files.containsKey('plugin.json')) throw const FormatException('This isn’t a Curator plugin.');
    final manifest = PackageFiles.json(files, 'plugin.json');
    if (manifest is! Map<String, Object?> || (manifest['format'] ?? mimeType) != mimeType) throw const FormatException('This isn’t a Curator plugin.');
    final id = manifest['id'];
    if (id is! String || !(isThirdPartyId(id) || isBuiltInId(id))) throw const FormatException('The plugin has no id Curator can use.');
    final (:sources, :locales, :assets) = PackageFiles.sorted(files, what: 'plugin');
    return PluginPackage(
      manifest: manifest,
      sources: sources,
      locales: locales,
      assets: assets,
      readme: files.containsKey('README.md') ? PackageFiles.text(files, 'README.md') : null,
    );
  }

  /// The package a `.cgp` file's [bytes] hold. A [FormatException] says what is wrong with one.
  factory PluginPackage.read(Uint8List bytes) => PluginPackage.fromFiles(PackageFiles.unzip(bytes, what: 'plugin'));

  /// It as a `.cgp` file: the same bytes for the same package, whenever it is written.
  Uint8List write() => _written;

  late final Uint8List _written = PackageFiles.zip(mimeType, files);
}
