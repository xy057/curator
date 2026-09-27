import 'package:curated_score/window_chrome.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the window title names the document the way each platform does', () {
    expect(WindowChrome.titleFor(name: null, edited: false, platform: TargetPlatform.macOS), 'Curated Score');
    // macOS: just the name; the edited dot is in the close button.
    expect(WindowChrome.titleFor(name: 'Intro', edited: true, platform: TargetPlatform.macOS), 'Intro');
    expect(WindowChrome.titleFor(name: 'Intro', edited: true, platform: TargetPlatform.windows), '• Intro — Curated Score');
    expect(WindowChrome.titleFor(name: 'Intro', edited: false, platform: TargetPlatform.linux), 'Intro — Curated Score');
  });
}
