import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

import '../bundled_packages.dart';

/// Curator's own plugins: kept as folders under `assets/plugins/<id>/` (a plugin's files as a
/// `.cgp` holds them: plugin.json, src/main.lua…), bundled with the app and read once as it
/// starts. Each is off until its switch is turned (Settings ▸ Plugins), and is an example of
/// how one is written: the docs carry them.
abstract final class BundledPlugins {
  static final _bundled = BundledPackages<PluginPackage>('plugin', PluginPackage.fromFiles, (a, b) => a.name.compareTo(b.name));

  /// In the order Settings lists them: by name.
  static List<PluginPackage> get packages => _bundled.packages;
  static PluginPackage? byId(String id) => _bundled.byId(id);
  static void set(Map<String, Map<String, Uint8List>> folders) => _bundled.set(folders);
  static Future<void> load(AssetBundle bundle) => _bundled.load(bundle);
}
