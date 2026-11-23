// Writes docs/lane-script.md: the guide the script's Help shows (assets/help/script.md) followed
// by every statement of the language, from the list the editor itself offers from
// (LaneScriptApi). test/in_step_test.dart fails until it has been run.
// Run from app/: `dart run tool/script_docs.dart` (`make script-docs` does).
import 'dart:io';

import 'package:score_engine/src/lane_script_api.dart';

/// docs/lane-script.md as it should be, from the [guide].
String laneScriptDocs(String guide) => '<!-- Made by app/tool/script_docs.dart (make script-docs): edit app/assets/help/script.md and LaneScriptApi instead. -->\n'
    '${LaneScriptApi.docs(guide)}';

void main() {
  final file = File('../docs/lane-script.md')..writeAsStringSync(laneScriptDocs(File('assets/help/script.md').readAsStringSync()));
  stdout.writeln('${file.path}: ${LaneScriptApi.statements.length} statements');
}
