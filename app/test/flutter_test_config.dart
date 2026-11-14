import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:curated_score/extensions/bundled.dart';
import 'package:curated_score/l10n/l10n.dart';
import 'package:curated_score/scratch_space.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every test file has the translations, as the app does, and cleans up its scratch folder, as the
/// app does when it quits. A tap on a widget something else covers fails, rather than landing
/// elsewhere with a warning.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  WidgetController.hitTestWarningShouldBeFatal = true;
  await Strings.load([for (final f in Directory('assets/l10n').listSync()) f.path], (path) => File(path).readAsString()); // as the app does as it starts
  loadBundledExtensions();
  await testMain();
  tearDownAll(ScratchSpace.close);
}

/// Curator's own extensions, read from assets/extensions as the app reads them from its bundle.
void loadBundledExtensions() {
  final folders = <String, Map<String, Uint8List>>{};
  final root = Directory('assets/extensions');
  for (final dir in root.existsSync() ? root.listSync().whereType<Directory>() : const <Directory>[]) {
    final id = dir.uri.pathSegments.lastWhere((s) => s.isNotEmpty), files = <String, Uint8List>{};
    for (final file in dir.listSync(recursive: true).whereType<File>()) {
      final path = file.path.substring(dir.path.length + 1).replaceAll(r'\', '/');
      if (path.split('/').any((part) => part.startsWith('.'))) continue; // .DS_Store
      files[path] = file.readAsBytesSync();
    }
    folders[id] = files;
  }
  BundledExtensions.set(folders);
}
