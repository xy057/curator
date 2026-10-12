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
  for (final (style, rows) in [(UiStyle.refined, 22.0), (UiStyle.classic, 48.0)]) {
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

  group('a dropdown', () {
    Widget select(UiStyle style, ValueChanged<int?> onChanged, {int? value = 2}) => _app(
          style,
          SizedBox(
            width: 200,
            child: AppDropdown<int>(
              value: value,
              isExpanded: true,
              boxed: true,
              hint: const Text('Pick'),
              items: [for (final n in [1, 2, 3]) DropdownMenuItem(value: n, child: Text('Item $n'))],
              onChanged: onChanged,
            ),
          ),
        );

    testWidgets('refined: opens at once under the field, as wide as it, with 22 px rows', (tester) async {
      int? chosen;
      await tester.pumpWidget(select(UiStyle.refined, (v) => chosen = v));
      final field = tester.getRect(find.byType(AppDropdown<int>));
      await tester.tap(find.byType(AppDropdown<int>));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      final row = find.widgetWithText(MenuItemButton, 'Item 3');
      expect(row, findsOneWidget);
      final rect = tester.getRect(row);
      expect(rect.height, 22);
      expect(rect.left, greaterThanOrEqualTo(field.left));
      expect(tester.getRect(find.byType(MenuItemButton).first).top, greaterThanOrEqualTo(field.bottom));
      expect(tester.getRect(find.byType(MenuItemButton).first).top - field.bottom, lessThan(12));
      final panel = find.ancestor(of: find.byType(MenuItemButton).first, matching: find.byType(Material)).first;
      expect(tester.getSize(panel).width, field.width);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(chosen, 3);
      expect(find.byType(MenuItemButton), findsNothing, reason: 'a choice closes it');
    });

    testWidgets('refined: shows the chosen item, or the hint; a null onChanged does not open', (tester) async {
      await tester.pumpWidget(select(UiStyle.refined, (_) {}));
      expect(find.text('Item 2'), findsOneWidget);
      await tester.pumpWidget(select(UiStyle.refined, (_) {}, value: null));
      expect(find.text('Pick'), findsOneWidget);
      await tester.pumpWidget(_app(
        UiStyle.refined,
        const AppDropdown<int>(value: 1, items: [DropdownMenuItem(value: 1, child: Text('One'))], onChanged: null),
      ));
      await tester.tap(find.text('One'));
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNothing);
    });

    testWidgets('classic: the material dropdown, as before', (tester) async {
      await tester.pumpWidget(select(UiStyle.classic, (_) {}));
      expect(find.byType(DropdownButton<int>), findsOneWidget);
      expect(find.byType(MenuAnchor), findsNothing);
    });
  });

  testWidgets('refined motion is about half as long; a dialog is open in 90 ms', (tester) async {
    late BuildContext refined, classic;
    await tester.pumpWidget(_app(UiStyle.refined, Builder(builder: (context) {
      refined = context;
      return const SizedBox();
    })));
    await tester.pumpAndSettle();
    expect(motion(refined, 120), const Duration(milliseconds: 66));
    await tester.pumpWidget(_app(UiStyle.classic, Builder(builder: (context) {
      classic = context;
      return const SizedBox();
    })));
    await tester.pumpAndSettle(); // the theme changes over a moment
    expect(motion(classic, 120), const Duration(milliseconds: 120));

    for (final style in [UiStyle.refined, UiStyle.classic]) {
      await tester.pumpWidget(_app(style, Builder(builder: (context) => TextButton(
            onPressed: () => showAppDialog<void>(context: context, builder: (_) => const AlertDialog(title: Text('Hi'))),
            child: const Text('Open'),
          ))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.hasRunningAnimations, style == UiStyle.classic, reason: style.name);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
    }
  });
}
