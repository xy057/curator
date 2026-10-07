// The metronome (C, or the toolbar): a click at every beat while playing, the bar's first
// accented; a seek into a beat doesn't click; it is neither an edit nor saved.
import 'dart:typed_data';

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/audio_track.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_project.dart';

void main() {
  late EditorController c;
  late List<bool> clicks;

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CuratedScoreApp(settings: AppSettings.memory()));
    c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    await tester.runAsync(() => c.openFile(demoScore.path));
    await tester.pump(const Duration(milliseconds: 200));
    clicks = [];
    c.audio.debugClick = ({required accent}) => clicks.add(accent);
  }

  /// Plays, frame by frame, until the time is past [until] (the clock is a Stopwatch: real time).
  Future<void> play(WidgetTester tester, double until) async {
    c.playback.play();
    while (c.playback.time.value < until) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 10));
    }
    c.playback.pause();
  }

  testWidgets('C turns it on and off; on, it clicks each beat, the first of a bar accented', (tester) async {
    await open(tester);
    final starts = c.timeline.measureStarts;
    final undo = c.canUndo;

    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.pump();
    expect(c.playback.metronome, isTrue);
    expect(c.canUndo, undo, reason: 'not an edit');

    // From just before bar 3's barline through its second beat (6/8: a dotted crotchet on).
    final bar = c.timeline.secondsAtQuarter(starts[2]), second = c.timeline.secondsAtQuarter(starts[2] + 1.5);
    c.playback.seek(bar - 0.03);
    await play(tester, second + 0.02);
    expect(clicks, [true, false]);

    // A seek into the middle of a beat waits for the next one.
    c.playback.seek(bar + (second - bar) / 4);
    await play(tester, (bar + second) / 2);
    expect(clicks, [true, false]);
    await play(tester, second + 0.02);
    expect(clicks, [true, false, false]);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.pump();
    expect(c.playback.metronome, isFalse);
    c.playback.seek(bar - 0.03);
    await play(tester, bar + 0.02);
    expect(clicks, [true, false, false], reason: 'off');
  });

  testWidgets('the toolbar button shows and switches it', (tester) async {
    await open(tester);
    await tester.tap(find.byTooltip('Metronome (C)'));
    await tester.pump();
    expect(c.playback.metronome, isTrue);
    final button = find.ancestor(of: find.byTooltip('Metronome (C)'), matching: find.byType(IconButton));
    expect(tester.widget<IconButton>(button).isSelected, isTrue);
    await tester.tap(find.byTooltip('Metronome (C)'));
    await tester.pump();
    expect(c.playback.metronome, isFalse);
  });

  test('the click is a short 16-bit mono WAV', () {
    final wav = AudioEngine.clickWav(1320);
    final data = ByteData.sublistView(wav);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(data.getUint32(24, Endian.little), 44100);
    expect(wav.length, 44 + 44100 * 40 ~/ 1000 * 2);
  });
}
