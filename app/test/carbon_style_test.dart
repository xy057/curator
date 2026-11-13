// Carbon's controls as its guidelines draw them, where the theme alone can't be trusted to.
import 'package:curated_score/app_colors.dart';
import 'package:curated_score/project_tabs.dart';
import 'package:curated_score/ui_kit.dart';
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

  testWidgets('a field takes the layer above the one it is on: on a group on \$layer-02, \$field-03', (tester) async {
    for (final brightness in Brightness.values) {
      final k = CarbonColors.of(AccentColor.sky, brightness);
      Color? onLayer, onGroup, decorated;
      await _carbon(
          tester,
          Column(children: [
            Builder(builder: (context) => Text('${onLayer = fieldFill(context)}')),
            CarbonLayer(
              child: Builder(builder: (context) {
                onGroup = fieldFill(context);
                decorated = Theme.of(context).inputDecorationTheme.fillColor;
                return CarbonLayer(child: Text('$onGroup')); // there already: as it is
              }),
            ),
          ]),
          brightness: brightness);
      expect(onLayer, k.field, reason: '$brightness');
      expect(onGroup, k.raised.field, reason: '$brightness');
      expect(decorated, k.raised.field, reason: '$brightness');
      // Each field stands out from what it is on, and lighter still under the pointer in the dark.
      expect(k.field, isNot(k.layer01), reason: '$brightness');
      expect(k.raised.field, isNot(k.layer02), reason: '$brightness');
      expect(k.raised.borderSubtle, isNot(k.layer02), reason: '$brightness: a line between a group\'s rows');
      if (brightness == Brightness.dark) {
        for (final c in [k, k.raised]) {
          expect(c.fieldHover.computeLuminance(), greaterThan(c.field.computeLuminance()));
        }
      }
    }
  });

  testWidgets('the tab showing is topped with \$border-interactive, as Carbon\'s contained tabs are', (tester) async {
    for (final brightness in Brightness.values) {
      await _carbon(
          tester,
          ProjectTabs(
            labels: [for (final name in ['Prelude', 'Fugue']) ValueNotifier<ProjectTabLabel>((name: name, edited: false, path: null))],
            shown: 1,
            onShow: (_) {},
            onClose: (_) {},
          ),
          brightness: brightness);
      final accent = AppColors.of(AccentColor.sky, brightness, UiStyle.carbon).accent;
      // The tab's own box, the one with its edges.
      BorderSide topOf(String name) => tester
          .widgetList<DecoratedBox>(find.ancestor(of: find.text(name), matching: find.byType(DecoratedBox)))
          .map((box) => (box.decoration as BoxDecoration).border)
          .whereType<Border>()
          .first
          .top;
      expect(topOf('Fugue'), BorderSide(color: accent, width: 2), reason: '$brightness');
      expect(topOf('Prelude'), BorderSide.none, reason: '$brightness');
      expect(tester.widget<Text>(find.text('Fugue')).style, isNull); // set by the tab, on the strip's type:
      expect(DefaultTextStyle.of(tester.element(find.text('Fugue'))).style.fontWeight, FontWeight.w600);
      expect(DefaultTextStyle.of(tester.element(find.text('Prelude'))).style.fontWeight, FontWeight.w400);
    }
  });
}
