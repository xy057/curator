// Settings ▸ Remote AI Provider: a provider's fields keep what is typed in them (the key kept without the spaces
// round it), and what Test found is shown only while the key and the address are those it tried; a
// model's abilities and context size are shown by its ID, set in Edit Model or fetched from the list.

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

    // Advanced: custom headers and body, kept as typed, each saying what of it isn't right.
    expect(find.text('Custom headers'), findsNothing);
    await tester.tap(find.text('Advanced'));
    await settle();
    await tester.enterText(field(3), 'X-Title: Curator\nno colon');
    await settle();
    expect(find.text('Custom headers, line 2: not “Name: value”.'), findsOneWidget);
    await tester.enterText(field(3), 'X-Title: Curator\n');
    await tester.enterText(field(4), '{"temperature": 0');
    await settle();
    expect(find.text('Custom headers, line 2: not “Name: value”.'), findsNothing);
    expect(find.text('The custom body isn’t a JSON object.'), findsOneWidget);
    await tester.enterText(field(4), '{"temperature": 0}');
    await settle();
    expect(find.text('The custom body isn’t a JSON object.'), findsNothing);
    expect([local().headers, local().body], ['X-Title: Curator\n', '{"temperature": 0}']);

    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await settle();
  });

  testWidgets('a model’s abilities and context are shown by it, set in Edit Model, and fetched from the list', (tester) async {
    await tester.runAsync(loadTestFonts);
    desktopWindow(tester);
    HttpOverrides.global = null; // the binding answers every request with 400 otherwise
    final server = (await tester.runAsync(() => HttpServer.bind(InternetAddress.loopbackIPv4, 0)))!;
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain<void>();
      request.response
        ..headers.contentType = ContentType.json
        ..write('{"data": [{"id": "see", "context_length": 1000000, "architecture": {"input_modalities": ["text", "image"]}, '
            '"supported_parameters": ["reasoning"]}, {"id": "new", "context_length": 8192}]}');
      await request.response.close();
    });
    final settings = AppSettings.memory()
      ..aiProviders = [
        AiProvider(
            id: 'local', name: 'Local', format: AiFormat.openai, enabled: true, apiKey: 'k', //
            baseUrl: 'http://127.0.0.1:${server.port}', path: AiFormat.openai.path, models: ['see', 'plain'],
            details: {'see': const AiModelInfo(vision: true, context: 131072)}),
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

    Future<void> until(Finder f) async {
      for (var i = 0; i < 200 && f.evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump();
      }
      await settle();
    }

    await tester.tap(find.text('Open'));
    await settle();
    // What is known of a model, by its ID: its context in short, its abilities as icons.
    expect(find.text('131K'), findsOneWidget);
    expect(find.byTooltip('Vision'), findsOneWidget);
    expect(find.byTooltip('Reasoning'), findsNothing);
    expect(find.byTooltip('Context size: 131,072 tokens'), findsOneWidget);

    // Set by hand: it reasons, and reads 200K.
    await tester.tap(find.byTooltip('Edit model').at(1));
    await settle();
    expect(find.text('Edit Model'), findsOneWidget);
    expect(find.text('plain'), findsNWidgets(2)); // its row, and the dialog's ID
    await tester.tap(find.text('Reasoning'));
    final contextField = find.descendant(of: find.byType(AppTextField).last, matching: find.byType(EditableText));
    await tester.enterText(contextField, '20x');
    await settle();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save')).onPressed, isNull); // no size
    await tester.enterText(contextField, '200K');
    await settle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await settle();
    expect(local().infoOf('plain'), const AiModelInfo(reasoning: true, context: 200000, byHand: true));
    expect(find.text('200K'), findsOneWidget);
    expect(find.byTooltip('Reasoning'), findsOneWidget);

    // Fetched in Edit Model: what the provider's list says of it.
    await tester.tap(find.text('see'));
    await settle();
    await tester.tap(find.widgetWithText(TextButton, 'Fetch').last);
    await until(find.text('Fetched from Local.'));
    expect(tester.widget<EditableText>(contextField).controller.text, '1,000,000');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await settle();
    expect(local().infoOf('see'), const AiModelInfo(vision: true, reasoning: true, context: 1000000));

    // A model's own headers and body, under Advanced: Save waits for them to be right.
    await tester.tap(find.text('see'));
    await settle();
    await tester.tap(find.text('Advanced').last);
    await settle();
    Finder inDialog(int n) => find.descendant(of: find.byType(AppTextField).at(n), matching: find.byType(EditableText));
    final fields = find.byType(AppTextField).evaluate().length; // the pane's three, then the dialog's context, headers, body
    await tester.enterText(inDialog(fields - 1), '{"reasoning": ');
    await settle();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save')).onPressed, isNull);
    await tester.enterText(inDialog(fields - 1), '{"reasoning": {"effort": "low"}}');
    await tester.enterText(inDialog(fields - 2), 'X-Model: 1');
    await settle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await settle();
    expect(local().infoOf('see'),
        const AiModelInfo(vision: true, reasoning: true, context: 1000000, headers: 'X-Model: 1', body: '{"reasoning": {"effort": "low"}}'));

    // Fetch: the list's models with what it says of each; what was set by hand stays as set.
    await tester.tap(find.widgetWithText(TextButton, 'Fetch'));
    await until(find.text('Choose Models'));
    expect(find.text('8K'), findsOneWidget);
    await tester.tap(find.text('new'));
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await settle();
    expect(local().models, ['see', 'plain', 'new']);
    expect(local().infoOf('new'), const AiModelInfo(context: 8192));
    expect(local().infoOf('plain'), const AiModelInfo(reasoning: true, context: 200000, byHand: true));

    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await settle();
  });
}
