import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

/// Curator's own packages of one [kind] ("extension", "plugin"): kept as folders under
/// `assets/<kind>s/<id>/` (the files a package's zip holds), bundled with the app and read once
/// as it starts.
class BundledPackages<T extends ScriptPackage> {
  BundledPackages(this.kind, this._read, this._compare);

  final String kind;
  final T Function(Map<String, Uint8List> files) _read;
  final Comparator<T> _compare;

  /// In the order they are listed.
  List<T> get packages => _packages;
  List<T> _packages = const [];

  T? byId(String id) {
    for (final p in _packages) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Takes them as files: each package's id → its files by path. (A test's way in: it reads
  /// the folders from disk.)
  void set(Map<String, Map<String, Uint8List>> folders) {
    final packages = <T>[];
    for (final MapEntry(key: id, value: files) in folders.entries) {
      try {
        final p = _read(files);
        if (p.id != id) throw FormatException('its id is ${p.id}');
        packages.add(p);
      } on FormatException catch (e) {
        debugPrint('Couldn’t read the bundled $kind $id: ${e.message}');
      }
    }
    _packages = List.unmodifiable(packages..sort(_compare));
  }

  /// Reads them from the app's assets.
  Future<void> load(AssetBundle bundle) async {
    final folder = 'assets/${kind}s/';
    final folders = <String, Map<String, Uint8List>>{};
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(bundle);
      for (final key in manifest.listAssets()) {
        if (!key.startsWith(folder)) continue;
        final rest = key.substring(folder.length), slash = rest.indexOf('/');
        if (slash <= 0) continue;
        final data = await bundle.load(key);
        (folders[rest.substring(0, slash)] ??= {})[rest.substring(slash + 1)] = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      }
    } on Object catch (e) {
      debugPrint('Couldn’t read the bundled ${kind}s: $e');
    }
    set(folders);
  }
}
