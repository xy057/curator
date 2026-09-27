import 'dart:async';

import 'package:curated_score/scratch_space.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every test file cleans up its scratch folder, as the app does when it quits.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await testMain();
  tearDownAll(ScratchSpace.close);
}
