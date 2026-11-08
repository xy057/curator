import 'dart:async';
import 'dart:io';

import 'package:curated_score/l10n/l10n.dart';
import 'package:curated_score/scratch_space.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every test file has the translations, as the app does, and cleans up its scratch folder, as the
/// app does when it quits. A tap on a widget something else covers fails, rather than landing
/// elsewhere with a warning.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  WidgetController.hitTestWarningShouldBeFatal = true;
  await Strings.load((path) => File(path).readAsString()); // as the app does as it starts
  await testMain();
  tearDownAll(ScratchSpace.close);
}
