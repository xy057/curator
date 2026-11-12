// The PDF import's Read with AI asks the model as Settings has it when it reads: Settings opens
// over the import, so a key put right there is the one the next reading sends.

import 'dart:io';

import 'package:curated_score/ai_providers.dart';
import 'package:curated_score/app_colors.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/pdf_import.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart';

import 'test_fonts.dart';
import 'window.dart';

void main() {
  testWidgets('Read with AI asks the model with the key Settings has now', (tester) async {
    await tester.runAsync(loadTestFonts);
    desktopWindow(tester);
    // A server that refuses every key, and keeps each it is sent.
    HttpOverrides.global = null; // the binding answers every request with 400 otherwise
    final server = (await tester.runAsync(() => HttpServer.bind(InternetAddress.loopbackIPv4, 0)))!;
    addTearDown(() => server.close(force: true));
    final keys = <String?>[];
    Future<void> refuse(HttpRequest request) async {
      keys.add(request.headers.value('authorization'));
      await request.drain<void>();
      request.response
        ..statusCode = 401
        ..headers.contentType = ContentType.json
        ..write('{"error": {"message": "Incorrect API key provided."}}');
      await request.response.close();
    }

    server.listen((request) => refuse(request).catchError((Object _) {}, test: (e) => e is HttpException || e is SocketException));
    final settings = AppSettings.memory()
      ..aiProviders = [
        AiProvider(
            id: 'local', name: 'Local', format: AiFormat.openai, enabled: true, apiKey: 'old', //
            baseUrl: 'http://127.0.0.1:${server.port}/', path: AiFormat.openai.path, models: const ['m']),
      ]
      ..pdfAiModel = 'local/m';

    final pages = (await tester.runAsync(() async => PdfPages.open(await File('assets/exam/pdf-ai-exam.pdf').readAsBytes())))!;
    addTearDown(pages.close);
    final layout = PdfScoreLayout(
      pages: pages.sizes,
      instruments: const [PdfInstrument(id: 'P1', name: 'Flute')],
      systems: [
        PdfSystem.cut(
            page: 0, top: 80, bottom: 150, left: 100, right: 420, //
            staves: const [PdfStaff(top: 100, space: 6, part: 'P1')], barlines: const [PdfBarline(420)]),
      ],
    );
    await tester.pumpWidget(MaterialApp(
      theme: AppColors.theme(),
      home: Scaffold(
        body: Builder(
          // As main.dart opens it: the model asked of the settings each time.
          builder: (context) => TextButton(
              onPressed: () => showPdfImport(context, pages, name: 'Exam.pdf', layout: layout, ai: () => settings.pdfAi),
              child: const Text('Open')),
        ),
      ),
    ));
    Future<void> settle() async {
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    /// Reads with AI, until the server's refusal is said.
    Future<void> read() async {
      final asked = keys.length;
      await tester.tap(find.byTooltip('Read with AI (m)'));
      for (var i = 0; i < 400 && (keys.length == asked || find.textContaining('Reading with AI').evaluate().isNotEmpty); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump();
      }
      expect(find.textContaining('HTTP 401: Incorrect API key provided.'), findsOneWidget);
    }

    await tester.tap(find.text('Open'));
    await settle();
    await read();
    expect(keys, ['Bearer old']);
    // The key put right in Settings, the import still open: the next reading sends it.
    settings.setAiProvider(settings.aiProviders.single.copyWith(apiKey: 'new'));
    await read();
    expect(keys, ['Bearer old', 'Bearer new']);
    // No model there any more: one is asked for, not the one read with before.
    settings.pdfAiModel = '';
    await tester.pump();
    await tester.tap(find.byTooltip('Zoom In')); // (anything that builds the bar again)
    await settle();
    expect(find.byTooltip('Read with AI…'), findsOneWidget);

    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await settle();
  });
}
