import 'dart:async';

import 'package:curated_score/scratch_space.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every test file cleans up its scratch folder, as the app does when it quits. A tap on a
/// widget something else covers fails, rather than landing elsewhere with a warning.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  WidgetController.hitTestWarningShouldBeFatal = true;
  await testMain();
  tearDownAll(ScratchSpace.close);
}
