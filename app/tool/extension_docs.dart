// Writes docs/extension-api.md: the guide the extension editor's Help shows
// (assets/help/extensions.md) followed by the API's reference, made from the list the app
// itself answers from (ExtensionApi). test/in_step_test.dart fails until it has been run.
// Run from app/: `dart run tool/extension_docs.dart` (`make extension-docs` does).
import 'dart:io';

import 'package:score_engine/src/extension/api.dart';

/// docs/extension-api.md as it should be, from the [guide].
String extensionDocs(String guide) => '<!-- Made by app/tool/extension_docs.dart (make extension-docs): edit app/assets/help/extensions.md and ExtensionApi instead. -->\n'
    '${ExtensionApi.docs(guide)}';

void main() {
  final file = File('../docs/extension-api.md')..writeAsStringSync(extensionDocs(File('assets/help/extensions.md').readAsStringSync()));
  stdout.writeln('${file.path}: API level ${ExtensionApi.level}');
}
