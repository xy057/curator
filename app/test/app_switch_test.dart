import 'package:curated_score/app_colors.dart';
import 'package:curated_score/ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<ValueNotifier<bool>> mount(WidgetTester tester, UiStyle style, {bool enabled = true}) async {
    final on = ValueNotifier(false);
    await tester.pumpWidget(MaterialApp(
      theme: AppColors.theme(style: style),
      home: Scaffold(
        body: Center(
          child: ValueListenableBuilder(
            valueListenable: on,
            builder: (context, value, _) => AppSwitch(value: value, onChanged: enabled ? (v) => on.value = v : null),
          ),
        ),
      ),
    ));
    return on;
  }

  testWidgets('Refined: a small switch of its own, toggled by a click or the keyboard', (tester) async {
    final on = await mount(tester, UiStyle.refined);
    expect(find.byType(Switch), findsNothing);
    expect(tester.getSize(find.byType(AppSwitch)), const Size(46, 28), reason: 'the track, and a margin to click');

    await tester.tap(find.byType(AppSwitch));
    await tester.pumpAndSettle();
    expect(on.value, isTrue);
    expect(tester.getSemantics(find.byType(AppSwitch)), isSemantics(isToggled: true));

    await tester.sendKeyEvent(LogicalKeyboardKey.tab); // focus it
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(on.value, isFalse);
  });

  testWidgets('Refined: a switch without onChanged ignores a click', (tester) async {
    final on = await mount(tester, UiStyle.refined, enabled: false);
    await tester.tap(find.byType(AppSwitch), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(on.value, isFalse);
  });

  testWidgets("Carbon: its small toggle, toggled by a click or the keyboard", (tester) async {
    final on = await mount(tester, UiStyle.carbon);
    expect(find.byType(Switch), findsNothing);
    expect(tester.getSize(find.byType(AppSwitch)), const Size(44, 24), reason: 'the 32 × 16 track, and a margin to click');
    await tester.tap(find.byType(AppSwitch));
    await tester.pumpAndSettle();
    expect(on.value, isTrue);
    expect(tester.getSemantics(find.byType(AppSwitch)), isSemantics(isToggled: true));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(on.value, isFalse);
  });
}
