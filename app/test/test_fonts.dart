// Real fonts for offscreen screenshots (tests otherwise draw text as boxes).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show FontLoader;

/// Flutter's own copy of Roboto and the Material icons, wherever Flutter is installed: the test
/// runs inside Flutter's cache, so walk up from it to the SDK root.
final String _materialFonts = () {
  var dir = File(Platform.resolvedExecutable).parent;
  while (dir.parent.path != dir.path && !File('${dir.path}/bin/flutter').existsSync()) {
    dir = dir.parent;
  }
  final root = Platform.environment['FLUTTER_ROOT'] ?? dir.path;
  return '$root/bin/cache/artifacts/material_fonts';
}();

Future<void> _font(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final path in paths) {
    if (File(path).existsSync()) loader.addFont(Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
  }
  await loader.load();
}

/// Loads Roboto (also as the test's default family), the Material icons and the score fonts.
Future<void> loadTestFonts() async {
  final roboto = ['$_materialFonts/Roboto-Regular.ttf', '$_materialFonts/Roboto-Medium.ttf'];
  await _font('Roboto', roboto);
  await _font('FlutterTest', roboto); // what a TextStyle without a family resolves to in tests
  await _font('MaterialIcons', ['$_materialFonts/MaterialIcons-Regular.otf']);
  for (final f in ['Bravura.otf', 'Leland.otf', 'Petaluma.otf', 'Leipzig.ttf', 'Gootville.otf']) {
    await _font('packages/score_engine/${f.split('.').first}', ['../packages/score_engine/assets/fonts/$f']);
  }
  await _font('packages/score_engine/Academico',
      [for (final s in ['Regular', 'Italic', 'Bold', 'BoldItalic']) '../packages/score_engine/assets/fonts/Academico-$s.otf']);
}
