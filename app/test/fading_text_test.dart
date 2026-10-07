// A status line (the Instruments tab's, which changes at every move of a drag) changes at once,
// fading only as it appears or goes.
import 'package:curated_score/ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('FadingText changes its text at once and fades only in and out', (tester) async {
    Future<void> show(String? text) =>
        tester.pumpWidget(Directionality(textDirection: TextDirection.ltr, child: FadingText(text)));
    double opacity() => tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;

    await show('Violin · 3.1 → 5.1');
    await tester.pumpAndSettle();
    await show('Violin · 3.1 → 6.1');
    expect(find.text('Violin · 3.1 → 6.1'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse, reason: 'a new text is no fade');

    await show(null);
    expect(opacity(), 0);
    expect(find.text('Violin · 3.1 → 6.1'), findsOneWidget, reason: 'it fades out as it was');
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();
  });
}
