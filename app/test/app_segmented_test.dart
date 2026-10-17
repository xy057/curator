import 'package:curated_score/app_colors.dart';
import 'package:curated_score/ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<ValueNotifier<int>> mount(WidgetTester tester, UiStyle style) async {
    final chosen = ValueNotifier(0);
    await tester.pumpWidget(MaterialApp(
      theme: AppColors.theme(style: style),
      home: Scaffold(
        body: Center(
          child: ValueListenableBuilder(
            valueListenable: chosen,
            builder: (context, value, _) => AppSegmented<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('Auto')),
                ButtonSegment(value: 1, label: Text('Light')),
                ButtonSegment(value: 2, label: Text('Dark')),
              ],
              selected: value,
              onChanged: (v) => chosen.value = v,
            ),
          ),
        ),
      ),
    ));
    return chosen;
  }

  final soft = AppColors.of(AccentColor.sky, Brightness.light, UiStyle.refined).accentSoft;
  final thumb = find.byWidgetPredicate((w) => w is DecoratedBox && (w.decoration as BoxDecoration).color == soft);

  testWidgets('Refined: the chosen segment is a light tint of the accent that slides to the one clicked', (tester) async {
    final chosen = await mount(tester, UiStyle.refined);
    expect(find.byType(SegmentedButton<int>), findsNothing);
    expect(tester.getSize(find.byType(AppSegmented<int>)).height, 32);
    expect(thumb, findsOneWidget);
    final segment = tester.getSize(thumb).width;
    final start = tester.getRect(thumb).left;
    expect(tester.getCenter(thumb).dx, closeTo(tester.getCenter(find.text('Auto')).dx, 0.5));

    await tester.tap(find.text('Dark'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(chosen.value, 0, reason: 'chosen when the tint lands');
    final between = tester.getRect(thumb).left;
    expect(between, greaterThan(start), reason: 'on its way');
    expect(between, lessThan(start + 2 * segment), reason: 'not there yet');

    Color label(String text) => tester.renderObject<RenderParagraph>(find.text(text)).text.style!.color!;
    final muted = AppColors.of(AccentColor.sky, Brightness.light, UiStyle.refined).textMuted;
    expect(label('Light'), isNot(muted), reason: 'the label under the moving tint takes some accent');

    await tester.pumpAndSettle();
    expect(chosen.value, 2);
    expect(tester.getRect(thumb).left, closeTo(start + 2 * segment, 0.5));
    expect(label('Auto'), muted);
    expect(label('Light'), muted);
    expect(tester.getCenter(thumb).dx, closeTo(tester.getCenter(find.text('Dark')).dx, 0.5));
  });

  testWidgets('Refined: a clear track; a segment not chosen shades under the mouse, but not while the tint slides', (tester) async {
    await mount(tester, UiStyle.refined);
    final track = tester.widget<Container>(find.descendant(of: find.byType(AppSegmented<int>), matching: find.byType(Container)).first);
    expect((track.decoration! as BoxDecoration).color, isNull);
    double shade(String label) =>
        (tester.widget<AnimatedContainer>(find.ancestor(of: find.text(label), matching: find.byType(AnimatedContainer))).decoration!
                as BoxDecoration)
            .color!
            .a;

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(find.text('Light')));
    await tester.pumpAndSettle();
    expect(shade('Light'), greaterThan(0));
    expect(shade('Auto'), 0, reason: 'the chosen one');

    await tester.tap(find.text('Dark'), kind: PointerDeviceKind.mouse);
    await mouse.moveTo(tester.getCenter(find.text('Light')));
    await tester.pump(const Duration(milliseconds: 40));
    expect(shade('Light'), 0, reason: 'the tint passes under it');
    await tester.pumpAndSettle();
    expect(shade('Light'), greaterThan(0), reason: 'landed');
  });

  testWidgets('Refined: a click back before the tint lands chooses nothing; a third one goes on from where it is', (tester) async {
    final chosen = await mount(tester, UiStyle.refined);
    var changes = 0;
    chosen.addListener(() => changes++);
    await tester.tap(find.text('Dark'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.text('Auto'));
    await tester.pumpAndSettle();
    expect((chosen.value, changes), (0, 0));

    await tester.tap(find.text('Dark'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect((chosen.value, changes), (1, 1));
    expect(tester.getCenter(thumb).dx, closeTo(tester.getCenter(find.text('Light')).dx, 0.5));
  });

  testWidgets('Refined: closed while the tint slides, the click still counts', (tester) async {
    final chosen = await mount(tester, UiStyle.refined);
    await tester.tap(find.text('Light'));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(chosen.value, 1);
  });

  testWidgets('Refined: for every accent, light and dark, the chosen label reads on its tint', (tester) async {
    double contrast(Color a, Color b) {
      final (x, y) = (a.computeLuminance(), b.computeLuminance());
      return (x > y ? x + 0.05 : y + 0.05) / (x > y ? y + 0.05 : x + 0.05);
    }

    for (final accent in AccentColor.values) {
      for (final brightness in Brightness.values) {
        final colors = AppColors.of(accent, brightness, UiStyle.refined);
        await tester.pumpWidget(MaterialApp(
          theme: AppColors.theme(accent: accent, brightness: brightness),
          home: Scaffold(
            body: Center(
              child: AppSegmented<int>(
                segments: const [ButtonSegment(value: 0, label: Text('On')), ButtonSegment(value: 1, label: Text('Off'))],
                selected: 0,
                onChanged: (_) {},
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        final tint = find.byWidgetPredicate((w) => w is DecoratedBox && (w.decoration as BoxDecoration).color == colors.accentSoft);
        expect(tint, findsOneWidget, reason: '$accent $brightness');
        final label = tester.renderObject<RenderParagraph>(find.text('On')).text.style!.color!;
        expect(contrast(label, colors.accentSoft), greaterThanOrEqualTo(4.5), reason: '$accent $brightness');
      }
    }
  });

  testWidgets("Classic: Material's segmented button", (tester) async {
    final chosen = await mount(tester, UiStyle.classic);
    expect(find.byType(SegmentedButton<int>), findsOneWidget);
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(chosen.value, 1);
  });
}
