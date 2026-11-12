// Settings ▸ Remote AI Provider: a provider's fields keep what is typed in them (the key kept without the spaces
// round it), and what Test found is shown only while the key and the address are those it tried.

import 'dart:io';

import 'package:curated_score/ai_providers.dart';
import 'package:curated_score/app_colors.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/dialog_kit.dart';
import 'package:curated_score/settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_fonts.dart';
import 'window.dart';

void main() {
  testWidgets('a provider’s fields keep what is typed, and Test’s answer goes with the key it tried', (tester) async {
    await tester.runAsync(loadTestFonts);
    desktopWindow(tester);
    HttpOverrides.global = null; // the binding answers every request with 400 otherwise
    final server = (await tester.runAsync(() => HttpServer.bind(InternetAddress.loopbackIPv4, 0)))!;
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain<void>();
      request.response
        ..headers.contentType = ContentType.json
        ..write('{"data": []}');
      await request.response.close();
    });
    final settings = AppSettings.memory()
      ..aiProviders = [
        AiProvider(
            id: 'local', name: 'Local', format: AiFormat.openai, enabled: true, apiKey: 'k', //
            baseUrl: 'http://127.0.0.1:${server.port}', path: AiFormat.openai.path),
      ];
    AiProvider local() => settings.aiProviders.single;

    await tester.pumpWidget(MaterialApp(
      theme: AppColors.theme(),
      home: Scaffold(
        body: Builder(
            builder: (context) => TextButton(
                onPressed: () => showSettingsDialog(context, settings, page: 'Remote AI Provider'), child: const Text('Open'))),
      ),
    ));
    Future<void> settle() async {
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    await tester.tap(find.text('Open'));
    await settle();
    expect(find.text('Remote AI Provider'), findsNWidgets(2)); // its sidebar row and its title
    // AI run on this computer has no page of its own: it is the Download Hub's.
    expect(find.text('Local AI'), findsNothing);
    expect(find.text('Download Hub'), findsOneWidget);
    // The key, the base URL and the path, in that order.
    Finder field(int n) => find.descendant(of: find.byType(AppTextField).at(n), matching: find.byType(EditableText));
    String typed(int n) => tester.widget<EditableText>(field(n)).controller.text;
    expect([typed(0), typed(1), typed(2)], ['k', local().baseUrl, '/chat/completions']);

    // With no models, Test asks for the model list.
    await tester.tap(find.text('Test'));
    for (var i = 0; i < 200 && find.text('Connected').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
    }
    expect(find.text('Connected'), findsOneWidget);

    // A key pasted with spaces round it: kept without them, the field as typed; and what Test
    // found of the key before is no longer said.
    await tester.enterText(field(0), ' sk-1 ');
    await settle();
    expect([local().apiKey, typed(0)], ['sk-1', ' sk-1 ']);
    expect(find.text('Connected'), findsNothing);
    await tester.enterText(field(1), '${local().baseUrl}/v1 ');
    await settle();
    expect([local().baseUrl, typed(1)], ['http://127.0.0.1:${server.port}/v1', 'http://127.0.0.1:${server.port}/v1 ']);

    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await settle();
  });
}
