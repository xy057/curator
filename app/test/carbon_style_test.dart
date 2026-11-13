// Carbon's controls as its guidelines draw them, where the theme alone can't be trusted to.
import 'dart:async';

import 'package:curated_score/app_colors.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/settings_dialog.dart';
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

  testWidgets('a button carries its icon at the right: a filled or outlined one at its right end, a ghost one after its label',
      (tester) async {
    for (final (kind, make) in <(String, Widget Function(BuildContext))>[
      ('filled', (c) => FilledButton.icon(style: withIconStyle(c), onPressed: () {}, icon: const Icon(Icons.add, size: 16), label: const Text('Open'))),
      ('outlined', (c) => OutlinedButton.icon(style: withIconStyle(c), onPressed: () {}, icon: const Icon(Icons.add, size: 16), label: const Text('Open'))),
      ('ghost', (c) => TextButton.icon(onPressed: () {}, icon: const Icon(Icons.add, size: 16), label: const Text('Open'))),
    ]) {
      await _carbon(tester, Builder(builder: make));
      final button = find.byWidgetPredicate((w) => w is ButtonStyleButton);
      final icon = tester.getRect(find.byType(Icon)), label = tester.getRect(find.text('Open'));
      expect(icon.left, greaterThan(label.right), reason: kind);
      expect(label.left - tester.getRect(button).left, 7, reason: '$kind: the label where a button\'s is');
      if (kind != 'ghost') expect(tester.getRect(button).right - icon.right, 8, reason: '$kind: 8 px in from the right end');
    }
  });

  testWidgets('Settings sits on Carbon\'s \$overlay, which follows the style changed under it; a click on it closes it', (tester) async {
    final settings = AppSettings.memory()
      ..uiStyle = UiStyle.carbon
      ..themeMode = ThemeMode.light;
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    await tester.pump(const Duration(seconds: 1));
    Future<void> open() async {
      unawaited(showSettingsDialog(tester.element(find.byType(Scaffold).first), settings, page: 'Appearance'));
      await tester.pump(const Duration(seconds: 1));
    }

    await open();
    await tester.tapAt(const Offset(400, 590)); // under the window
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Density'), findsNothing, reason: 'closed');

    await open();
    Finder shade(Color color) => find.byWidgetPredicate((w) => w is ColoredBox && w.color == color);
    expect(shade(CarbonColors.of(AccentColor.sky, Brightness.light).overlay), findsOneWidget);
    settings.themeMode = ThemeMode.dark;
    await tester.pump(const Duration(seconds: 1));
    expect(shade(CarbonColors.of(AccentColor.sky, Brightness.dark).overlay), findsOneWidget);
    settings.uiStyle = UiStyle.refined;
    await tester.pump(const Duration(seconds: 1));
    expect(shade(Colors.black.withValues(alpha: 0.2)), findsOneWidget);
  });

  testWidgets('a slider\'s thumb is 14 px, grown to 20 px and ringed in \$interactive while dragged', (tester) async {
    var value = 0.5;
    await _carbon(tester, SizedBox(width: 200, child: StatefulBuilder(
        builder: (context, setState) => Slider(value: value, onChanged: (v) => setState(() => value = v)))));
    final accent = AppColors.of(AccentColor.sky, Brightness.light, UiStyle.carbon).accent.toARGB32();
    final thumb = CarbonColors.of(AccentColor.sky, Brightness.light).selectedInverse.toARGB32();
    // The circles the slider draws: radius, colour (to 8 bits a channel), filled or stroked.
    List<(double, int, PaintingStyle)> circles() {
      final drawn = <(double, int, PaintingStyle)>[];
      expect(find.byType(Slider), paints..everything((method, args) {
        if (method == #drawCircle) drawn.add((args[1] as double, (args[2] as Paint).color.toARGB32(), (args[2] as Paint).style));
        return true;
      }));
      return drawn;
    }

    expect(circles(), contains((7.0, thumb, PaintingStyle.fill)));
    final hold = await tester.startGesture(tester.getCenter(find.byType(Slider)));
    await hold.moveBy(const Offset(20, 0)); // dragged
    await tester.pump(); // the thumb's animation starts, and runs to its end
    await tester.pump(const Duration(seconds: 1));
    expect(circles(), containsAll([(10.0, thumb, PaintingStyle.fill), (9.0, accent, PaintingStyle.stroke)]));
    await hold.up();
  });
}
