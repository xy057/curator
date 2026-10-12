// Refined dialogs are laid out as a desktop editor's: title, scrolling body, footer; the
// material AlertDialog stays for Classic.
import 'package:curated_score/app_colors.dart';
import 'package:curated_score/dialog_kit.dart';
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

  testWidgets('classic: the material AlertDialog', (tester) async {
    await tester.pumpWidget(_app(
      UiStyle.classic,
      AppDialog(title: const Text('T'), actions: [FilledButton(onPressed: () {}, child: const Text('OK'))]),
    ));
    await _open(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
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

  testWidgets('refined: a check row is 34 px and toggles by its label; classic is the material list tile', (tester) async {
    bool? value = false;
    for (final style in [UiStyle.refined, UiStyle.classic]) {
      await tester.pumpWidget(MaterialApp(
        theme: _theme(style),
        home: Scaffold(body: Align(alignment: Alignment.topLeft, child: AppCheckRow(value: false, label: 'Flute', onChanged: (v) => value = v))),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile), style == UiStyle.classic ? findsOneWidget : findsNothing);
      if (style == UiStyle.refined) expect(tester.getSize(find.byType(AppCheckRow)).height, 34);
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
}
