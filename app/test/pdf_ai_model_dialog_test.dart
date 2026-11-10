// Settings ▸ General ▸ AI for PDF import: a model chosen takes the exam (both pages asked as Read
// with AI asks them), and is used as its result allows; what goes wrong asking is shown whole.

import 'dart:convert';
import 'dart:io';

import 'package:curated_score/ai_providers.dart';
import 'package:curated_score/app_colors.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/pdf_ai_model_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

/// [page] answered as printed.
String _answer(PdfAiExamPage page) {
  final view = PdfAiView(PdfAiExam.size);
  double y(double p) => p / PdfAiExam.size.height * 1000;
  return jsonEncode({
    'systems': [
      {
        'staves': [
          for (final (k, s) in page.staves.indexed)
            {'label': k + 1, 'y': y((s.top + s.bottom) / 2), 'instrument': 'P${k + 1}', 'name': s.name, 'printed': s.printed, 'clef': s.clef.name, 'key': s.key},
        ],
        'top': y((page.top.$1 + page.top.$2) / 2),
        'bottom': y((page.bottom.$1 + page.bottom.$2) / 2),
        'borders': [for (var k = 1; k < page.staves.length; k++) {'below': k, 'y': y((page.staves[k - 1].bottom + page.staves[k].top) / 2)}],
        'barlines': [for (final b in page.barlines) {'x': b / view.width * 1000}],
        'time': page.time?.toString(),
        'tempos': [if (page.tempo case final t?) {'bar': 1, 'text': t.words, 'bpm': t.bpm}],
      },
    ],
  });
}

void main() {
  testWidgets('a model chosen takes the exam, and is used as its result allows', (tester) async {
    expect([for (final p in [96, 95, 86, 85, 76, 75, 66, 65, 51, 50]) PdfAiVerdict.of(p)], [
      PdfAiVerdict.pass, PdfAiVerdict.passWarned, PdfAiVerdict.passWarned, PdfAiVerdict.ticked, PdfAiVerdict.ticked, //
      PdfAiVerdict.confirmed, PdfAiVerdict.confirmed, PdfAiVerdict.discouraged, PdfAiVerdict.discouraged, PdfAiVerdict.incapable,
    ]);

    // A server whose "good" model reads both pages right, "half" the first only (the second's
    // answer isn't JSON), and whose "bad" one's key is refused.
    HttpOverrides.global = null; // the binding answers every request with 400 otherwise
    final server = (await tester.runAsync(() => HttpServer.bind(InternetAddress.loopbackIPv4, 0)))!;
    addTearDown(server.close);
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      final first = '${body['messages']}'.contains('This is the page they were taken from');
      final r = request.response..headers.contentType = ContentType.json;
      if (body['model'] == 'bad') {
        r
          ..statusCode = 401
          ..write(jsonEncode({'error': {'message': 'Incorrect API key provided.'}}));
      } else {
        final text = body['model'] == 'half' && !first ? 'Sorry, I can’t read this page.' : _answer(PdfAiExam.pages[first ? 0 : 1]);
        r.write(jsonEncode({'choices': [{'message': {'content': text}}]}));
      }
      await r.close();
    });
    final settings = AppSettings.memory()
      ..aiProviders = [
        AiProvider(
            id: 'local', name: 'Local', format: AiFormat.openai, enabled: true, apiKey: 'k', //
            baseUrl: 'http://127.0.0.1:${server.port}/', path: AiFormat.openai.path, models: const ['good', 'half', 'bad']),
      ];

    AiModel? used;
    await tester.pumpWidget(MaterialApp(
      theme: AppColors.theme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(onPressed: () async => used = await showPdfAiModelDialog(context, settings), child: const Text('Open')),
        ),
      ),
    ));
    Future<void> settle() async {
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    Future<void> until(Finder finder) async {
      for (var i = 0; i < 400 && finder.evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump();
      }
      expect(finder, findsWidgets);
    }

    Future<void> choose(String from, String model) async {
      await tester.tap(find.text('Open'));
      await settle();
      await tester.tap(find.text(from));
      await settle();
      await tester.tap(find.text('$model · Local').last);
      await settle();
    }

    VoidCallback? use() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Use')).onPressed;

    // Read right throughout: passed, and used.
    await choose('None', 'good');
    await until(find.text('100%'));
    expect(find.text('Passed'), findsOneWidget);
    await tester.tap(find.text('Use'));
    await settle();
    expect(used?.model, 'good');
    expect([settings.pdfAiModel, settings.pdfAiExam('local/good')?.accuracy], ['local/good', 1]);

    // Half of it wrong: in red, used only once Use anyway is ticked and the warning confirmed.
    await choose('good · Local', 'half');
    await until(find.text('54%'));
    expect(find.text('Not recommended'), findsOneWidget);
    expect(use(), isNull);
    await tester.tap(find.text('Use anyway'));
    await settle();
    await tester.tap(find.text('Use'));
    await settle();
    expect(find.text('Use an inaccurate model?'), findsOneWidget);
    await tester.tap(find.text('Use Anyway'));
    await settle();
    expect([used?.model, settings.pdfAiModel], ['half', 'local/half']);

    // Refused: the server's words, whole; nothing to use.
    await choose('half · Local', 'bad');
    await until(find.text('HTTP 401: Incorrect API key provided.'));
    expect(use(), isNull);
    await tester.tap(find.text('Cancel'));
    await settle();
    expect([used, settings.pdfAiModel, settings.pdfAiExam('local/bad')], [null, 'local/half', null]);
  });
}
