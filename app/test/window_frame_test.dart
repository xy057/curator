import 'package:curated_score/app_settings.dart';
import 'package:curated_score/window_chrome.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('a window frame is kept, read back, and merged with a maximised runner answer', () async {
    const frame = WindowFrame(-1200, 40, 1440, 900, maximized: true);
    expect(WindowFrame.parse(frame.encode()), frame);
    expect(WindowFrame.parse('1,2,0,4'), isNull);
    expect(WindowFrame.parse('junk'), isNull);
    // Linux, maximised: no size, the one from before kept.
    expect(WindowFrame.fromMap({'maximized': true}, previous: const WindowFrame(5, 6, 1000, 700)),
        const WindowFrame(5, 6, 1000, 700, maximized: true));
    expect(WindowFrame.fromMap({'maximized': true}), isNull);

    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load();
    expect(settings.rememberWindow, isTrue);
    expect(settings.windowFrame, isNull);
    settings.rememberWindow = false;
    await settings.saveWindowFrame(frame);
    final again = await AppSettings.load();
    expect(again.rememberWindow, isFalse);
    expect(again.windowFrame, frame);
  });
}
