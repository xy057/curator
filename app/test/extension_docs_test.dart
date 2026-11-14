// docs/extension-api.md is made from the guide and the API's own list: it says what the app does.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/extension_docs.dart';

void main() {
  test('docs/extension-api.md is the guide and the API as they are now', () {
    expect(File('../docs/extension-api.md').readAsStringSync(), extensionDocs(File('assets/help/extensions.md').readAsStringSync()),
        reason: 'run `make extension-docs`');
  });
}
