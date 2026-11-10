// Settings ▸ AI: providers are kept with the built-in ones always among them, and the client reads
// each API's model list and error messages, keeping the key to the provider's own server.

import 'dart:convert';
import 'dart:io';

import 'package:curated_score/ai_providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('providers are kept, and the client lists models and reports errors', () async {
    // Nothing saved: the five built-in ones, in order, off.
    expect([for (final p in AiProvider.read(null)) p.name], ['OpenAI', 'Anthropic', 'OpenRouter', 'Gemini', 'DeepSeek']);
    expect(AiProvider.read('not json').length, 5);

    // Saved and read back: the user's own one kept, a built-in one missing comes back after it.
    final mine = AiProvider.added('Local', AiFormat.anthropic).copyWith(apiKey: 'k', models: ['a', 'b']);
    final saved = AiProvider.write([AiProvider.builtIns.first.copyWith(enabled: true, apiKey: 'sk'), mine]);
    final read = AiProvider.read(saved);
    expect(read.take(2), [AiProvider.builtIns.first.copyWith(enabled: true, apiKey: 'sk'), mine]);
    expect(read.length, 6);

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final heard = <String>[];
    server.listen((request) async {
      final key = request.headers.value('authorization') ?? request.headers.value('x-api-key') ?? request.headers.value('x-goog-api-key');
      heard.add('${request.method} ${request.uri} $key');
      final r = request.response..headers.contentType = ContentType.json;
      final body = switch (request.uri.path) {
        '/o/models' => {'data': [{'id': 'gpt-a'}, {'id': 'gpt-b'}]},
        '/a/models' when request.uri.queryParameters['after_id'] == null => {'data': [{'id': 'c-1'}], 'has_more': true, 'last_id': 'c-1'},
        '/a/models' => {'data': [{'id': 'c-2'}], 'has_more': false},
        '/g/models' => {
            'models': [
              {'name': 'models/gem', 'supportedGenerationMethods': ['generateContent']},
              {'name': 'models/embed', 'supportedGenerationMethods': ['embedContent']},
            ],
          },
        '/o/chat/completions' => {'choices': []},
        '/away/models' => null,
        _ => {'error': {'message': 'Incorrect API key provided.'}},
      };
      if (request.uri.path == '/away/models') {
        r.statusCode = 302;
        r.headers.set('location', 'http://example.com/steal');
      } else if (request.uri.path.startsWith('/bad')) {
        r.statusCode = 401;
      }
      await request.drain<void>();
      if (body != null) r.write(jsonEncode(body));
      await r.close();
    });
    addTearDown(server.close);
    final base = 'http://127.0.0.1:${server.port}';
    AiProvider at(String path, AiFormat format) =>
        AiProvider(id: 'x', name: 'x', format: format, apiKey: 'secret', baseUrl: '$base/$path/', path: format.path);

    expect(await AiClient(at('o', AiFormat.openai)).models(), ['gpt-a', 'gpt-b']);
    expect(await AiClient(at('a', AiFormat.anthropic)).models(), ['c-1', 'c-2']); // two pages
    expect(await AiClient(at('g', AiFormat.gemini)).models(), ['gem']); // only those that write text
    await AiClient(at('o', AiFormat.openai)).test('gpt-a');
    expect(heard, contains('POST /o/chat/completions Bearer secret'));
    expect(heard, contains('GET /a/models?limit=1000&after_id=c-1 secret'));

    await expectLater(AiClient(at('bad', AiFormat.openai)).models(),
        throwsA(isA<AiError>().having((e) => '$e', 'text', 'HTTP 401: Incorrect API key provided.')));
    // A redirect is refused, not followed: the key never leaves for another server.
    await expectLater(AiClient(at('away', AiFormat.openai)).models(), throwsA(isA<AiError>().having((e) => e.status, 'status', 302)));
    expect(heard.where((h) => h.contains('steal')), isEmpty);
    await expectLater(AiClient(at('o', AiFormat.openai).copyWith(baseUrl: 'api.openai.com')).models(), throwsA(isA<AiError>()));
  });
}
