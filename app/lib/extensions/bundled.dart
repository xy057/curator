import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

import '../bundled_packages.dart';

/// Curator's own extensions that are packages: kept as folders under `assets/extensions/<id>/`
/// (an extension's files as a `.cpe` holds them: extension.json, connect.json, src/…), bundled
/// with the app and read once as it starts. They change with the app, so a project names them
/// and never carries them.
abstract final class BundledExtensions {
  /// The order they are listed in; one not named here follows, by id.
  static const _order = ['attachImage', 'captions', 'chapters', 'tonality'];

  static int _place(ExtensionPackage p) => switch (_order.indexOf(p.id)) { -1 => _order.length, final i => i };

  static final _bundled = BundledPackages<ExtensionPackage>('extension', ExtensionPackage.fromFiles,
      (a, b) => switch (_place(a).compareTo(_place(b))) { 0 => a.id.compareTo(b.id), final by => by });

  /// In the order Project Settings lists them.
  static List<ExtensionPackage> get packages => _bundled.packages;
  static ExtensionPackage? byId(String id) => _bundled.byId(id);
  static void set(Map<String, Map<String, Uint8List>> folders) => _bundled.set(folders);
  static Future<void> load(AssetBundle bundle) => _bundled.load(bundle);
}
