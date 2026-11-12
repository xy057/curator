// Settings ▸ AI: providers are kept with the built-in ones always among them, and the client reads
// each API's model list and error messages, keeping the key to the provider's own server.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
    // What isn't as written is passed over, not an error that stops the settings being read.
    final odd = AiProvider.read('[{"id": "x", "name": "X", "format": 5, "enabled": "yes", "apiKey": 7, "models": {"a": 1}}, {"id": 3}, 4]');
    expect(odd.first, const AiProvider(id: 'x', name: 'X', format: AiFormat.openai, baseUrl: ''));
    expect(odd.length, 6);

    // What is known of its models is kept with them, and goes with a model removed.
    const seeing = AiModelInfo(vision: true, context: 128000);
    final described = mine.withInfo('a', seeing).withInfo('b', const AiModelInfo(reasoning: false, byHand: true));
    expect(AiProvider.read(AiProvider.write([described])).first.details, {'a': seeing, 'b': const AiModelInfo(reasoning: false, byHand: true)});
    expect(described.copyWith(models: ['b']).details.keys, ['b']);
    expect(described.withInfo('a', const AiModelInfo()).details.keys, ['b']); // nothing known: nothing kept
    expect(AiProvider.read(AiProvider.write([mine])).first.details, isEmpty);
    expect(AiProvider.read('[{"id": "x", "name": "X", "models": ["m"], "details": {"m": {"vision": "yes", "context": -1}, "n": {"vision": true}}}]').first.details,
        isEmpty);
    // A list says what it says; what was set by hand stays as set.
    expect(seeing.fetched(const AiModelInfo(reasoning: true, context: 200000)), const AiModelInfo(vision: true, reasoning: true, context: 200000));
    expect(const AiModelInfo(vision: false, byHand: true).fetched(seeing), const AiModelInfo(vision: false, byHand: true));
    expect([for (final n in [512, 8192, 131072, 200000, 999999, 1048576, 1500000, 2097152]) AiModelInfo.short(n)],
        ['512', '8K', '131K', '200K', '1M', '1M', '1.5M', '2.1M']);
    expect([for (final t in ['128000', '128K', '128 k', '1,048,576', '1.5M', '', 'K', '-5', '0.4', '12x']) AiModelInfo.parseTokens(t)],
        [128000, 128000, 128000, 1048576, 1500000, null, null, null, null, null]);

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final heard = <String>[];
    server.listen((request) async {
      final key = request.headers.value('authorization') ?? request.headers.value('x-api-key') ?? request.headers.value('x-goog-api-key');
      heard.add('${request.method} ${request.uri} $key');
      final sent = await utf8.decoder.bind(request).join();
      final r = request.response..headers.contentType = ContentType.json;
      final body = switch (request.uri.path) {
        '/o/models' => {'data': [{'id': 'gpt-a'}, {'id': 7}, {'id': 'gpt-b'}], 'last_id': 9, 'nextPageToken': 9},
        '/a/models' when request.uri.queryParameters['after_id'] == null => {
            'data': [
              {
                'id': 'c-1',
                'max_input_tokens': 200000,
                'capabilities': {
                  'image_input': {'supported': true},
                  'thinking': {'supported': true, 'types': {}},
                },
              },
            ],
            'has_more': true,
            'last_id': 'c-1',
          },
        '/a/models' => {'data': [{'id': 'c-2', 'capabilities': null}], 'has_more': false},
        '/g/models' => {
            'models': [
              {'name': 'models/gem', 'supportedGenerationMethods': ['generateContent'], 'inputTokenLimit': 1048576, 'thinking': true},
              {'name': 'models/gem-old', 'supportedGenerationMethods': ['generateContent'], 'inputTokenLimit': 32768},
              {'name': 'models/embed', 'supportedGenerationMethods': ['embedContent']},
            ],
          },
        '/r/models' => {
            'data': [
              {
                'id': 'see/think',
                'context_length': 131072,
                'architecture': {'input_modalities': ['text', 'image'], 'output_modalities': ['text']},
                'supported_parameters': ['max_tokens', 'reasoning', 'include_reasoning'],
                'reasoning': {'mandatory': false},
              },
              {
                'id': 'text/only',
                'context_length': null,
                'top_provider': {'context_length': 8192},
                'architecture': {'input_modalities': ['text']},
                'supported_parameters': ['max_tokens'],
              },
              {'id': 'mistral', 'capabilities': {'vision': true}, 'max_context_length': 32000.0},
              {'id': 'lm', 'type': 'vlm', 'context_window': 4096},
            ],
          },
        '/o/chat/completions' when sent.contains('"image_url"') => {
            'choices': [
              {
                'message': {'content': 'seen'},
              },
            ],
          },
        '/o/chat/completions' => {'choices': []},
        '/a/messages' when sent.contains('"image"') => {
            'content': [
              {'type': 'text', 'text': 'se'},
              {'type': 'text', 'text': 'en'},
            ],
          },
        '/g/models/gem:generateContent' when sent.contains('"inline_data"') => {
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'seen'},
                  ],
                },
              },
            ],
          },
        '/away/models' || '/raw/models' => null,
        _ => {'error': {'message': 'Incorrect API key provided.'}},
      };
      if (request.uri.path == '/away/models') {
        r.statusCode = 302;
        r.headers.set('location', 'http://example.com/steal');
      } else if (request.uri.path.startsWith('/bad')) {
        r.statusCode = 401;
      }
      if (request.uri.path == '/raw/models') r.add([0x7b, 0xff, 0xfe, 0x7d]); // no UTF-8
      if (body != null) r.write(jsonEncode(body));
      await r.close();
    });
    addTearDown(server.close);
    final base = 'http://127.0.0.1:${server.port}';
    AiProvider at(String path, AiFormat format) =>
        AiProvider(id: 'x', name: 'x', format: format, apiKey: 'secret', baseUrl: '$base/$path/', path: format.path);

    // OpenAI's list says nothing of a model but its ID.
    expect(await AiClient(at('o', AiFormat.openai)).models(), {'gpt-a': const AiModelInfo(), 'gpt-b': const AiModelInfo()});
    expect(await AiClient(at('a', AiFormat.anthropic)).models(), {
      'c-1': const AiModelInfo(vision: true, reasoning: true, context: 200000),
      'c-2': const AiModelInfo(), // two pages
    });
    // Only those that write text; a Gemini model that doesn't think leaves it out; nothing of images.
    expect(await AiClient(at('g', AiFormat.gemini)).models(), {
      'gem': const AiModelInfo(reasoning: true, context: 1048576),
      'gem-old': const AiModelInfo(reasoning: false, context: 32768),
    });
    // OpenRouter's, and other servers' of OpenAI's format.
    expect(await AiClient(at('r', AiFormat.openai)).models(), {
      'see/think': const AiModelInfo(vision: true, reasoning: true, context: 131072),
      'text/only': const AiModelInfo(vision: false, reasoning: false, context: 8192),
      'mistral': const AiModelInfo(vision: true, context: 32000),
      'lm': const AiModelInfo(vision: true, context: 4096),
    });
    await AiClient(at('o', AiFormat.openai)).test('gpt-a');
    expect(heard, contains('POST /o/chat/completions Bearer secret'));
    expect(heard, contains('GET /a/models?limit=1000&after_id=c-1 secret'));

    // A question about pictures, in each format: the words of the answer.
    final picture = Uint8List.fromList(List.filled(300, 7));
    for (final (path, format) in [('o', AiFormat.openai), ('a', AiFormat.anthropic), ('g', AiFormat.gemini)]) {
      expect(await AiClient(at(path, format)).ask('gem', 'What is this?', images: [picture]), 'seen');
    }
    expect(heard, contains('POST /g/models/gem:generateContent secret'));
    await expectLater(AiClient(at('o', AiFormat.openai)).ask('gpt-a', 'Hi'), throwsA(isA<AiError>())); // no words in it

    await expectLater(AiClient(at('bad', AiFormat.openai)).models(),
        throwsA(isA<AiError>().having((e) => '$e', 'text', 'HTTP 401: Incorrect API key provided.')));
    // A redirect is refused, not followed: the key never leaves for another server.
    await expectLater(AiClient(at('away', AiFormat.openai)).models(), throwsA(isA<AiError>().having((e) => e.status, 'status', 302)));
    expect(heard.where((h) => h.contains('steal')), isEmpty);
    await expectLater(AiClient(at('o', AiFormat.openai).copyWith(baseUrl: 'api.openai.com')).models(), throwsA(isA<AiError>()));
    // An answer that is no text at all isn't JSON, said as every such answer is.
    await expectLater(AiClient(at('raw', AiFormat.openai)).models(), throwsA(isA<AiError>()));
    // An answer past the most one may be is ended there.
    await expectLater(AiClient(at('o', AiFormat.openai), mostBytes: 20).models(),
        throwsA(isA<AiError>().having((e) => e.status, 'status', isNull)));
    // A key no header can hold is said to be one, without repeating it, and nothing is asked.
    final asked = heard.length;
    for (final key in ['sk-密钥', 'sk-a\nb', 'sk-“quoted”']) {
      await expectLater(
          AiClient(at('o', AiFormat.openai).copyWith(apiKey: key)).models(),
          throwsA(isA<AiError>().having((e) => '$e', 'text', allOf(contains('API key'), isNot(contains('sk-'))))));
    }
    expect(heard.length, asked);
  });

  test('custom headers and bodies go with the requests, the provider’s then the model’s', () async {
    // Read: one header a line, by name in lower case; what isn't one named by its line, never
    // repeating a value.
    expect(AiClient.headersIn('X-Title: Curator\n\n  HTTP-Referer:https://a.example/x:1  \nx-title: again'),
        {'x-title': 'again', 'http-referer': 'https://a.example/x:1'});
    expect(AiClient.headersIn('  '), isEmpty);
    for (final (text, said) in [
      ('X-A: 1\nno colon', 'Custom headers, line 2: not “Name: value”.'),
      (': value', 'Custom headers, line 1: not “Name: value”.'),
      ('Bad Name: 1', 'Custom headers, line 1: characters a header can’t hold.'),
      ('X-Key: sk-密钥', 'Custom headers, line 1: characters a header can’t hold.'),
    ]) {
      expect(() => AiClient.headersIn(text), throwsA(isA<AiError>().having((e) => e.message, 'message', said)));
    }
    expect(AiClient.bodyIn(' '), isEmpty);
    expect(AiClient.bodyIn('{"temperature": 0, "provider": {"order": ["a"]}}'), {'temperature': 0, 'provider': {'order': ['a']}});
    for (final text in ['[1]', '{"a": ', '7']) {
      expect(() => AiClient.bodyIn(text), throwsA(isA<AiError>().having((e) => e.message, 'message', 'The custom body isn’t a JSON object.')));
    }

    // Kept with the provider and its model.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final heard = <({String path, HttpHeaders headers, Object? body})>[];
    server.listen((request) async {
      final sent = await utf8.decoder.bind(request).join();
      heard.add((path: request.uri.path, headers: request.headers, body: sent.isEmpty ? null : jsonDecode(sent)));
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(request.uri.path.endsWith('/models')
          ? {'data': [{'id': 'm'}], 'models': [{'name': 'models/m'}]}
          : {'choices': [{'message': {'content': 'seen'}}], 'candidates': [{'content': {'parts': [{'text': 'seen'}]}}]}));
      await request.response.close();
    });
    final provider = AiProvider(
      id: 'x', name: 'x', format: AiFormat.openai, apiKey: 'secret', baseUrl: 'http://127.0.0.1:${server.port}', path: AiFormat.openai.path,
      models: ['m', 'n'],
      headers: 'X-Title: Curator\nX-Both: provider',
      body: '{"temperature": 0, "max_tokens": 100, "provider": {"order": ["a"], "allow_fallbacks": false}}',
      details: {
        'm': const AiModelInfo(
            headers: 'X-Both: model\nAuthorization: Bearer other', body: '{"max_tokens": null, "provider": {"order": ["b"]}, "reasoning": {"effort": "low"}}'),
      },
    );
    expect(AiProvider.read(AiProvider.write([provider])).first, provider);

    await AiClient(provider).models(); // the provider's headers, no body
    await AiClient(provider).ask('m', 'Hi');
    await AiClient(provider).ask('n', 'Hi');
    final [list, m, n] = heard;
    expect([list.headers.value('x-title'), list.headers.value('x-both'), list.headers.value('authorization'), list.body],
        ['Curator', 'provider', 'Bearer secret', null]);
    // The model's after the provider's: a header named again replaces it, the key's too.
    expect([m.headers.value('x-title'), m.headers.value('x-both'), m.headers.value('authorization')], ['Curator', 'model', 'Bearer other']);
    // Bodies merged: an object in both merged, a null taking its name out, anything else replaced.
    final body = m.body! as Map;
    expect([body['model'], body['temperature'], body.containsKey('max_tokens'), body['provider'], body['reasoning']],
        ['m', 0, false, {'order': ['b'], 'allow_fallbacks': false}, {'effort': 'low'}]);
    expect(body['messages'], isA<List>());
    expect([n.headers.value('x-both'), n.headers.value('authorization'), (n.body! as Map)['max_tokens']], ['provider', 'Bearer secret', 100]);

    // Gemini's: what the app asks of it kept where the body adds to the same object.
    final gemini = provider.copyWith(format: AiFormat.gemini, path: AiFormat.gemini.path, body: '{"generationConfig": {"temperature": 0}}');
    expect(await AiClient(gemini).ask('n', 'Hi'), 'seen');
    expect((heard.last.body! as Map)['generationConfig'], {'responseMimeType': 'application/json', 'temperature': 0});
    // A custom header that isn't one: said, and nothing is asked.
    final asked = heard.length;
    await expectLater(AiClient(provider.copyWith(headers: 'X-Key: 秘密')).models(), throwsA(isA<AiError>()));
    await expectLater(AiClient(provider.copyWith(body: '[]')).ask('n', 'Hi'), throwsA(isA<AiError>()));
    expect(heard.length, asked);
  });

  test('a client closed ends its requests, one whose connection is still being made too, and asks nothing after', () async {
    // A server that answers every model at once but "held", which it never answers.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final heard = <String>[];
    server.listen((request) async {
      final model = (jsonDecode(await utf8.decoder.bind(request).join()) as Map)['model'] as String;
      heard.add(model);
      if (model == 'held') return;
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'choices': [{'message': {'content': 'seen'}}]}));
      await request.response.close();
    });
    AiClient client() => AiClient(
        AiProvider(id: 'x', name: 'x', format: AiFormat.openai, apiKey: 'k', baseUrl: 'http://127.0.0.1:${server.port}/', path: AiFormat.openai.path),
        timeout: const Duration(seconds: 20));

    // Under way: ended, with the reason.
    var c = client();
    final held = c.ask('held', 'Hi');
    while (!heard.contains('held')) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    c.close();
    await expectLater(held, throwsA(isA<AiError>()));

    // Closed while its connection is being made (which closing an HttpClient doesn't end): ended
    // once it is made, before anything is sent; and nothing asked after is sent.
    c = client();
    final opening = c.ask('opening', 'Hi');
    c.close();
    await expectLater(opening, throwsStateError);
    await expectLater(c.ask('after', 'Hi'), throwsStateError);
    expect(await client().ask('last', 'Hi'), 'seen');
    expect(heard, ['held', 'last']);
  });
}
