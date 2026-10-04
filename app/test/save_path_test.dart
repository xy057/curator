import 'dart:io';

import 'package:curated_score/edit_dialogs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the extension is added only when the name lacks it, in any case', () {
    expect(withExtension('/a/Song', 'ccs'), ('/a/Song.ccs', true));
    expect(withExtension('/a/Song.CCS', 'ccs'), ('/a/Song.CCS', false));
    expect(withExtension('/a/Song.ccs.mp4', 'ccs'), ('/a/Song.ccs.mp4.ccs', true));
  });

  testWidgets('adding the extension to the name of a file already there asks before replacing it', (tester) async {
    final dir = Directory.systemTemp.createTempSync('save-path-');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/Song.mp4').writeAsStringSync('the old one');
    final answers = <String?>[];
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
      context = c;
      return const SizedBox();
    })));

    Future<void> ask(String path, {String? press}) async {
      final answer = tester.runAsync(() => confirmSavePath(context, path, 'mp4'));
      await tester.pumpAndSettle();
      if (press != null) {
        expect(find.text('Replace “Song.mp4”?'), findsOneWidget);
        await tester.tap(find.text(press));
        await tester.pumpAndSettle();
      }
      answers.add(await answer);
    }

    await ask('${dir.path}/Song', press: 'Cancel');
    await ask('${dir.path}/Song', press: 'Replace');
    await ask('${dir.path}/Song.mp4'); // the panel asked about this one itself
    await ask('${dir.path}/Other');
    expect(answers, [null, '${dir.path}/Song.mp4', '${dir.path}/Song.mp4', '${dir.path}/Other.mp4']);
  });
}
