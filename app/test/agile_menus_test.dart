// The app's menus are agile: they open in the style's time (190 ms Refined, 110 Carbon; the material ones take 300) and their rows are a desktop menu's, not 48 px.
import 'package:curated_score/app_colors.dart';
import 'package:curated_score/menu_kit.dart';
import 'package:curated_score/ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(UiStyle style, Widget child) => MaterialApp(
      themeAnimationDuration: Duration.zero, // a test may switch styles: no lerp between them
      theme: AppColors.theme(brightness: Brightness.light, style: style),
      home: Scaffold(body: Align(alignment: Alignment.topLeft, child: child)),
    );

void main() {
  for (final (style, rows) in [(UiStyle.refined, 22.0), (UiStyle.carbon, 24.0)]) {
    testWidgets('${style.name}: a popup menu has ${rows.round()} px rows', (tester) async {
      await tester.pumpWidget(_app(
        style,
        Builder(
          builder: (context) => AppPopupMenuButton<int>(
            tooltip: 'Menu',
            itemBuilder: (context) => [
              menuHeader(context, 'Heading'),
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
      expect(items, findsNWidgets(3));
      for (final item in items.evaluate().skip(1)) {
        expect(item.size!.height, rows);
      }
      expect(items.evaluate().first.size!.height, rows, reason: 'the heading is a row of the menu');
      expect(tester.getRect(find.text('Heading')).left, tester.getRect(find.text('One')).left,
          reason: "the heading's text is on the items' edge");
    });
  }

  testWidgets('a popup menu opens in 190 ms in Refined, 110 in Carbon', (tester) async {
    for (final (style, open) in [(UiStyle.refined, 190), (UiStyle.carbon, 110)]) {
      await tester.pumpWidget(_app(
        style,
        AppPopupMenuButton<int>(
          tooltip: 'Menu',
          itemBuilder: (context) => [menuItem(context, value: 1, child: const Text('One'))],
        ),
      ));
      await tester.pumpAndSettle(); // the button takes the new style's look
      await tester.tap(find.byTooltip('Menu'));
      await tester.pump();
      await tester.pump(Duration(milliseconds: open - 10));
      expect(tester.hasRunningAnimations, isTrue, reason: '${style.name}: still opening, so the motion shows');
      await tester.pump(const Duration(milliseconds: 20));
      expect(tester.hasRunningAnimations, isFalse, reason: '${style.name} at ${open + 10} ms');
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

    testWidgets('refined: opens under the field, as wide as it; boxed (a dialog field), its rows are 30 px', (tester) async {
      int? chosen;
      await tester.pumpWidget(select(UiStyle.refined, (v) => chosen = v));
      final field = tester.getRect(find.byType(AppDropdown<int>));
      await tester.tap(find.byType(AppDropdown<int>));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      final row = find.widgetWithText(MenuItemButton, 'Item 3');
      expect(row, findsOneWidget);
      final rect = tester.getRect(row);
      expect(rect.height, 30);
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

    testWidgets('refined: the whole menu, its card with its rows, fades in over 190 ms', (tester) async {
      await tester.pumpWidget(select(UiStyle.refined, (_) {}));
      await tester.tap(find.byType(AppDropdown<int>));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      // The nearest fade over a row; the card (a Material with the menu's shape) is under it too.
      final fade = find.ancestor(of: find.byType(MenuItemButton).first, matching: find.byType(Opacity)).first;
      double opacity() => tester.widget<Opacity>(fade).opacity;
      final card = find.descendant(of: fade, matching: find.byWidgetPredicate((w) => w is Material && w.shape != null));
      expect(card, findsWidgets);
      expect(opacity(), inExclusiveRange(0, 1));
      await tester.pump(const Duration(milliseconds: 200));
      expect(opacity(), 1);
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

    testWidgets('carbon: a filled field with a line under it, 40 px; its rows 32 px, the chosen one selected', (tester) async {
      await tester.pumpWidget(select(UiStyle.carbon, (_) {}));
      final k = CarbonColors.of(AccentColor.sky, Brightness.light);
      expect(find.byType(DropdownButton<int>), findsNothing);
      final box = find.descendant(of: find.byType(AppDropdown<int>), matching: find.byType(Container)).first;
      expect(tester.getSize(box).height, 40);
      final decoration = tester.widget<Container>(box).foregroundDecoration! as BoxDecoration;
      expect(decoration.border, Border(bottom: BorderSide(color: k.borderStrong)));
      await tester.tap(find.byType(AppDropdown<int>));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.widgetWithText(MenuItemButton, 'Item 3')).height, 32);
      final chosen = tester.widget<MenuItemButton>(find.widgetWithText(MenuItemButton, 'Item 2'));
      expect(chosen.style!.backgroundColor!.resolve({}), k.layerSelected);
      expect((tester.widget<Container>(box).foregroundDecoration! as BoxDecoration).border, Border.all(color: k.focus, width: 2),
          reason: 'open: the focus ring');
    });
  });

  testWidgets("refined motion is about three quarters as long, Carbon's on its duration steps; a dialog opens in 116 or 110 ms", (tester) async {
    late BuildContext refined, carbon;
    await tester.pumpWidget(_app(UiStyle.refined, Builder(builder: (context) {
      refined = context;
      return const SizedBox();
    })));
    await tester.pumpAndSettle();
    expect(motion(refined, 120), const Duration(milliseconds: 93));
    await tester.pumpWidget(_app(UiStyle.carbon, Builder(builder: (context) {
      carbon = context;
      return const SizedBox();
    })));
    await tester.pumpAndSettle(); // the theme changes over a moment
    expect(motion(carbon, 120), const Duration(milliseconds: 70), reason: r'$duration-fast-01');
    expect(motion(carbon, 300), const Duration(milliseconds: 240), reason: r'$duration-moderate-02');

    for (final (style, open) in [(UiStyle.refined, 116), (UiStyle.carbon, 110)]) {
      await tester.pumpWidget(_app(style, Builder(builder: (context) => TextButton(
            onPressed: () => showAppDialog<void>(context: context, builder: (_) => const AlertDialog(title: Text('Hi'))),
            child: const Text('Open'),
          ))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(Duration(milliseconds: open - 10));
      expect(tester.hasRunningAnimations, isTrue, reason: style.name);
      await tester.pump(const Duration(milliseconds: 20));
      expect(tester.hasRunningAnimations, isFalse, reason: '${style.name} at ${open + 10} ms');
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
    }
  });
}
