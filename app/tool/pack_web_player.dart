// Zips the web player `flutter build web -t lib/web_player/main.dart` made in build/web_player
// into assets/web_player/player.zip, which File ▸ Export to Web… copies beside a page. What a
// page never loads stays out: the renderers a JavaScript build doesn't use, debug symbols, and
// the app's own assets (the sample project, the player itself, the desktop's sound engine).
// Run from app/: `dart run tool/pack_web_player.dart` (`make web-player` does).
import 'dart:io';

import 'package:archive/archive_io.dart';

const _left = [
  r'\.symbols$',
  r'^canvaskit/(skwasm|wimp)',
  r'^canvaskit/webparagraph/',
  r'^assets/assets/(demo|web_player)/',
  r'^assets/packages/flutter_soloud/',
  r'^\.last_build_id$',
];

void main() {
  final build = Directory('build/web_player');
  if (!build.existsSync()) {
    stderr.writeln('No build/web_player: build the web player first (make web-player).');
    exit(1);
  }
  final left = [for (final p in _left) RegExp(p)];
  final archive = Archive();
  for (final file in build.listSync(recursive: true).whereType<File>()) {
    final name = file.path.substring(build.path.length + 1).replaceAll(r'\', '/');
    if (left.any((p) => p.hasMatch(name))) continue;
    archive.add(ArchiveFile.bytes(name, file.readAsBytesSync()));
  }
  final out = File('assets/web_player/player.zip')..createSync(recursive: true);
  out.writeAsBytesSync(ZipEncoder().encodeBytes(archive));
  stdout.writeln('${out.path}: ${archive.length} files, ${(out.lengthSync() / (1 << 20)).toStringAsFixed(1)} MB');
}
