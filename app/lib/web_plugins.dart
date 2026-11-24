import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

import 'app_folders.dart';
import 'app_settings.dart';
import 'bundled_packages.dart';
import 'web_page.dart';

/// Curator's own web plugins: kept as folders under `assets/web_plugins/<id>/` (a plugin's
/// files as a `.cwp` holds them: plugin.json, main.js, src/main.ts…), bundled with the app.
/// Each is an example of how one is written: the docs carry them. Their `main.js` is built
/// from their TypeScript by `make web-plugins`, and kept in git.
abstract final class BundledWebPlugins {
  static final _bundled = BundledPackages<WebPluginPackage>('web_plugin', WebPluginPackage.fromFiles, (a, b) => a.name.compareTo(b.name));

  /// In the order they are listed: by name.
  static List<WebPluginPackage> get packages => _bundled.packages;
  static WebPluginPackage? byId(String id) => _bundled.byId(id);
  static void set(Map<String, Map<String, Uint8List>> folders) => _bundled.set(folders);
  static Future<void> load(AssetBundle bundle) => _bundled.load(bundle);
}

/// Web plugins: what changes the pages File ▸ Export to Web… writes (its Plugins). Which there
/// are (Curator's own, [BundledWebPlugins], and those the user added, kept as `.cwp` files in
/// the app's Web Plugins folder), which go into a page ([AppSettings.webPluginsOn]) and how
/// each is set ([AppSettings.webPluginSettings]). The app runs none of their code: a page does.
class WebPlugins extends ChangeNotifier {
  /// [folder] is where added plugins are kept; without one they are kept until the app closes
  /// (a test's).
  WebPlugins(this.settings, {this.folder, Iterable<WebPluginPackage> installed = const [], Map<String, String> files = const {}}) : _files = {...files} {
    for (final p in installed) {
      _installed[p.id] = p;
    }
  }

  /// Curator's own, and the plugins in the app's Web Plugins folder ([AppFolders]). One that
  /// doesn't read is left where it is, and isn't listed.
  static Future<WebPlugins> load(AppSettings settings) async {
    if (BundledWebPlugins.packages.isEmpty) await BundledWebPlugins.load(rootBundle);
    final installed = <WebPluginPackage>[], files = <String, String>{};
    Directory? folder;
    try {
      folder = AppFolders.folder('Web Plugins');
      for (final file in folder.listSync().whereType<File>().toList()..sort((a, b) => a.path.compareTo(b.path))) {
        if (!file.path.toLowerCase().endsWith('.${WebPluginPackage.fileExtension}')) continue;
        try {
          final package = WebPluginPackage.read(await file.readAsBytes());
          if (!WebPluginPackage.isThirdPartyId(package.id) || files.containsKey(package.id)) continue;
          installed.add(package);
          files[package.id] = file.path;
        } on Object catch (e) {
          debugPrint('Couldn’t read the web plugin ${file.path}: $e');
        }
      }
    } on Object catch (e) {
      debugPrint('Couldn’t read the web plugins: $e');
    }
    return WebPlugins(settings, folder: folder, installed: installed, files: files);
  }

  final AppSettings settings;
  final Directory? folder;

  /// Where each added plugin's file is, by id.
  final Map<String, String> _files;
  final _installed = <String, WebPluginPackage>{};

  /// Curator's own, then the ones added, by name.
  List<WebPluginPackage> get packages => [
        ...BundledWebPlugins.packages,
        ..._installed.values.toList()..sort((a, b) => switch (a.name.toLowerCase().compareTo(b.name.toLowerCase())) { 0 => a.id.compareTo(b.id), final by => by }),
      ];

  WebPluginPackage? package(String id) => _installed[id] ?? BundledWebPlugins.byId(id);

  /// Whether plugin [id] is Curator's own: it changes with the app, and is never removed.
  bool isOwn(String id) => BundledWebPlugins.byId(id) != null;

  /// Whether plugin [id] goes into the pages exported.
  bool isOn(String id) => settings.webPluginsOn.contains(id);

  void turn(String id, bool on) {
    settings.setWebPluginOn(id, on);
    notifyListeners();
  }

  /// Adds [package] (in place of the one with its id), kept as a file in the Web Plugins
  /// folder, and on: it was added to be used. A [FileSystemException] when it can't be kept.
  void add(WebPluginPackage package) {
    if (!WebPluginPackage.isThirdPartyId(package.id)) throw const WordsFormatException(Words('The plugin has no id Curator can use.'));
    if (folder case final folder?) {
      final path = _files[package.id] ?? '${folder.path}${Platform.pathSeparator}${package.id}.${WebPluginPackage.fileExtension}';
      File(path).writeAsBytesSync(package.write(), flush: true);
      _files[package.id] = path;
    }
    _installed[package.id] = package;
    settings.setWebPluginOn(package.id, true);
    notifyListeners();
  }

  /// Takes plugin [id] out of the app, its file with it; how it was set stays, for when it is
  /// added again.
  void remove(String id) {
    if (_installed.remove(id) == null) return;
    if (_files.remove(id) case final path?) {
      try {
        File(path).deleteSync();
      } on FileSystemException catch (e) {
        debugPrint('Couldn’t delete the web plugin $path: $e');
      }
    }
    settings.setWebPluginOn(id, false);
    notifyListeners();
  }

  /// [package]'s settings as they are set, by id: each its own value until it is set.
  Map<String, Object> settingsOf(WebPluginPackage package) => package.settingsWith(settings.webPluginSettings(package.id));

  void set(WebPluginPackage package, String setting, Object value) {
    settings.setWebPluginSettings(package.id, {...settingsOf(package), setting: value});
    notifyListeners();
  }

  /// The plugins that go into a page, in the order listed, each with how it is set.
  List<({WebPluginPackage package, WebPagePlugin plugin})> get chosen => [
        for (final p in packages)
          if (isOn(p.id) && p.api <= WebPluginApi.level) (package: p, plugin: WebPagePlugin.of(p, settings.webPluginSettings(p.id))),
      ];
}
