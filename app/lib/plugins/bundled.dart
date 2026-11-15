import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

/// Curator's own plugins: kept as folders under `assets/plugins/<id>/` (a plugin's files as a
/// `.cgp` holds them: plugin.json, src/main.lua…), bundled with the app and read once as it
/// starts. Each is off until its switch is turned (Settings ▸ Plugins), and is an example of
/// how one is written: the docs carry them.
abstract final class BundledPlugins {
  static const _folder = 'assets/plugins/';

  /// In the order Settings lists them: by name.
  static List<PluginPackage> get packages => _packages;
  static List<PluginPackage> _packages = const [];

  static PluginPackage? byId(String id) {
    for (final p in _packages) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Takes them as files: each plugin's id → its files by path. (A test's way in: it reads
  /// the folders from disk.)
  static void set(Map<String, Map<String, Uint8List>> folders) {
    final packages = <PluginPackage>[];
    for (final MapEntry(key: id, value: files) in folders.entries) {
      try {
        final p = PluginPackage.fromFiles(files);
        if (p.id != id) throw FormatException('its id is ${p.id}');
        packages.add(p);
      } on FormatException catch (e) {
        debugPrint('Couldn’t read the bundled plugin $id: ${e.message}');
      }
    }
    packages.sort((a, b) => a.name.compareTo(b.name));
    _packages = List.unmodifiable(packages);
  }

  /// Reads them from the app's assets.
  static Future<void> load(AssetBundle bundle) async {
    final folders = <String, Map<String, Uint8List>>{};
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(bundle);
      for (final key in manifest.listAssets()) {
        if (!key.startsWith(_folder)) continue;
        final rest = key.substring(_folder.length), slash = rest.indexOf('/');
        if (slash <= 0) continue;
        final data = await bundle.load(key);
        (folders[rest.substring(0, slash)] ??= {})[rest.substring(slash + 1)] = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      }
    } on Object catch (e) {
      debugPrint('Couldn’t read the bundled plugins: $e');
    }
    set(folders);
  }
}
