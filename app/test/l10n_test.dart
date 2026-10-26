// The interface in Simplified Chinese: every text the code translates has an entry, with the same
// placeholders, and choosing the language re-labels the open window at once.

import 'dart:io';

import 'package:curated_score/app_settings.dart';
import 'package:curated_score/l10n/l10n.dart';
import 'package:curated_score/l10n/zh_hans.dart';
import 'package:curated_score/main.dart';
import 'package:flutter_test/flutter_test.dart';

import 'window.dart';

void main() {
  test('every text the code translates has a Simplified Chinese entry', () {
    final literal = RegExp(r"""'((?:[^'\\\n]|\\.)*)'\s*\.(?:tr\b|fill\()|"((?:[^"\\\n]|\\.)*)"\s*\.(?:tr\b|fill\()""");
    final placeholder = RegExp(r'\{\w+\}');
    Set<String> placeholders(String text) => {for (final m in placeholder.allMatches(text)) m[0]!};
    final missing = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart') || file.path.contains('l10n')) continue;
      for (final m in literal.allMatches(file.readAsStringSync())) {
        final english = (m[1] ?? m[2])!.replaceAll(r"\'", "'").replaceAll(r'\n', '\n');
        final chinese = zhHans[english];
        if (chinese == null) {
          missing.add('${file.path}: $english');
        } else {
          expect(placeholders(chinese), placeholders(english), reason: english);
        }
      }
    }
    expect(missing, isEmpty);
  });

  testWidgets('choosing Simplified Chinese re-labels the window, and English brings it back', (tester) async {
    desktopWindow(tester);
    addTearDown(() => Strings.use(AppLanguage.english));
    final settings = AppSettings.memory();
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Open Sample'), findsOneWidget);

    settings.language = AppLanguage.chineseSimplified;
    await tester.pump(const Duration(milliseconds: 400)); // past the cross-fade
    expect(find.text('打开示例'), findsOneWidget);
    expect(find.text('Open Sample'), findsNothing);

    settings.language = AppLanguage.english;
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Open Sample'), findsOneWidget);
  });
}
