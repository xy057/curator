import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

/// One AI service and the credentials for it (Settings ▸ AI): an API key, where its API is, and
/// the models chosen from it. Kept in the app's settings ([AppSettings.aiProviders]), for every
/// project. Five come with the app ([builtIns]); the user can add others, which speak one of the
/// [AiFormat]s.
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
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'format': format.name,
        'enabled': enabled,
        'apiKey': apiKey,
        'baseUrl': baseUrl,
        'path': path,
        'models': models,
      };

  /// One read back from [toJson]; null when it isn't one (a damaged entry is left out).
  static AiProvider? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'], name = json['name'];
    if (id is! String || id.isEmpty || name is! String) return null;
    String text(String key) => switch (json[key]) { final String s => s, _ => '' };
    final builtIn = builtIns.where((p) => p.id == id).firstOrNull;
    return AiProvider(
      id: id,
      name: name,
      // A built-in one speaks its own format, whatever was saved.
      format: builtIn?.format ?? AiFormat.named(json['format'] as String?),
      enabled: json['enabled'] == true,
      apiKey: text('apiKey'),
      baseUrl: text('baseUrl'),
      path: text('path'),
      models: [
        for (final m in json['models'] is List ? json['models'] as List : const [])
          if (m is String && m.isNotEmpty) m,
      ],
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
      listEquals(other.models, models);

  @override
  int get hashCode => Object.hash(id, name, format, enabled, apiKey, baseUrl, path, Object.hashAll(models));
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
  AiClient(this.provider, {this.timeout = const Duration(seconds: 30)});

  final AiProvider provider;
  final Duration timeout;

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

  Map<String, String> get _headers {
    final key = provider.apiKey.trim();
    return switch (provider.format) {
      AiFormat.openai => {if (key.isNotEmpty) 'Authorization': 'Bearer $key'},
      AiFormat.anthropic => {if (key.isNotEmpty) 'x-api-key': key, 'anthropic-version': '2023-06-01'},
      AiFormat.gemini => {if (key.isNotEmpty) 'x-goog-api-key': key},
    };
  }

  /// The IDs of the models the provider offers, in its order (several pages of them, where it
  /// pages its list). Gemini's: those that can write text.
  Future<List<String>> models() async {
    final ids = <String>[];
    String? after;
    for (var page = 0; page < 50; page++) {
      final json = await _send('GET', switch (provider.format) {
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
          _ => m['id'] as String?,
        };
        if (id != null && id.isNotEmpty && !ids.contains(id)) ids.add(id);
      }
      after = switch (provider.format) {
        AiFormat.anthropic when json['has_more'] == true => json['last_id'] as String?,
        AiFormat.gemini => json['nextPageToken'] as String?,
        _ => null,
      };
      if (after == null || after.isEmpty) break;
    }
    return ids;
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
    await _send('POST', _at(path), switch (provider.format) {
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
    });
  }

  /// The JSON a request answers with; an [AiError] with the server's message when it refuses.
  Future<Object?> _send(String method, Uri uri, [Object? body]) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..userAgent = 'Curator/$appVersion';
    try {
      final request = await client.openUrl(method, uri).timeout(timeout);
      request.followRedirects = false; // the key stays with this server
      _headers.forEach(request.headers.set);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(jsonEncode(body)));
      }
      final response = await request.close().timeout(timeout);
      final text = await response.transform(utf8.decoder).join().timeout(timeout);
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
    } on HandshakeException catch (e) {
      throw AiError(e.message);
    } on HttpException catch (e) {
      throw AiError(e.message);
    } finally {
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
