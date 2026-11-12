import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'l10n/l10n.dart';
import 'updater.dart' show appVersion;

/// The API a provider speaks: how a request is made, how its models are listed, where its key
/// goes, and the path a chat request takes unless the provider says otherwise.
enum AiFormat {
  openai('OpenAI', '/chat/completions'),
  anthropic('Anthropic', '/messages'),
  gemini('Gemini', '/models/{model}:generateContent');

  const AiFormat(this.label, this.path);

  /// Its name in the interface (a product's: not translated).
  final String label;

  /// The usual API path, after the base URL; `{model}` stands for the model's ID.
  final String path;

  static AiFormat named(String? name) => values.asNameMap()[name] ?? openai;
}

/// What is known of one of a provider's models (Settings ▸ Remote AI Provider ▸ Edit Model):
/// whether it reads images, whether it reasons, how much it reads at once, each null while
/// nothing says (what the provider's model list says, [AiClient.models], or the user); and what
/// its requests add to the provider's: [headers] and [body].
@immutable
class AiModelInfo {
  const AiModelInfo({this.vision, this.reasoning, this.context, this.byHand = false, this.headers = '', this.body = ''});

  /// Reads images (as Read with AI asks it to).
  final bool? vision;

  /// Reasons (thinks) before it answers.
  final bool? reasoning;

  /// Its context window: the most tokens it reads at once.
  final int? context;

  /// What it can do was set by the user: Fetch leaves it as set.
  final bool byHand;

  /// Headers its requests send after the provider's ([AiProvider.headers]), as typed: "Name: value" lines.
  final String headers;

  /// What its requests' bodies take after the provider's ([AiProvider.body]), as typed: a JSON object.
  final String body;

  bool get isEmpty =>
      vision == null && reasoning == null && context == null && !byHand && headers.trim().isEmpty && body.trim().isEmpty;

  /// This with what the provider's list says of the model ([found]) where it says something;
  /// what it can do unchanged when set [byHand].
  AiModelInfo fetched(AiModelInfo found) => byHand
      ? this
      : AiModelInfo(
          vision: found.vision ?? vision,
          reasoning: found.reasoning ?? reasoning,
          context: found.context ?? context,
          headers: headers,
          body: body);

  /// [context] in short: 8192, 128K, 1M, 1.5M (thousands and millions, as models' windows are
  /// told).
  static String short(int tokens) {
    final k = (tokens / 1000).round();
    if (tokens < 1000) return '$tokens';
    if (k < 1000) return '${k}K';
    final m = (tokens / 100000).round() / 10;
    return '${m == m.truncate() ? m.toInt() : m}M';
  }

  /// A context size as typed: digits (commas, spaces or underscores between them), and K or M
  /// after them for thousands or millions (128K, 1.5M); null when it isn't one.
  static int? parseTokens(String text) {
    final match = RegExp(r'^(\d+(?:\.\d+)?)([km]?)$').firstMatch(text.replaceAll(RegExp(r'[\s,_]'), '').toLowerCase());
    if (match == null) return null;
    final n = double.parse(match[1]!) * switch (match[2]) { 'k' => 1e3, 'm' => 1e6, _ => 1 };
    return n >= 1 && n < 1e12 ? n.round() : null;
  }

  Map<String, Object?> toJson() => {
        'vision': ?vision,
        'reasoning': ?reasoning,
        'context': ?context,
        if (byHand) 'byHand': true,
        if (headers.trim().isNotEmpty) 'headers': headers,
        if (body.trim().isNotEmpty) 'body': body,
      };

  static AiModelInfo fromJson(Object? json) {
    if (json is! Map) return const AiModelInfo();
    bool? flag(String key) => switch (json[key]) { final bool b => b, _ => null };
    return AiModelInfo(
      vision: flag('vision'),
      reasoning: flag('reasoning'),
      context: switch (json['context']) { final int n when n > 0 => n, _ => null },
      byHand: json['byHand'] == true,
      headers: switch (json['headers']) { final String s => s, _ => '' },
      body: switch (json['body']) { final String s => s, _ => '' },
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AiModelInfo &&
      other.vision == vision &&
      other.reasoning == reasoning &&
      other.context == context &&
      other.byHand == byHand &&
      other.headers == headers &&
      other.body == body;

  @override
  int get hashCode => Object.hash(vision, reasoning, context, byHand, headers, body);
}

/// One AI service and the credentials for it (Settings ▸ Remote AI Provider): an API key, where
/// its API is, and the models chosen from it. Kept in the app's settings
/// ([AppSettings.aiProviders]), for every project. Five come with the app ([builtIns]); the user
/// can add others, which speak one of the [AiFormat]s.
@immutable
class AiProvider {
  const AiProvider({
    required this.id,
    required this.name,
    required this.format,
    this.enabled = false,
    this.apiKey = '',
    required this.baseUrl,
    String? path,
    this.models = const [],
    this.details = const {},
    this.headers = '',
    this.body = '',
  }) : path = path ?? '';

  /// Stays the same when it is renamed: a built-in one's is its [builtIns] entry's.
  final String id;
  final String name;
  final AiFormat format;
  final bool enabled;
  final String apiKey;
  final String baseUrl;
  final String path;

  /// Model IDs, in the order shown.
  final List<String> models;

  /// What is known of its [models], by ID: only those something is known of.
  final Map<String, AiModelInfo> details;

  /// What is known of [model].
  AiModelInfo infoOf(String model) => details[model] ?? const AiModelInfo();

  /// Headers every request to it sends after the key's (custom ones), as typed: "Name: value"
  /// lines ([AiClient.headersIn]). A model's own ([AiModelInfo.headers]) come after them.
  final String headers;

  /// What every request asking a model takes in its body, as typed: a JSON object merged into
  /// the one the app makes ([AiClient.bodyIn]). A model's own ([AiModelInfo.body]) after it.
  final String body;

  /// One of [builtIns]: it can't be removed, and speaks only its own format.
  bool get builtIn => builtIns.any((p) => p.id == id);

  /// The ones the app comes with, in this order, off until turned on.
  static const builtIns = [
    AiProvider(id: 'openai', name: 'OpenAI', format: AiFormat.openai, baseUrl: 'https://api.openai.com/v1', path: '/chat/completions'),
    AiProvider(id: 'anthropic', name: 'Anthropic', format: AiFormat.anthropic, baseUrl: 'https://api.anthropic.com/v1', path: '/messages'),
    AiProvider(id: 'openrouter', name: 'OpenRouter', format: AiFormat.openai, baseUrl: 'https://openrouter.ai/api/v1', path: '/chat/completions'),
    AiProvider(
        id: 'gemini',
        name: 'Gemini',
        format: AiFormat.gemini,
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        path: '/models/{model}:generateContent'),
    AiProvider(id: 'deepseek', name: 'DeepSeek', format: AiFormat.openai, baseUrl: 'https://api.deepseek.com', path: '/chat/completions'),
  ];

  /// A new provider of the user's, of [format], its path the format's.
  factory AiProvider.added(String name, AiFormat format) => AiProvider(
        id: 'custom-${DateTime.now().microsecondsSinceEpoch}',
        name: name,
        format: format,
        enabled: true,
        baseUrl: '',
        path: format.path,
      );

  AiProvider copyWith({
    String? name,
    AiFormat? format,
    bool? enabled,
    String? apiKey,
    String? baseUrl,
    String? path,
    List<String>? models,
    Map<String, AiModelInfo>? details,
    String? headers,
    String? body,
  }) =>
      AiProvider(
        id: id,
        name: name ?? this.name,
        format: format ?? this.format,
        enabled: enabled ?? this.enabled,
        apiKey: apiKey ?? this.apiKey,
        baseUrl: baseUrl ?? this.baseUrl,
        path: path ?? this.path,
        models: models ?? this.models,
        // What is known of a model goes with it.
        details: {
          for (final MapEntry(:key, :value) in (details ?? this.details).entries)
            if ((models ?? this.models).contains(key) && !value.isEmpty) key: value,
        },
        headers: headers ?? this.headers,
        body: body ?? this.body,
      );

  /// This with [info] known of [model] (nothing, when it is empty).
  AiProvider withInfo(String model, AiModelInfo info) =>
      copyWith(details: {
        for (final MapEntry(:key, :value) in details.entries)
          if (key != model) key: value,
        model: info,
      });

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'format': format.name,
        'enabled': enabled,
        'apiKey': apiKey,
        'baseUrl': baseUrl,
        'path': path,
        'models': models,
        if (details.isNotEmpty) 'details': {for (final MapEntry(:key, :value) in details.entries) key: value.toJson()},
        if (headers.isNotEmpty) 'headers': headers,
        if (body.isNotEmpty) 'body': body,
      };

  /// One read back from [toJson]; null when it isn't one (a damaged entry is left out).
  static AiProvider? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'], name = json['name'];
    if (id is! String || id.isEmpty || name is! String) return null;
    String text(String key) => switch (json[key]) { final String s => s, _ => '' };
    final builtIn = builtIns.where((p) => p.id == id).firstOrNull;
    final models = [
      for (final m in json['models'] is List ? json['models'] as List : const [])
        if (m is String && m.isNotEmpty) m,
    ];
    final details = json['details'] is Map ? json['details'] as Map : const {};
    return AiProvider(
      id: id,
      name: name,
      // A built-in one speaks its own format, whatever was saved.
      format: builtIn?.format ?? AiFormat.named(switch (json['format']) { final String name => name, _ => null }),
      enabled: json['enabled'] == true,
      apiKey: text('apiKey'),
      baseUrl: text('baseUrl'),
      path: text('path'),
      models: models,
      details: {
        for (final m in models)
          if (AiModelInfo.fromJson(details[m]) case final info when !info.isEmpty) m: info,
      },
      headers: text('headers'),
      body: text('body'),
    );
  }

  /// The providers saved as [saved] (a JSON list, or null when none were ever saved): every
  /// built-in one there is, those missing from it after the others.
  static List<AiProvider> read(String? saved) {
    final list = <AiProvider>[];
    try {
      final json = saved == null ? null : jsonDecode(saved);
      for (final entry in json is List ? json : const []) {
        final p = fromJson(entry);
        if (p != null && !list.any((q) => q.id == p.id)) list.add(p);
      }
    } on FormatException {
      // Not JSON: the built-in ones, as new.
    }
    return [...list, for (final b in builtIns) if (!list.any((p) => p.id == b.id)) b];
  }

  static String write(List<AiProvider> providers) => jsonEncode([for (final p in providers) p.toJson()]);

  @override
  bool operator ==(Object other) =>
      other is AiProvider &&
      other.id == id &&
      other.name == name &&
      other.format == format &&
      other.enabled == enabled &&
      other.apiKey == apiKey &&
      other.baseUrl == baseUrl &&
      other.path == path &&
      listEquals(other.models, models) &&
      mapEquals(other.details, details) &&
      other.headers == headers &&
      other.body == body;

  @override
  int get hashCode => Object.hash(id, name, format, enabled, apiKey, baseUrl, path, Object.hashAll(models),
      Object.hashAllUnordered([for (final MapEntry(:key, :value) in details.entries) Object.hash(key, value)]), headers, body);
}

/// A model of a provider's: what a setting picks to do something with ([AppSettings.pdfAiModel]).
typedef AiModel = ({AiProvider provider, String model});

extension AiModels on List<AiProvider> {
  /// Every model of the providers turned on, in their order.
  List<AiModel> get models => [
        for (final p in this)
          if (p.enabled)
            for (final m in p.models) (provider: p, model: m),
      ];

  /// The model a setting keeps as [saved] ([keyOf]), while its provider is on and has it.
  AiModel? model(String saved) => models.where((m) => keyOf(m) == saved).firstOrNull;

  /// How a setting keeps [model]: its provider's id, a slash, its ID (which may hold slashes too).
  static String keyOf(AiModel model) => '${model.provider.id}/${model.model}';
}

/// What a provider's server answered when it refused, or why it couldn't be reached.
class AiError implements Exception {
  const AiError(this.message, {this.status});
  final String message;

  /// The HTTP status, when the server answered.
  final int? status;

  @override
  String toString() => status == null ? message : 'HTTP $status: $message';
}

/// Talks to one [provider]'s API: its model list ([models]) and a one-word request to a model
/// ([test]). The key goes only to the provider's own base URL: redirects are not followed.
class AiClient {
  AiClient(this.provider, {this.timeout = const Duration(seconds: 30), this.mostBytes = 32 << 20});

  final AiProvider provider;

  /// How long a server may take to answer (a model reading a page: minutes).
  final Duration timeout;

  /// The most a server may answer, bytes: a model list or an answer about a page is far under
  /// it. Past it the request is ended: an address that is no API's (a file's, a stream's) isn't
  /// read whole into memory.
  final int mostBytes;

  /// Reaching a server takes seconds, however long its answer may.
  static const _connecting = Duration(seconds: 30);

  /// The base URL as typed, without a trailing slash; an error when it isn't an http(s) URL.
  Uri _base() {
    final text = provider.baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(text);
    if (uri == null || !(uri.isScheme('https') || uri.isScheme('http')) || uri.host.isEmpty) {
      throw AiError('The base URL isn’t a web address.'.tr);
    }
    return uri;
  }

  /// [path] (and [query]) after the base URL.
  Uri _at(String path, [Map<String, String>? query]) {
    final base = _base();
    final rest = path.startsWith('/') ? path : '/$path';
    return base.replace(path: '${base.path}$rest', queryParameters: query == null ? null : {...base.queryParameters, ...query});
  }

  /// The key, where the provider's API wants it, then the provider's custom headers and [model]'s
  /// (a header named again replaces the one before: a custom Authorization, the key's). An error
  /// when the key can't go in a header (which holds printable ASCII), in words that don't repeat
  /// the key, as dart:io's do; or when the custom ones aren't headers ([headersIn]).
  Map<String, String> _headersFor(String? model) {
    final key = provider.apiKey.trim();
    if (key.codeUnits.any((c) => c < 0x20 || c > 0x7e)) throw AiError('The API key has invalid characters.'.tr);
    return {
      ...switch (provider.format) {
        AiFormat.openai => {if (key.isNotEmpty) 'authorization': 'Bearer $key'},
        AiFormat.anthropic => {if (key.isNotEmpty) 'x-api-key': key, 'anthropic-version': '2023-06-01'},
        AiFormat.gemini => {if (key.isNotEmpty) 'x-goog-api-key': key},
      },
      ...headersIn(provider.headers),
      if (model != null) ...headersIn(provider.infoOf(model).headers),
    };
  }

  /// The headers [text] holds, one "Name: value" a line (blank lines passed over), by name in
  /// lower case (as HTTP's are the same in any case); an [AiError] naming the line that isn't one,
  /// or that holds what a header can't (a value: printable ASCII), never repeating a value (which
  /// may be a key).
  static Map<String, String> headersIn(String text) {
    final headers = <String, String>{};
    for (final (i, line) in text.split('\n').indexed) {
      if (line.trim().isEmpty) continue;
      final colon = line.indexOf(':');
      final name = colon < 0 ? '' : line.substring(0, colon).trim();
      if (name.isEmpty) throw AiError('Custom headers, line {line}: not “Name: value”.'.fill({'line': i + 1}));
      final value = line.substring(colon + 1).trim();
      if (!RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$").hasMatch(name) || value.codeUnits.any((c) => (c < 0x20 && c != 0x09) || c > 0x7e)) {
        throw AiError('Custom headers, line {line}: characters a header can’t hold.'.fill({'line': i + 1}));
      }
      headers[name.toLowerCase()] = value;
    }
    return headers;
  }

  /// The JSON object [text] holds (none when it is blank); an [AiError] when it isn't one.
  static Map<String, Object?> bodyIn(String text) {
    if (text.trim().isEmpty) return const {};
    try {
      if (jsonDecode(text) case final Map<String, Object?> body) return body;
    } on FormatException {
      // said below
    }
    throw AiError('The custom body isn’t a JSON object.'.tr);
  }

  /// [body] (a request asking [model]) with the provider's custom body merged in, then the
  /// model's: an object in both merged the same way, a null taking its name out, anything else
  /// in place of what was there.
  Map<String, Object?> _bodyFor(String model, Map<String, Object?> body) =>
      _merged(_merged(body, bodyIn(provider.body)), bodyIn(provider.infoOf(model).body));

  static Map<String, Object?> _merged(Map base, Map extra) {
    final merged = <String, Object?>{for (final MapEntry(:key, :value) in base.entries) '$key': value};
    for (final MapEntry(:key, :value) in extra.entries) {
      final was = merged['$key'];
      if (value == null) {
        merged.remove('$key');
      } else {
        merged['$key'] = was is Map && value is Map ? _merged(was, value) : value;
      }
    }
    return merged;
  }

  /// The models the provider offers, by ID in its order (several pages of them, where it pages
  /// its list), each with what the list says of it ([infoIn]). Gemini's: those that can write
  /// text.
  Future<Map<String, AiModelInfo>> models() async {
    final ids = <String, AiModelInfo>{};
    String? after;
    for (var page = 0; page < 50; page++) {
      final json = await _send(null, 'GET', switch (provider.format) {
        AiFormat.openai => _at('/models'),
        AiFormat.anthropic => _at('/models', {'limit': '1000', 'after_id': ?after}),
        AiFormat.gemini => _at('/models', {'pageSize': '1000', 'pageToken': ?after}),
      });
      if (json is! Map) throw AiError('The server’s answer isn’t a list of models.'.tr);
      final list = json[provider.format == AiFormat.gemini ? 'models' : 'data'];
      if (list is! List) throw AiError('The server’s answer isn’t a list of models.'.tr);
      for (final m in list.whereType<Map>()) {
        final id = switch (provider.format) {
          AiFormat.gemini => switch ((m['name'], m['supportedGenerationMethods'])) {
              (final String name, final List methods) when methods.contains('generateContent') =>
                name.replaceFirst(RegExp('^models/'), ''),
              (final String name, null) => name.replaceFirst(RegExp('^models/'), ''),
              _ => null,
            },
          _ => switch (m['id']) { final String id => id, _ => null },
        };
        if (id != null && id.isNotEmpty) ids.putIfAbsent(id, () => infoIn(m, provider.format));
      }
      after = switch ((provider.format, json['last_id'], json['nextPageToken'])) {
        (AiFormat.anthropic, final String last, _) when json['has_more'] == true => last,
        (AiFormat.gemini, _, final String next) => next,
        _ => null,
      };
      if (after == null || after.isEmpty) break;
    }
    return ids;
  }

  /// What an entry of a model list ([m]) says of the model, in [format]; null where it says
  /// nothing. Read from where the providers known here say it: Anthropic's capabilities and
  /// max_input_tokens; Gemini's inputTokenLimit and thinking (a model that doesn't think leaves
  /// it out); OpenRouter's architecture, reasoning, supported_parameters and context_length; and
  /// other servers of OpenAI's format: Mistral's capabilities, LM Studio's type ("vlm"), Groq's
  /// context_window, vLLM's max_model_len. Gemini's list says nothing of images.
  @visibleForTesting
  static AiModelInfo infoIn(Map m, AiFormat format) {
    bool? supported(Object? v) => switch (v) { {'supported': final bool b} => b, final bool b => b, _ => null };
    int? count(Object? v) => switch (v) {
          final int n when n > 0 => n,
          final double d when d >= 1 && d.isFinite => d.round(),
          _ => null,
        };
    final capabilities = m['capabilities'] is Map ? m['capabilities'] as Map : const {};
    final modalities = switch (m) {
      {'architecture': {'input_modalities': final List l}} => l,
      {'input_modalities': final List l} => l,
      _ => null,
    };
    final parameters = switch (m['supported_parameters']) { final List l => l, _ => null };
    const reasons = ['reasoning', 'include_reasoning', 'reasoning_effort'];
    return AiModelInfo(
      vision: modalities?.contains('image') ??
          supported(capabilities['image_input']) ??
          supported(capabilities['vision']) ??
          switch (m['type']) { 'vlm' => true, 'llm' => false, _ => null },
      reasoning: m['reasoning'] is Map
          ? true
          : parameters?.any(reasons.contains) ??
              supported(capabilities['thinking']) ??
              supported(capabilities['reasoning']) ??
              (format == AiFormat.gemini ? m['thinking'] == true : null),
      context: count(m['max_input_tokens']) ??
          count(m['inputTokenLimit']) ??
          count(m['context_length']) ??
          count(switch (m['top_provider']) { {'context_length': final Object n} => n, _ => null }) ??
          count(m['context_window']) ??
          count(m['max_context_length']) ??
          count(m['max_model_len']),
    );
  }

  /// Asks [model] for a word, through the provider's API path; throws an [AiError] when it
  /// doesn't answer. Without a [model], asks for the model list instead (the key and the base
  /// URL, not the path).
  Future<void> test([String? model]) async {
    if (model == null) {
      await models();
      return;
    }
    const prompt = 'Hi';
    final path = (provider.path.trim().isEmpty ? provider.format.path : provider.path.trim())
        .replaceAll('{model}', Uri.encodeComponent(model));
    await _send(model, 'POST', _at(path), _bodyFor(model, switch (provider.format) {
      AiFormat.openai => {
          'model': model,
          'messages': [
            {'role': 'user', 'content': prompt},
          ],
        },
      AiFormat.anthropic => {
          'model': model,
          'max_tokens': 1,
          'messages': [
            {'role': 'user', 'content': prompt},
          ],
        },
      AiFormat.gemini => {
          'contents': [
            {
              'parts': [
                {'text': prompt},
              ],
            },
          ],
        },
    }));
  }

  /// Asks [model] [prompt] about [images] (PNG pictures, put before the words), through the
  /// provider's API path; the text it answers. Throws an [AiError] when it doesn't answer.
  Future<String> ask(String model, String prompt, {List<Uint8List> images = const []}) async {
    final path = (provider.path.trim().isEmpty ? provider.format.path : provider.path.trim())
        .replaceAll('{model}', Uri.encodeComponent(model));
    final pictures = [for (final i in images) base64Encode(i)];
    final json = await _send(model, 'POST', _at(path), _bodyFor(model, switch (provider.format) {
      AiFormat.openai => {
          'model': model,
          'messages': [
            {
              'role': 'user',
              'content': [
                for (final p in pictures)
                  {
                    'type': 'image_url',
                    'image_url': {'url': 'data:image/png;base64,$p'},
                  },
                {'type': 'text', 'text': prompt},
              ],
            },
          ],
        },
      AiFormat.anthropic => {
          'model': model,
          'max_tokens': 8192,
          'messages': [
            {
              'role': 'user',
              'content': [
                for (final p in pictures)
                  {
                    'type': 'image',
                    'source': {'type': 'base64', 'media_type': 'image/png', 'data': p},
                  },
                {'type': 'text', 'text': prompt},
              ],
            },
          ],
        },
      AiFormat.gemini => {
          'contents': [
            {
              'parts': [
                for (final p in pictures)
                  {
                    'inline_data': {'mime_type': 'image/png', 'data': p},
                  },
                {'text': prompt},
              ],
            },
          ],
          'generationConfig': {'responseMimeType': 'application/json'},
        },
    }));
    final text = _answer(json);
    if (text == null || text.trim().isEmpty) throw AiError('The server’s answer has no text.'.tr);
    return text;
  }

  /// The words of a chat answer: OpenAI's first choice's message, Anthropic's text blocks,
  /// Gemini's first candidate's parts.
  static String? _answer(Object? json) {
    String? joined(Object? parts, String key) => parts is List
        ? [
            for (final p in parts)
              if (p is Map && p[key] is String) p[key] as String,
          ].join()
        : null;
    if (json is! Map) return null;
    return switch (json) {
      {'choices': [{'message': {'content': final String text}}, ...]} => text,
      {'choices': [{'message': {'content': final List parts}}, ...]} => joined(parts, 'text'),
      {'content': final List blocks} => joined(blocks, 'text'),
      {'candidates': [{'content': {'parts': final List parts}}, ...]} => joined(parts, 'text'),
      _ => null,
    };
  }

  final _open = <HttpClient>{};
  var _closed = false;

  /// Ends every request under way, and any asked after: each throws.
  void close() {
    _closed = true;
    for (final c in [..._open]) {
      c.close(force: true);
    }
  }

  /// The JSON a request (asking [model], when it does) answers with; an [AiError] with the
  /// server's message when it refuses.
  Future<Object?> _send(String? model, String method, Uri uri, [Object? body]) async {
    if (_closed) throw StateError('closed');
    final headers = _headersFor(model); // before anything is opened: a key that can't be sent
    final client = HttpClient()
      ..connectionTimeout = timeout < _connecting ? timeout : _connecting
      ..userAgent = 'Curator/$appVersion';
    _open.add(client);
    try {
      final request = await client.openUrl(method, uri).timeout(timeout);
      if (_closed) {
        // Closed while its connection was being made, which closing the HttpClient doesn't end:
        // ended now it is made, before anything is sent.
        request.abort();
        throw StateError('closed');
      }
      request.followRedirects = false; // the key stays with this server
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) request.headers.contentType = ContentType.json;
      headers.forEach(request.headers.set); // after those: a custom Accept or Content-Type in their place
      if (body != null) request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close().timeout(timeout);
      final bytes = BytesBuilder(copy: false);
      await response.forEach((chunk) {
        bytes.add(chunk);
        if (bytes.length > mostBytes) throw AiError('The server’s answer is too long.'.tr);
      }).timeout(timeout);
      // (Bytes that are no UTF-8 are no JSON either: said below, not as a decoder's error.)
      final text = const Utf8Decoder(allowMalformed: true).convert(bytes.takeBytes());
      Object? json;
      try {
        json = text.isEmpty ? null : jsonDecode(text);
      } on FormatException {
        json = null;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AiError(_message(json) ?? (response.reasonPhrase.isEmpty ? 'No answer.'.tr : response.reasonPhrase),
            status: response.statusCode);
      }
      if (json == null && text.isNotEmpty) throw AiError('The server’s answer isn’t JSON.'.tr);
      return json;
    } on AiError {
      rethrow;
    } on TimeoutException {
      throw AiError('The server didn’t answer in time.'.tr);
    } on SocketException catch (e) {
      throw AiError(e.osError?.message.isNotEmpty == true ? e.osError!.message : e.message);
    } on TlsException catch (e) {
      // A handshake refused, or a certificate that isn't the server's.
      throw AiError(e.message.isNotEmpty ? e.message : '$e');
    } on HttpException catch (e) {
      throw AiError(e.message);
    } finally {
      _open.remove(client);
      client.close(force: true);
    }
  }

  /// The message in an API's error answer: `{"error": {"message": …}}` (OpenAI, Anthropic,
  /// Gemini and most others), or `{"error": "…"}`, `{"message": "…"}`.
  static String? _message(Object? json) {
    if (json is List && json.isNotEmpty) return _message(json.first); // Gemini, sometimes
    if (json is! Map) return null;
    return switch (json['error']) {
      {'message': final String m} => m,
      final String m => m,
      _ => switch (json['message']) { final String m => m, _ => null },
    };
  }
}
