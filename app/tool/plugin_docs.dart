// Writes docs/plugin-api.md: the guide the plugin editor's Help shows (assets/help/plugins.md)
// followed by the API's reference, made from the list the app itself answers from (PluginApi).
// test/in_step_test.dart fails until it has been run.
// Run from app/: `dart run tool/plugin_docs.dart` (`make plugin-docs` does).
import 'dart:io';

import 'package:score_engine/src/plugin/api.dart';

/// docs/plugin-api.md as it should be, from the [guide].
String pluginDocs(String guide) => '<!-- Made by app/tool/plugin_docs.dart (make plugin-docs): edit app/assets/help/plugins.md and PluginApi instead. -->\n'
    '${PluginApi.docs(guide)}';

void main() {
  final file = File('../docs/plugin-api.md')..writeAsStringSync(pluginDocs(File('assets/help/plugins.md').readAsStringSync()));
  stdout.writeln('${file.path}: API level ${PluginApi.level}');
}
