// docs/extension-api.md is made from the guide and the API's own list: it says what the app
// does. So do the docs copied in the editor, and the pack downloaded there for a model.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:curated_score/app_colors.dart';
import 'package:curated_score/extensions/bundled.dart';
import 'package:curated_score/extensions/extension_docs.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart';

import '../tool/extension_docs.dart';

void main() {
  final guide = File('assets/help/extensions.md').readAsStringSync();

  test('docs/extension-api.md is the guide and the API as they are now', () {
    expect(File('../docs/extension-api.md').readAsStringSync(), extensionDocs(guide), reason: 'run `make extension-docs`');
  });

  test('the docs pack: a README, the docs as one file, the API as JSON, Curator’s own extensions as examples', () {
    final pack = extensionDocsPack(guide, examples: BundledExtensions.packages);
    expect(extensionDocsPack(guide, examples: BundledExtensions.packages), pack, reason: 'the same bytes for the same docs');
    final files = {for (final f in ZipDecoder().decodeBytes(pack).files) f.name: utf8.decode(f.content)};
    String file(String path) => files['curator-extension-docs/$path']!;
    expect(file('README.md'), contains('For an AI assistant'));
    expect(file('extension-api.md'), ExtensionApi.docs(guide));
    final api = jsonDecode(file('api.json')) as Map<String, Object?>;
    expect(api['level'], ExtensionApi.level);
    expect([for (final s in api['sockets']! as List<Object?>) (s! as Map<String, Object?>)['type']], [for (final s in ExtensionApi.sockets) s.type]);
    expect([for (final l in api['libraries']! as List<Object?>) (l! as Map<String, Object?>)['name']], [for (final l in ExtensionApi.libraries) l.name]);
    for (final p in BundledExtensions.packages) {
      expect(file('examples/${p.id}/extension.json'), contains('"id": "${p.id}"'));
      expect(file('examples/${p.id}/connect.json'), contains('"wires"'));
      // Each example reads as the package it is.
      expect(p.sources.keys.every((path) => files.containsKey('curator-extension-docs/examples/${p.id}/src/$path')), isTrue);
      expect(file('README.md'), contains('`${p.id}`'), reason: 'the README says what each example shows');
    }
  });

  testWidgets('Copy Docs puts the guide and the reference on the clipboard', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(MaterialApp(
      theme: AppColors.theme(style: UiStyle.refined, brightness: Brightness.light),
      home: const Scaffold(body: ExtensionDocsBar(title: 'Help')),
    ));
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Copy Docs'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    expect(copied, ExtensionApi.docs(guide));
    expect(find.byTooltip('Download Docs for AI…'), findsOneWidget);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1600)));
    await tester.pump();
  });
}
