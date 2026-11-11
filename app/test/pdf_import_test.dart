// The PDF import's Pages step, its staves' regions edited as images on a canvas: a region clicked
// is selected (the empty page deselects), its sides and corners dragged resize it, over a
// neighbour's region if need be and never past its own lines, dragged inside it moves, its edges
// snap to the others'; Draw Region (R) over a staff's lines makes it a staff with that region.
// The barlines stay the system's.

import 'dart:io';

import 'package:curated_score/app_colors.dart';
import 'package:curated_score/pdf_import.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'test_fonts.dart';
import 'window.dart';

void main() {
  testWidgets('a staff’s region is resized, moved and drawn as an image on a canvas', (tester) async {
    await tester.runAsync(loadTestFonts);
    desktopWindow(tester);
    final pages = (await tester.runAsync(() async => PdfPages.open(await File('assets/exam/pdf-ai-exam.pdf').readAsBytes())))!;
    addTearDown(pages.close);
    // A staff of the page as printed, below where the two made up here lie.
    final printed = (await tester.runAsync(() => pages.detectAgain(0, const [])))!;
    final real = printed.expand((s) => [for (final t in s.staves) (s, t)]).firstWhere((e) => e.$2.top > 300);
    // Two staves, their regions meeting halfway between them (at 147), barlines at 240 and 420.
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
    expect([layout.systems.single.regionOf(0), layout.systems.single.regionOf(1)],
        [const Rect.fromLTRB(100, 80, 420, 147), const Rect.fromLTRB(100, 147, 420, 220)]);

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

    Future<void> rendered() async {
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump();
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

    final remove = find.widgetWithText(OutlinedButton, 'Remove Region');
    // The upper region clicked: selected. The empty page clicked: nothing is.
    await tester.tapAt(at(200, 110));
    await tester.pump();
    expect(remove, findsOneWidget);
    await tester.tapAt(at(60, 40));
    await tester.pump();
    expect(remove, findsNothing);
    await tester.tapAt(at(200, 110));
    await tester.pump();
    // Its bottom's handle dragged down over the lower staff's lines: the lower region stays.
    await drag(at(260, 147), at(260, 175));
    // Its bottom right corner: both sides at once, its right no longer the system's end.
    await drag(at(420, 175), at(380, 190));
    if (screenshotDir != null) {
      await rendered();
      await screenshot(tester, 'pdf-import-region', inside: view);
    }

    // The lower region selected: its right side dragged to 3 points off the upper's snaps to it.
    await tester.tapAt(at(200, 205));
    await tester.pump();
    await drag(at(420, 183.5), at(383, 183.5));
    // Moved down by 10, by a drag inside it.
    await drag(at(300, 210), at(300, 220));
    // Its top dragged below its own lines stops at them.
    await drag(at(240, 157), at(240, 200));

    // Draw Region over a staff of the page as printed: a system of its own, its music the region's
    // width, the staff's lines where they are printed.
    await tester.tapAt(at(60, 40));
    await tester.pump();
    expect(remove, findsNothing);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.keyR), isTrue);
    await tester.pump();
    final (system, staff) = real;
    final drawn = Rect.fromLTRB(system.left - 8, staff.top - 2 * staff.space, system.right + 8, staff.bottom + 2 * staff.space);
    await drag(at(drawn.left, drawn.top), at(drawn.right, drawn.bottom));
    for (var i = 0; i < 200 && remove.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
    }
    expect(remove, findsOneWidget);
    if (screenshotDir != null) {
      await rendered();
      await screenshot(tester, 'pdf-import-region-drawn', inside: view);
    }

    await tester.tap(find.text('Review'));
    await settle();
    await tester.tap(find.text('Done'));
    for (var i = 0; i < 400 && done == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
    }
    expect(done!.systems, hasLength(2));
    final s = done!.systems.first;
    expect(s.regionOf(0), rectMoreOrLessEquals(const Rect.fromLTRB(100, 80, 380, 190), epsilon: 0.5));
    expect(s.regionOf(1), rectMoreOrLessEquals(const Rect.fromLTRB(100, 170, 380, 230), epsilon: 0.5));
    // A side where the music starts follows it; one elsewhere is the region's own.
    expect([s.staves[0].regionLeft, s.staves[1].regionLeft, s.staves[1].regionRight], [null, null, 380]);
    expect([for (final b in s.barlines) b.x], [240, 420]);
    expect(s.ink, hasLength(2));
    final added = done!.systems.last;
    expect(added.staves.single.top, closeTo(staff.top, 0.5));
    expect(added.staves.single.space, closeTo(staff.space, 0.2));
    expect(added.regionOf(0), rectMoreOrLessEquals(drawn, epsilon: 0.5));
    expect([added.left, added.right], [closeTo(drawn.left, 0.5), closeTo(drawn.right, 0.5)]);
  });
}
