// Project Settings ▸ Project Info ▸ Score ▸ Edit…: the score editor typed into with Dorico's
// keys, and what Done gives back.
import 'package:curated_score/app_colors.dart';
import 'package:curated_score/score_editor.dart';
import 'package:curated_score/ui_kit.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';
import 'window.dart';

/// A flute, two empty bars of 4/4.
const _flute = '''<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="4.0">
  <part-list><score-part id="P1"><part-name>Flute</part-name></score-part></part-list>
  <part id="P1">
    <measure number="1"><attributes><divisions>1</divisions><key><fifths>0</fifths></key><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>
      <note><rest measure="yes"/><duration>4</duration><voice>1</voice></note></measure>
    <measure number="2"><note><rest measure="yes"/><duration>4</duration><voice>1</voice></note></measure>
  </part>
</score-partwise>''';

void main() {
  testWidgets('notes typed in the score editor come back as MusicXML on Done; Cancel with nothing edited gives nothing', (tester) async {
    desktopWindow(tester);
    String? result;
    var closed = false;
    final score = EditableScore.parse(_flute);
    await tester.pumpWidget(MaterialApp(
      theme: AppColors.theme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showScoreEditor(context, score, name: 'Flute.musicxml');
              closed = true;
            },
            child: const Text('Open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Edit Score'), findsOneWidget);

    Future<void> engraved() async {
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
    }

    await engraved();

    // ⇧N, then an eighth (5), C D E, a quarter (6) rest, Esc.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
    for (final key in [LogicalKeyboardKey.keyC, LogicalKeyboardKey.keyD, LogicalKeyboardKey.keyE]) {
      await tester.sendKeyEvent(key);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.digit6);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await engraved();

    const voice = VoiceKey(1, '1');
    final bar = score.eventsIn(0, 0, voice);
    expect([for (final e in bar.take(3)) e.pitches.single.name], ['C5', 'D5', 'E5']);
    expect(bar[3].isRest, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft); // the rest selected
    await tester.pump();
    await screenshot(tester, 'score-editor', inside: find.byType(ScoreEditor));
    expect(score.canUndo, isTrue);
    expect(tester.widget<ToolbarButton>(find.byWidgetPredicate((w) => w is ToolbarButton && w.tooltip.startsWith('Undo'))).onPressed, isNotNull);

    // ⌘Z takes the rest back; Done gives the score as edited.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    await tester.tap(find.text('Done'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(closed, isTrue);
    final back = EditableScore.parse(result!).eventsIn(0, 0, voice);
    expect([for (final e in back.where((e) => !e.isRest)) e.pitches.single.name], ['C5', 'D5', 'E5']);
    expect(back.where((e) => e.isRest).fold(Frac.zero, (a, e) => a + e.length), Frac(5, 2)); // the rest undone: rests to the end
    expect(result, isNot(contains('cxe')));

    // Opened again and left with nothing changed: nothing to replace.
    closed = false;
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await engraved();
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(closed, isTrue);
    expect(result, isNull);
  });

  testWidgets('an orchestral score scrolls in the editor without the page being built again', (tester) async {
    desktopWindow(tester);
    final score = EditableScore.parse(ScoreFile.decodeMusicXML(demoScore.readAsBytesSync()));
    await tester.pumpWidget(MaterialApp(theme: AppColors.theme(), home: ScoreEditor(score: score, name: 'Intro.musicxml')));
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    await screenshot(tester, 'score-editor-orchestra', inside: find.byType(ScoreEditor));
    final paint = find.descendant(
        of: find.byType(ScoreEditor), matching: find.byWidgetPredicate((w) => w is CustomPaint && '${w.painter.runtimeType}' == '_GalleyPainter'));
    // ignore: avoid_dynamic_calls
    Offset scrolled() => (tester.widget<CustomPaint>(paint).painter as dynamic).scroll.value as Offset;
    expect(scrolled(), Offset.zero);

    final built = <Type>[];
    debugOnRebuildDirtyWidget = (element, _) => built.add(element.widget.runtimeType);
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    tester.binding.handlePointerEvent(PointerScrollEvent(position: tester.getCenter(paint), scrollDelta: const Offset(900, 120)));
    await tester.pump();
    debugOnRebuildDirtyWidget = null;
    expect(scrolled(), const Offset(900, 120));
    expect(built, isEmpty);
    await screenshot(tester, 'score-editor-orchestra-scrolled', inside: find.byType(ScoreEditor));

    // ⌘ and the wheel zoom about the pointer: what is under it stays under it, and nothing is built.
    // ignore: avoid_dynamic_calls
    double zoom() => (tester.widget<CustomPaint>(paint).painter as dynamic).zoom.value as double;
    final at = tester.getCenter(paint), local = at - tester.getTopLeft(paint);
    Offset under() => Offset(local.dx - 132 + scrolled().dx, local.dy + scrolled().dy) / zoom();
    final held = under();
    expect(zoom(), 9);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump(); // (a key pressed has the buttons built for the keyboard)
    built.clear();
    debugOnRebuildDirtyWidget = (element, _) => built.add(element.widget.runtimeType);
    tester.binding.handlePointerEvent(PointerScrollEvent(position: at, scrollDelta: const Offset(0, -120)));
    await tester.pump();
    debugOnRebuildDirtyWidget = null;
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    expect(zoom(), closeTo(9 * 1.6487, 0.01));
    expect((under() - held).distance, lessThan(0.01));
    expect(built, isEmpty);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(zoom(), 9);

    // A rectangle dragged out from where nothing is selects what it touches; ⌘A, everything.
    int selected() {
      final status = find.textContaining(' selected');
      if (status.evaluate().isEmpty) return 0;
      return int.parse(RegExp(r'(\d+) selected').firstMatch(tester.widget<Text>(status).data!)!.group(1)!);
    }

    expect(selected(), 0);
    final corner = tester.getTopLeft(paint) + const Offset(140, 4);
    final drag = await tester.startGesture(corner, kind: PointerDeviceKind.mouse);
    await drag.moveTo(corner + const Offset(300, 200));
    await tester.pump();
    final some = selected();
    expect(some, greaterThan(3));
    await screenshot(tester, 'score-editor-marquee', inside: find.byType(ScoreEditor));
    await drag.moveTo(corner + const Offset(600, 500));
    await tester.pump();
    expect(selected(), greaterThan(some));
    await drag.up();
    await tester.pump();
    final dragged = selected();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(selected(), score.ids.length);
    expect(selected(), greaterThan(dragged));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(selected(), 0);
  });
}
