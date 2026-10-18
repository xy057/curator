// Dialogs are laid out as a desktop editor's: title, scrolling body, footer; Carbon's as its
// modal, the footer's buttons edge to edge.
import 'package:curated_score/app_colors.dart';
import 'package:curated_score/app_icons.dart';
import 'package:curated_score/dialog_kit.dart';
import 'package:curated_score/menu_kit.dart';
import 'package:curated_score/ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ThemeData _theme(UiStyle style) => AppColors.theme(brightness: Brightness.light, style: style);

Widget _app(UiStyle style, Widget dialog) => MaterialApp(
      theme: _theme(style),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showAppDialog<void>(context: context, builder: (_) => dialog),
            child: const Text('Open'),
          ),
        ),
      ),
    );

/// The dialog's panel ([Dialog] itself spans the window, around its inset).
Rect _panel(WidgetTester tester) =>
    tester.getRect(find.descendant(of: find.byType(Dialog), matching: find.byType(Material)).first);

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('refined: the title is over the body, the footer under it: leading, status, then the actions', (tester) async {
    await tester.pumpWidget(_app(
      UiStyle.refined,
      AppDialog(
        title: const Text('Title'),
        content: const SizedBox(key: Key('body'), width: 300, height: 60),
        leading: [TextButton(onPressed: () {}, child: const Text('Extra'))],
        status: const Text('Problem'),
        actions: [
          TextButton(onPressed: () {}, child: const Text('Cancel')),
          FilledButton(onPressed: () {}, child: const Text('OK')),
        ],
      ),
    ));
    await _open(tester);
    expect(find.byType(AlertDialog), findsNothing);
    final extra = tester.getRect(find.text('Extra')), status = tester.getRect(find.text('Problem'));
    final cancel = tester.getRect(find.text('Cancel')), ok = tester.getRect(find.text('OK'));
    expect(extra.right, lessThan(status.left));
    expect(status.right, lessThan(cancel.left));
    expect(cancel.right, lessThan(ok.left));
    final body = tester.getRect(find.byKey(const Key('body')));
    expect(tester.getRect(find.text('Title')).bottom, lessThan(body.top));
    expect(body.bottom, lessThan(ok.top));
  });

  testWidgets('refined: a tall body scrolls in a short window instead of overflowing', (tester) async {
    tester.view.physicalSize = const Size(800, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(
      UiStyle.refined,
      AppDialog(
        title: const Text('Tall'),
        content: const SizedBox(width: 300, height: 900),
        actions: [FilledButton(onPressed: () {}, child: const Text('OK'))],
      ),
    ));
    await _open(tester);
    expect(tester.takeException(), isNull);
    expect(tester.getRect(find.text('OK')).bottom, lessThanOrEqualTo(400));
  });

  testWidgets("carbon: a square modal, its two buttons slim (40 px), each a quarter of its width, edge to edge at the right", (tester) async {
    await tester.pumpWidget(_app(
      UiStyle.carbon,
      AppDialog(
        title: const Text('T'),
        content: const SizedBox(width: 400, height: 40),
        actions: [
          TextButton(onPressed: () {}, child: const Text('Cancel')),
          FilledButton(onPressed: () {}, child: const Text('OK')),
        ],
      ),
    ));
    await _open(tester);
    expect(find.byType(AlertDialog), findsNothing);
    final dialog = _panel(tester);
    final cancel = tester.getRect(find.byType(TextButton).last), ok = tester.getRect(find.byType(FilledButton));
    expect(cancel.height, 40);
    expect(ok.height, 40);
    expect(cancel.width, moreOrLessEquals(dialog.width / 4, epsilon: 1));
    expect(ok.right, dialog.right);
    expect(cancel.right, ok.left);
    expect(cancel.width, ok.width);
    expect(ok.bottom, dialog.bottom);
    expect(tester.getRect(find.text('OK')).left - ok.left, 16, reason: 'the label at the left');
    expect(tester.getRect(find.text('OK')).center.dy, moreOrLessEquals(ok.center.dy, epsilon: 1), reason: 'and centred');
    final k = CarbonColors.of(AccentColor.sky, Brightness.light);
    final cancelStyle = Theme.of(tester.element(find.text('Cancel'))).textButtonTheme.style!;
    expect(cancelStyle.backgroundColor!.resolve(const {}), k.secondary, reason: 'Cancel is a secondary button');
    expect((tester.widget<Material>(find.descendant(of: find.byType(Dialog), matching: find.byType(Material)).first).shape
            as RoundedRectangleBorder)
        .borderRadius, BorderRadius.zero);
  });

  testWidgets('carbon: one action takes the right quarter, with or without a leading button and a status', (tester) async {
    for (final (leading, share) in [(false, 0.25), (true, 0.25)]) {
      await tester.pumpWidget(_app(
        UiStyle.carbon,
        AppDialog(
          title: const Text('T'),
          content: const SizedBox(width: 400, height: 40),
          leading: [if (leading) TextButton(onPressed: () {}, child: const Text('Add'))],
          status: leading ? const Text('Problem') : null,
          actions: [FilledButton(onPressed: () {}, child: const Text('OK'))],
        ),
      ));
      await _open(tester);
      final dialog = _panel(tester), ok = tester.getRect(find.byType(FilledButton));
      expect(ok.width, moreOrLessEquals(dialog.width * share, epsilon: 1));
      expect(ok.right, dialog.right);
      if (leading) expect(tester.getRect(find.text('Problem')).right, lessThanOrEqualTo(ok.left));
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('refined: a text field is 36 px with its label over it, and a bad one is outlined in red', (tester) async {
    final text = TextEditingController(text: '12');
    addTearDown(text.dispose);
    for (final bad in [false, true]) {
      await tester.pumpWidget(MaterialApp(
        theme: _theme(UiStyle.refined),
        home: Scaffold(body: Center(child: SizedBox(width: 200, child: AppTextField(controller: text, label: 'Bar', bad: bad)))),
      ));
      expect(tester.getSize(find.byType(TextField)).height, 36);
      expect(tester.getRect(find.text('Bar')).bottom, lessThanOrEqualTo(tester.getRect(find.byType(TextField)).top));
      final border = tester.widget<TextField>(find.byType(TextField)).decoration!.enabledBorder as OutlineInputBorder;
      expect(border.borderSide.color == _theme(UiStyle.refined).extension<AppColors>()!.erase, bad);
    }
  });

  testWidgets("carbon: a text field is 40 px, filled, a line under it; a bad one is ringed in \$support-error with its icon", (tester) async {
    final text = TextEditingController(text: '12');
    addTearDown(text.dispose);
    final k = CarbonColors.of(AccentColor.sky, Brightness.light);
    for (final bad in [false, true]) {
      await tester.pumpWidget(MaterialApp(
        theme: _theme(UiStyle.carbon),
        home: Scaffold(body: Center(child: SizedBox(width: 200, child: AppTextField(controller: text, label: 'Bar', bad: bad)))),
      ));
      expect(tester.getSize(find.byType(TextField)).height, 40);
      final decoration = tester.widget<TextField>(find.byType(TextField)).decoration!;
      expect(decoration.fillColor, k.field);
      final border = decoration.enabledBorder! as CarbonFieldBorder;
      expect(border.ring, bad);
      expect(border.borderSide.color, bad ? k.error : k.borderStrong);
      expect((decoration.focusedBorder! as CarbonFieldBorder).borderSide.width, 2);
      expect(find.byIcon(AppIcon.invalid.carbon), bad ? findsOneWidget : findsNothing);
    }
  });

  testWidgets('a check row is 34 px (Carbon 32), no list tile, and toggles by its label', (tester) async {
    bool? value = false;
    for (final style in [UiStyle.refined, UiStyle.carbon]) {
      await tester.pumpWidget(MaterialApp(
        theme: _theme(style),
        home: Scaffold(body: Align(alignment: Alignment.topLeft, child: AppCheckRow(value: false, label: 'Flute', onChanged: (v) => value = v))),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(tester.getSize(find.byType(AppCheckRow)).height, style == UiStyle.carbon ? 32 : 34);
      value = null;
      await tester.tap(find.text('Flute'));
      expect(value, isTrue, reason: style.name);
    }
  });

  testWidgets('refined: the footer buttons are 34 px, a dialog\'s, not the toolbar\'s 28', (tester) async {
    await tester.pumpWidget(_app(
      UiStyle.refined,
      AppDialog(title: const Text('T'), actions: [FilledButton(onPressed: () {}, child: const Text('OK'))]),
    ));
    await _open(tester);
    expect(tester.getSize(find.byType(FilledButton)).height, 34);
  });

  testWidgets('refined: content, check rows and footer buttons share one left and one right edge', (tester) async {
    await tester.pumpWidget(_app(
      UiStyle.refined,
      AppDialog(
        title: const Text('Title'),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            AppCheckRow(value: true, label: 'Row', onChanged: (_) {}),
            const SizedBox(key: Key('content'), height: 10, width: double.infinity),
          ]),
        ),
        leading: [TextButton(onPressed: () {}, child: const Text('Extra'))],
        actions: [
          TextButton(onPressed: () {}, child: const Text('Cancel')),
          FilledButton(onPressed: () {}, child: const Text('OK')),
        ],
      ),
    ));
    await _open(tester);
    final content = tester.getRect(find.byKey(const Key('content')));
    expect(tester.getRect(find.text('Title')).left, content.left);
    expect(tester.getRect(find.byType(Checkbox)).left, content.left, reason: 'no inset on a check row');
    expect(tester.getRect(find.widgetWithText(TextButton, 'Extra')).left, content.left);
    expect(tester.getRect(find.byType(FilledButton)).right, content.right);
    final footer = Theme.of(tester.element(find.text('Cancel'))).textButtonTheme.style!;
    expect(footer.side?.resolve(const {}), isNotNull, reason: 'a text button in the footer is outlined, so its edge shows');
  });

  testWidgets('typed and chosen text start one inset in from their borders', (tester) async {
    final text = TextEditingController(text: '16:9');
    addTearDown(text.dispose);
    for (final style in [AppStyle.refined, AppStyle.carbon]) {
    await tester.pumpWidget(MaterialApp(
      themeAnimationDuration: Duration.zero,
      theme: _theme(style.style),
      home: Scaffold(
        body: SizedBox(
          width: 300,
          child: Column(children: [
            AppTextField(controller: text, label: 'Ratio'),
            AppDropdown<int>(
              label: 'Choice',
              isExpanded: true,
              value: 1,
              items: const [DropdownMenuItem(value: 1, child: Text('1 bar'))],
              onChanged: (_) {},
            ),
          ]),
        ),
      ),
    ));
    expect(tester.getRect(find.byType(EditableText)).left, style.fieldInset, reason: style.style.name);
    expect(tester.getRect(find.text('1 bar')).left, style.fieldInset, reason: style.style.name);
    }
  });

  testWidgets('carbon: a labelled select shows a value set from outside (an Undo, its dialog)', (tester) async {
    var value = 1;
    late StateSetter setOuter;
    await tester.pumpWidget(MaterialApp(
      theme: _theme(UiStyle.carbon),
      home: Scaffold(
        body: StatefulBuilder(builder: (context, setState) {
          setOuter = setState;
          return AppDropdown<int>(
            label: 'Count',
            value: value,
            items: const [DropdownMenuItem(value: 1, child: Text('One')), DropdownMenuItem(value: 2, child: Text('Two'))],
            onChanged: (v) => setState(() => value = v!),
          );
        }),
      ),
    ));
    expect(find.text('One'), findsOneWidget);
    setOuter(() => value = 2);
    await tester.pumpAndSettle();
    expect(find.text('Two'), findsOneWidget);
    expect(find.text('One'), findsNothing);
  });
}
