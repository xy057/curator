// At the window's minimum size (WindowChrome.minimumSize, which the runners set natively)
// nothing overflows, in either tab, with the selection-only buttons showing.
import 'dart:io';

import 'package:curated_score/audio_track.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/window_chrome.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_project.dart';

void main() {
  test('every runner sets the same minimum window size', () {
    final (w, h) = (WindowChrome.minimumSize.width.toInt(), WindowChrome.minimumSize.height.toInt());
    final runners = {
      'macos/Runner/MainFlutterWindow.swift': RegExp('NSSize\\(width: $w, height: $h\\)'),
      'windows/runner/flutter_window.cpp': RegExp('kMinimumWidth = $w;[\\s\\S]*kMinimumHeight = $h;'),
      'linux/runner/my_application.cc': RegExp('kMinimumWidth = $w;[\\s\\S]*kMinimumHeight = $h;'),
    };
    for (final MapEntry(key: file, value: pattern) in runners.entries) {
      expect(File(file).readAsStringSync(), matches(pattern), reason: file);
    }
  });

  testWidgets('the editor fits the minimum window size', (tester) async {
    tester.view.physicalSize = WindowChrome.minimumSize * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const CuratedScoreApp());
    await tester.pump(const Duration(seconds: 1));
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    await tester.tap(find.text('Try the sample'));
    for (var i = 0; i < 300 && c.score == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 500));

    c.lanes.selectAll(); // trim / remove buttons and the selection summary
    await tester.pump(const Duration(milliseconds: 400));

    final recording = await tester.runAsync(demoWaveform);
    if (recording != null) {
      c.audio.debugTrack = AudioTrack.forTesting(name: 'a long recording name.flac', length: recording.length, waveform: recording.waveform);
    }
    c.tab = BottomTab.audio;
    c.anchors.tapArmed = true;
    c.anchors.selectAll(); // the anchor count chip
    await tester.pump(const Duration(milliseconds: 400));
    c.anchors.tapArmed = false;
    await tester.pump(const Duration(milliseconds: 400));
    // Any overflow fails the test with its report.
  });
}
