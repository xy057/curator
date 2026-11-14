import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

/// Curator's own extensions that are packages: kept as folders under `assets/extensions/<id>/`
/// (an extension's files as a `.cpe` holds them: extension.json, connect.json, src/…), bundled
/// with the app and read once as it starts. They change with the app, so a project names them
/// and never carries them.
abstract final class BundledExtensions {
  static const _folder = 'assets/extensions/';

  /// In the order Project Settings lists them.
  static List<ExtensionPackage> get packages => _packages;
  static List<ExtensionPackage> _packages = const [];

  static ExtensionPackage? byId(String id) {
    for (final p in _packages) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// The order they are listed in; one not named here follows, by id.
  static const _order = ['attachImage', 'captions', 'chapters', 'tonality'];

  /// Takes them as files: each extension's id → its files by path. (A test's way in: it
  /// reads the folders from disk.)
  static void set(Map<String, Map<String, Uint8List>> folders) {
    final packages = <ExtensionPackage>[];
    for (final MapEntry(key: id, value: files) in folders.entries) {
      try {
        final p = ExtensionPackage.fromFiles(files);
        if (p.id != id) throw FormatException('its id is ${p.id}');
        packages.add(p);
      } on FormatException catch (e) {
        debugPrint('Couldn’t read the bundled extension $id: ${e.message}');
      }
    }
    int place(ExtensionPackage p) => switch (_order.indexOf(p.id)) { -1 => _order.length, final i => i };
    packages.sort((a, b) => switch (place(a).compareTo(place(b))) { 0 => a.id.compareTo(b.id), final by => by });
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
      debugPrint('Couldn’t read the bundled extensions: $e');
    }
    set(folders);
  }
}
