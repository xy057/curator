// The icons: one meaning, drawn from the style's own set.
import 'dart:io';

import 'package:curated_score/app_colors.dart';
import 'package:curated_score/app_icons.dart';
import 'package:curated_score/ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(ThemeData theme) => MaterialApp(
      key: UniqueKey(),
      theme: theme,
      themeAnimationDuration: Duration.zero,
      home: Scaffold(body: Center(child: Builder(
          builder: (context) => ToolbarButton(icon: AppIcon.undo.of(context), tooltip: 'Undo', onPressed: () {})))),
    );

void main() {
  test('each icon has one code point, the same in both sets, and each set is its own font', () {
    final codes = {for (final i in AppIcon.values) i.refined.codePoint};
    expect(codes, hasLength(AppIcon.values.length));
    for (final i in AppIcon.values) {
      expect(i.carbon.codePoint, i.refined.codePoint);
      expect(i.refined.fontFamily, 'Material Symbols Rounded');
      expect(i.carbon.fontFamily, 'Carbon Icons');
      expect(i.forStyle(UiStyle.carbon), i.carbon);
      expect(i.forStyle(UiStyle.refined), i.refined);
    }
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final font in ['MaterialSymbolsRounded.ttf', 'CarbonIcons.ttf']) {
      expect(pubspec, contains('assets/fonts/$font'));
      expect(File('assets/fonts/$font').existsSync(), isTrue);
    }
  });

  testWidgets("a toolbar button draws its style's icon; a theme without the app's styles draws Refined's", (tester) async {
    await tester.pumpWidget(_app(AppColors.theme(brightness: Brightness.light, style: UiStyle.carbon)));
    expect(find.byIcon(AppIcon.undo.carbon), findsOneWidget);
    await tester.pumpWidget(_app(AppColors.theme(brightness: Brightness.dark, style: UiStyle.refined)));
    await tester.pumpAndSettle();
    expect(find.byIcon(AppIcon.undo.refined), findsOneWidget);
    await tester.pumpWidget(_app(ThemeData()));
    await tester.pumpAndSettle();
    expect(find.byIcon(AppIcon.undo.refined), findsOneWidget);
  });
}
