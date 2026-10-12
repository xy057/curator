// Refined menus are agile: they open in 90 ms and their rows are a desktop menu's, not 48 px.
import 'package:curated_score/app_colors.dart';
import 'package:curated_score/ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(UiStyle style, Widget child) => MaterialApp(
      theme: AppColors.theme(brightness: Brightness.light, style: style),
      home: Scaffold(body: Align(alignment: Alignment.topLeft, child: child)),
    );

void main() {
  for (final (style, rows) in [(UiStyle.refined, 28.0), (UiStyle.classic, 48.0)]) {
    testWidgets('${style.name}: a popup menu has ${rows.round()} px rows', (tester) async {
      await tester.pumpWidget(_app(
        style,
        Builder(
          builder: (context) => AppPopupMenuButton<int>(
            tooltip: 'Menu',
            itemBuilder: (context) => [
              menuItem(context, value: 1, child: const Text('One')),
              menuDivider(context),
              checkedMenuItem(context, value: 2, checked: true, child: const Text('Two')),
            ],
          ),
        ),
      ));
      await tester.tap(find.byTooltip('Menu'));
      await tester.pumpAndSettle();
      final items = find.byWidgetPredicate((w) => w is PopupMenuItem<int>);
      expect(items, findsNWidgets(2));
      for (final item in items.evaluate()) {
        expect(item.size!.height, rows);
      }
    });
  }

  testWidgets('refined: a popup menu is open in 90 ms, the classic one is not', (tester) async {
    for (final style in [UiStyle.refined, UiStyle.classic]) {
      await tester.pumpWidget(_app(
        style,
        AppPopupMenuButton<int>(
          tooltip: 'Menu',
          itemBuilder: (context) => [menuItem(context, value: 1, child: const Text('One'))],
        ),
      ));
      await tester.tap(find.byTooltip('Menu'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.hasRunningAnimations, style == UiStyle.classic, reason: style.name);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(700, 500)); // the barrier
      await tester.pumpAndSettle();
    }
  });
}
