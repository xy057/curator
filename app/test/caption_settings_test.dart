// The Captions extension's settings: its font select is a dialog's field in each style.
import 'package:curated_score/app_colors.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/caption_settings.dart';
import 'package:curated_score/ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(UiStyle style) => MaterialApp(
      theme: AppColors.theme(brightness: Brightness.light, style: style),
      home: Scaffold(body: Center(child: CaptionSettings(settings: AppSettings.memory()))),
    );

void main() {
  testWidgets('refined: the font select is 36 px with 14 px text and the select arrow, as a dialog field', (tester) async {
    await tester.pumpWidget(_app(UiStyle.refined));
    final menu = find.byType(DropdownMenu<String>);
    expect(tester.getSize(find.descendant(of: menu, matching: find.byType(TextField))).height, 36);
    expect(tester.widget<EditableText>(find.descendant(of: menu, matching: find.byType(EditableText))).style.fontSize, 14);
    expect(find.descendant(of: menu, matching: find.byIcon(Icons.unfold_more_rounded)), findsOneWidget);
    expect(tester.getRect(find.descendant(of: menu, matching: find.byType(EditableText))).left -
        tester.getRect(find.descendant(of: menu, matching: find.byType(TextField))).left, fieldInset);
  });

  testWidgets('classic: the font select is the material one', (tester) async {
    await tester.pumpWidget(_app(UiStyle.classic));
    final menu = find.byType(DropdownMenu<String>);
    expect(tester.getSize(find.descendant(of: menu, matching: find.byType(TextField))).height, greaterThan(36));
    expect(find.descendant(of: menu, matching: find.byIcon(Icons.unfold_more_rounded)), findsNothing);
  });
}
