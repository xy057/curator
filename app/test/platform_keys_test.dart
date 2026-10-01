// Hover texts name the keys the way the platform does: ⌘ ⌥ ⇧ ⌫ on macOS, Ctrl Alt Shift
// Backspace (in Windows order) elsewhere.
import 'package:curated_score/ui_kit.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows spelling', () {
    expect(windowsKeys('⌘W'), 'Ctrl+W');
    expect(windowsKeys('⇧⌘Z'), 'Ctrl+Shift+Z');
    expect(windowsKeys('⌥-drag'), 'Alt+drag');
    expect(windowsKeys('⌘-scroll'), 'Ctrl+scroll');
    expect(windowsKeys('⇧ adds · ⌘ toggles, no snap · ⌥ draws'), 'Shift adds · Ctrl toggles, no snap · Alt draws');
    expect(windowsKeys('←/→ move a bar (⇧ a beat)'), '←/→ move a bar (Shift a beat)');
    expect(windowsKeys('⌫'), 'Backspace');
  });

  test('shortcut follows the platform', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(shortcut('⌥-clicks'), '⌥-clicks');
    expect(shortcut('⇧⌘Z', 'Ctrl+Y'), '⇧⌘Z');
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(shortcut('⌥-clicks'), 'Alt+clicks');
    expect(shortcut('⇧⌘Z', 'Ctrl+Y'), 'Ctrl+Y');
    debugDefaultTargetPlatformOverride = null;
  });
}
