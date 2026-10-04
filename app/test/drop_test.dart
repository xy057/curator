import 'dart:io';

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/score_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'image_patch_test.dart' show greyPng;
import 'test_fonts.dart';

void main() {
  testWidgets('a drop goes by where it lands: an image on the score; on the timeline, what its tab takes',
      (tester) async {
    await tester.runAsync(loadTestFonts);
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('drop-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final png = File('${dir.path}/logo.png')..writeAsBytesSync(greyPng(40, 20));
    final midi = File('${dir.path}/tempo.mid')..writeAsBytesSync([0]);

    final settings = AppSettings.memory()..attachImage = true;
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Try the sample'));
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    for (var i = 0; i < 100 && c.score == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 500));

    Future<void> channel(String method, Object arguments) => tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'desktop_drop', const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments)), (_) {});
    Future<void> drag(Offset at) async {
      await channel('updated', [at.dx, at.dy]);
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<void> drop(File file, Offset at) async {
      ScaffoldMessenger.of(tester.element(find.byType(ScoreView))).clearSnackBars(); // the sample has no recording here
      await tester.pump();
      await channel('entered', [at.dx, at.dy]);
      await tester.runAsync(() => channel('performOperation', [file.path]));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    void sees(String text) => expect(find.text(text), findsOneWidget);

    final view = tester.getRect(find.byType(ScoreView));
    final timeline = view.bottomCenter + const Offset(0, 60);

    // The hint says what the area under the pointer takes.
    await channel('entered', [view.center.dx, view.center.dy]);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Drop to add an image'), findsOneWidget);
    await drag(timeline);
    expect(find.text('A project or a MusicXML score'), findsOneWidget);
    await channel('exited', const <double>[]);
    await tester.pump(const Duration(milliseconds: 300));

    // On the score: an image, its top-left corner where it was dropped.
    final spot = view.center + const Offset(120, -40);
    await drop(png, spot);
    expect(c.images.patches, hasLength(1));
    final rect = c.scene!.patchRect(c.scene!.patches.single, c.playback.time.value, view.size).shift(view.topLeft);
    expect(rect.topLeft.dx, closeTo(spot.dx, 0.5));
    expect(rect.topLeft.dy, closeTo(spot.dy, 0.5));

    await drop(midi, spot);
    sees('Not an SVG, PNG or JPEG.');
    settings.attachImage = false;
    await tester.pump();
    await drop(png, spot);
    sees('Attach Image is off.');
    expect(c.images.patches, hasLength(1));

    // On the timeline: the Instruments tab opens a project or score, the Audio tab takes MIDI.
    await drop(midi, timeline);
    sees('Drop it on the Audio tab.');
    c.tab = BottomTab.audio;
    await tester.pump();
    await drop(png, timeline);
    sees('Not a MIDI file or a recording.');
    await drag(timeline);
    expect(find.text('A MIDI tempo map or a recording'), findsOneWidget);
    await channel('exited', const <double>[]);
    await tester.pump(const Duration(milliseconds: 300));
  });
}
