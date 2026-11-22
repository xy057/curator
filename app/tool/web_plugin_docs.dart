// Writes docs/web-plugin-api.md: the guide to writing a web plugin (assets/help/web-plugins.md)
// followed by the API as TypeScript declares it (assets/web_plugins/curator-web.d.ts), whole.
// test/in_step_test.dart fails until it has been run.
// Run from app/: `dart run tool/web_plugin_docs.dart` (`make web-plugin-docs` does).
import 'dart:io';

import 'package:score_engine/src/web_plugin/api.dart';

/// docs/web-plugin-api.md as it should be, from the [guide] and the [types].
String webPluginDocs(String guide, String types) =>
    '<!-- Made by app/tool/web_plugin_docs.dart (make web-plugin-docs): edit app/assets/help/web-plugins.md and app/assets/web_plugins/curator-web.d.ts instead. -->\n'
    '${WebPluginApi.docs(guide, types)}';

void main() {
  final file = File('../docs/web-plugin-api.md')
    ..writeAsStringSync(webPluginDocs(File('assets/help/web-plugins.md').readAsStringSync(), File('assets/web_plugins/${WebPluginApi.typesName}').readAsStringSync()));
  stdout.writeln('${file.path}: API level ${WebPluginApi.level}');
}
