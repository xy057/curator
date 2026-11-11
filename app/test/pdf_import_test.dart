// The PDF import's Pages step: a staff clicked is selected, its band a box whose top and bottom are
// dragged by their handles, on their own (a neighbour's band stays where it is), over another
// staff's band if need be; the barlines stay the system's.

import 'dart:io';

import 'package:curated_score/app_colors.dart';
import 'package:curated_score/pdf_import.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'test_fonts.dart';
import 'window.dart';

void main() {
  testWidgets('a staff’s band is dragged on its own, over its neighbour’s', (tester) async {
    await tester.runAsync(loadTestFonts);
    desktopWindow(tester);
    final pages = (await tester.runAsync(() async => PdfPages.open(await File('assets/exam/pdf-ai-exam.pdf').readAsBytes())))!;
    addTearDown(pages.close);
    // Two staves, their bands meeting halfway between them (at 147), barlines at 240 and 420.
    final layout = PdfScoreLayout(
      pages: pages.sizes,
      instruments: const [PdfInstrument(id: 'P1', name: 'Flute'), PdfInstrument(id: 'P2', name: 'Oboe')],
      systems: [
        PdfSystem.cut(
          page: 0,
          top: 80,
          bottom: 220,
          left: 100,
          right: 420,
          staves: const [PdfStaff(top: 100, space: 6, part: 'P1'), PdfStaff(top: 170, space: 6, part: 'P2')],
          barlines: const [PdfBarline(240), PdfBarline(420)],
        ),
      ],
    );
    expect([layout.systems.single.bandOf(0), layout.systems.single.bandOf(1)], [(80.0, 147.0), (147.0, 220.0)]);

    PdfScoreLayout? done;
    await tester.pumpWidget(MaterialApp(
      theme: AppColors.theme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
              onPressed: () async => done = await showPdfImport(context, pages, name: 'Exam.pdf', layout: layout), child: const Text('Open')),
        ),
      ),
    ));
    Future<void> settle() async {
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    await tester.tap(find.text('Open'));
    await settle();

    // A page point on the screen: the page is drawn 132 px from the view's left, 24 from its top,
    // at 1.4 px a point.
    final view = find.byWidgetPredicate((w) => w is CustomPaint && '${w.painter.runtimeType}' == '_PagePainter');
    Offset at(double x, double y) => tester.getTopLeft(view) + Offset(132 + x * 1.4, 24 + y * 1.4);
    Future<void> drag(Offset from, Offset to) async {
      final gesture = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      for (var k = 1; k <= 10; k++) {
        await gesture.moveTo(Offset.lerp(from, to, k / 10)!);
        await tester.pump();
      }
      await gesture.up();
      await tester.pump();
    }

    // The upper staff clicked: selected, its box's handles at the middle of its top and bottom.
    await tester.tapAt(at(200, 110));
    await tester.pump();
    expect(find.widgetWithText(OutlinedButton, 'Remove Staff'), findsOneWidget);
    // Its bottom dragged down past the lower staff's top line: the lower one's band stays.
    await drag(at(260, 147), at(260, 175));
    if (screenshotDir != null) {
      // The page as printed, once it is rendered.
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump();
      }
      await screenshot(tester, 'pdf-import-staff-box', inside: view);
    }
    // The lower staff selected: its top dragged up, the upper one's bottom staying.
    await tester.tapAt(at(200, 200));
    await tester.pump();
    await drag(at(260, 147), at(260, 140));
    // A top dragged below its own lines stops at them.
    await drag(at(260, 140), at(260, 190));

    await tester.tap(find.text('Review'));
    await settle();
    await tester.tap(find.text('Done'));
    for (var i = 0; i < 400 && done == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
    }
    final s = done!.systems.single;
    expect([s.staves[0].bandTop, s.staves[0].bandBottom, s.staves[1].bandTop, s.staves[1].bandBottom], [80, closeTo(175, 0.5), 170, 220]);
    expect([for (final b in s.barlines) b.x], [240, 420]);
    expect(s.ink, hasLength(2));
  });
}
