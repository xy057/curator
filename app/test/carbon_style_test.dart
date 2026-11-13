// Carbon's controls as its guidelines draw them, where the theme alone can't be trusted to.
import 'package:curated_score/app_colors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// [child] in a Carbon theme, its focus shown as a keyboard shows it.
Future<void> _carbon(WidgetTester tester, Widget child, {Brightness brightness = Brightness.light}) async {
  FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
  addTearDown(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic);
  await tester.pumpWidget(MaterialApp(
    theme: AppColors.theme(style: UiStyle.carbon, brightness: brightness),
    themeAnimationDuration: Duration.zero, // the theme asked for at once, not lerped from the last test's
    home: Scaffold(body: Center(child: child)),
  ));
  await tester.pump();
}

/// The outline the button's [Material] draws.
ShapeBorder? _shapeOf(WidgetTester tester, Finder button) =>
    tester.widget<Material>(find.descendant(of: button, matching: find.byType(Material)).first).shape;

void main() {
  testWidgets('a focused button wears the focus ring, whatever its kind', (tester) async {
    for (final button in <Widget>[
      FilledButton(autofocus: true, onPressed: () {}, child: const Text('Go')),
      OutlinedButton(autofocus: true, onPressed: () {}, child: const Text('Go')),
      TextButton(autofocus: true, onPressed: () {}, child: const Text('Go')),
      IconButton(autofocus: true, onPressed: () {}, icon: const Icon(Icons.add)),
    ]) {
      await _carbon(tester, button);
      expect(_shapeOf(tester, find.byWidget(button)), isA<CarbonFocusBorder>(), reason: '${button.runtimeType}');
    }
  });

  testWidgets('a tertiary (outlined) button is edged in \$button-tertiary, a disabled one in \$button-disabled', (tester) async {
    for (final brightness in Brightness.values) {
      final k = CarbonColors.of(AccentColor.sky, brightness);
      for (final (onPressed, edge) in [(() {}, k.tertiary), (null, k.buttonDisabled)]) {
        final button = OutlinedButton(onPressed: onPressed, child: const Text('Add…'));
        await _carbon(tester, button, brightness: brightness);
        final shape = _shapeOf(tester, find.byWidget(button)) as RoundedRectangleBorder;
        expect(shape.side.color, edge, reason: '$brightness, ${onPressed == null ? 'disabled' : 'enabled'}');
      }
    }
  });
}
