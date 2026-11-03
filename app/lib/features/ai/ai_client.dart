import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../bridge/api.dart';

/// One model offered by `/models`.
class AiModel {
  const AiModel({required this.id, this.name});

  final String id;
  final String? name;

  String get label => (name == null || name!.isEmpty) ? id : '$name ($id)';
}

/// A failure with a message already suitable for the user.
class AiException implements Exception {
  AiException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Provider presets. The endpoint stays editable for self-hosted gateways.
const aiProviders = <String, ({String label, String endpoint})>{
  'zen': (label: 'OpenCode Zen', endpoint: 'https://opencode.ai/zen/v1'),
  'go': (
    label: 'OpenCode Go',
    endpoint: 'https://opencode.ai/inference/go/openai/v1',
  ),
  'openrouter': (label: 'OpenRouter', endpoint: 'https://openrouter.ai/api/v1'),
  'custom': (label: 'Другой (свой endpoint)', endpoint: ''),
};

String aiKeyId(String provider) => 'ai_key_$provider';

String aiProviderLabel(String provider) =>
    aiProviders[provider]?.label ?? provider;

/// `/models` for an OpenAI-compatible chat base.
///
/// OpenCode's inference gateway puts the list one level above the chat base:
///   chat   https://opencode.ai/inference/go/openai/v1/chat/completions
///   models https://opencode.ai/inference/go/v1/models
/// Zen and OpenRouter keep both under the same base.
String modelsEndpoint(String endpoint) {
  final base = endpoint.trim().replaceAll(RegExp(r'/+$'), '');
  final modelsBase = base.endsWith('/openai/v1')
      ? '${base.substring(0, base.length - '/openai/v1'.length)}/v1'
      : base;
  return '$modelsBase/models';
}

/// Minimal OpenAI-compatible client: `GET /models` and `POST /chat/completions`.
///
/// Kept on `dart:io` so no extra dependency is added to the app.
class AiClient {
  AiClient({
    required this.endpoint,
    required this.apiKey,
    required this.model,
    String? sessionId,
  }) : sessionId = sessionId ?? _newSessionId();

  final String endpoint;
  final String apiKey;
  final String model;

  /// OpenCode Go routes requests by this header and rejects requests without
  /// it (`MissingSessionID`). One id per dialog keeps routing and the prompt
  /// cache stable within a conversation.
  final String sessionId;

  static final Random _random = Random();

  static String _newSessionId() {
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final tail = _random.nextInt(0x7fffffff).toRadixString(36);
    return 'ses_nova${stamp}${tail}';
  }

  String get _base => endpoint.trim().replaceAll(RegExp(r'/+$'), '');

  Uri _uri(String path) {
    final base = _base;
    if (base.isEmpty) {
      throw AiException('Не задан endpoint — откройте Настройки → ИИ');
    }
    return Uri.parse('$base$path');
  }

  Uri _modelsUri() => Uri.parse(modelsEndpoint(_base));

  HttpClient _http() {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 15);
    return client;
  }

  Map<String, String> _headers() => {
    'Authorization': 'Bearer $apiKey',
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    // Go asks clients to identify themselves and to carry a stable session.
    'User-Agent': 'NovaSSH/1.0',
    'x-opencode-session': sessionId,
    // OpenRouter likes these, other providers ignore them.
    'HTTP-Referer': 'https://novassh.local',
    'X-Title': 'Nova SSH',
  };

  /// Loads the model list. Doubles as the "Проверить ключ" action.
  Future<List<AiModel>> fetchModels() async {
    if (apiKey.trim().isEmpty) {
      throw AiException('Не задан API-ключ');
    }
    final client = _http();
    try {
      final request = await client
          .getUrl(_modelsUri())
          .timeout(const Duration(seconds: 25));
      request.headers.set('Authorization', 'Bearer $apiKey');
      request.headers.set('Accept', 'application/json');
      request.headers.set('User-Agent', 'NovaSSH/1.0');
      request.headers.set('x-opencode-session', sessionId);
      final response = await request.close().timeout(
        const Duration(seconds: 25),
      );
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw AiException(_statusError(response.statusCode, body));
      }
      final decoded = jsonDecode(body);
      final data = decoded is Map ? decoded['data'] : decoded;
      if (data is! List) {
        throw AiException('Ответ /models непонятен: ${_excerpt(body)}');
      }
      final models = <AiModel>[];
      for (final item in data) {
        if (item is String) {
          models.add(AiModel(id: item));
        } else if (item is Map) {
          final id = '${item['id'] ?? item['name'] ?? ''}'.trim();
          if (id.isEmpty) continue;
          final name = '${item['name'] ?? ''}'.trim();
          models.add(AiModel(id: id, name: name.isEmpty ? null : name));
        }
      }
      models.sort((a, b) => a.id.toLowerCase().compareTo(b.id.toLowerCase()));
      return models;
    } on AiException {
      rethrow;
    } on TimeoutException {
      throw AiException(
        'Сервер не ответил вовремя — проверьте endpoint и сеть',
      );
    } on SocketException catch (e) {
      throw AiException('Нет связи с ${_base}: ${e.message}');
    } on FormatException {
      throw AiException('Ответ не похож на JSON — проверьте endpoint');
    } finally {
      client.close(force: true);
    }
  }

  /// Asks for one shell command. The answer is cleaned of markdown and `$`.
  Future<String> askCommand({
    required String question,
    String context = '',
  }) async {
    if (apiKey.trim().isEmpty) {
      throw AiException('Не задан API-ключ');
    }
    if (model.trim().isEmpty) {
      throw AiException('Не выбрана модель — откройте Настройки → ИИ');
    }
    final client = _http();
    try {
      final request = await client
          .postUrl(_uri('/chat/completions'))
          .timeout(const Duration(seconds: 25));
      _headers().forEach(request.headers.set);
      const system =
          'Ты — помощник по администрированию Linux-сервера. '
          'Ответ — ровно одна команда оболочки: без пояснений, без markdown, '
          'без обратных кавычек и без знака \$ в начале. '
          'Если нужно несколько действий, соедини их через && в одну строку. '
          'Если задача невыполнима одной командой, дай ближайшую подходящую.';
      final user = StringBuffer();
      if (context.trim().isNotEmpty) {
        user.writeln('Контекст сервера:');
        user.writeln(context.trim());
        user.writeln();
      }
      user.write(question.trim());
      request.headers.contentType = ContentType(
        'application',
        'json',
        charset: 'utf-8',
      );
      request.add(
        utf8.encode(
          jsonEncode({
            'model': model.trim(),
            'temperature': 0,
            'max_tokens': 300,
            'messages': [
              {'role': 'system', 'content': system},
              {'role': 'user', 'content': user.toString()},
            ],
          }),
        ),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 60),
      );
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 60));
      if (response.statusCode != 200) {
        throw AiException(_statusError(response.statusCode, body));
      }
      final decoded = jsonDecode(body);
      final choices = decoded is Map ? decoded['choices'] : null;
      if (choices is! List || choices.isEmpty) {
        throw AiException('Модель не вернула ответ: ${_excerpt(body)}');
      }
      final message = choices.first is Map ? choices.first['message'] : null;
      final content = message is Map ? message['content'] : null;
      final command = cleanCommand('${content ?? ''}');
      if (command.isEmpty) {
        throw AiException('Модель вернула пустой ответ');
      }
      return command;
    } on AiException {
      rethrow;
    } on TimeoutException {
      throw AiException('Модель не ответила вовремя — попробуйте ещё раз');
    } on SocketException catch (e) {
      throw AiException('Нет связи с ${_base}: ${e.message}');
    } on FormatException {
      throw AiException('Ответ сервера не похож на JSON');
    } finally {
      client.close(force: true);
    }
  }

  static String _statusError(int status, String body) {
    final hint = switch (status) {
      400 => 'запрос отклонён',
      401 => 'неверный API-ключ',
      402 => 'на счету провайдера нет средств',
      403 => 'доступ запрещён',
      404 => 'endpoint или модель не найдены',
      429 => 'слишком много запросов, подождите',
      500 || 502 || 503 || 504 => 'ошибка на стороне провайдера',
      _ => 'ошибка $status',
    };
    return '$hint (HTTP $status)\n${_excerpt(body)}';
  }

  static String _excerpt(String text) {
    final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty) return '';
    return clean.length <= 220 ? clean : '${clean.substring(0, 220)}…';
  }
}

/// Strips fences, a leading `$` and empty lines; providers are not consistent.
String cleanCommand(String raw) {
  var text = raw.trim();
  if (text.startsWith('```')) {
    text = text.replaceFirst(RegExp(r'^```[a-zA-Z0-9_+-]*\s*'), '');
    text = text.replaceFirst(RegExp(r'\s*```$'), '');
  }
  final lines = text
      .split('\n')
      .map((line) => line.trimRight())
      .where((line) => line.trim().isNotEmpty)
      .toList();
  text = lines.join('\n').trim();
  if (text.startsWith(r'$ ')) text = text.substring(2).trim();
  if (text.length > 1 && text.startsWith('`') && text.endsWith('`')) {
    text = text.substring(1, text.length - 1).trim();
  }
  return text;
}

/// Loads the configured client, or null when the assistant is disabled or has
/// no key yet.
Future<AiClient?> configuredAiClient() async {
  final settings = await loadAiSettings();
  if (!settings.enabled) return null;
  final key = (await getSecret(id: aiKeyId(settings.provider)))?.trim() ?? '';
  if (key.isEmpty) return null;
  return AiClient(
    endpoint: settings.endpoint,
    apiKey: key,
    model: settings.model,
  );
}

/// True when a key exists for the provider (used to decide whether to show ✨).
Future<bool> aiReady() async {
  try {
    final settings = await loadAiSettings();
    if (!settings.enabled) return false;
    final key = (await getSecret(id: aiKeyId(settings.provider)))?.trim() ?? '';
    return key.isNotEmpty;
  } catch (_) {
    return false;
  }
}

/// Context line sent with every question.
String describeAiContext({
  required String host,
  required String user,
  required int port,
  required String serverName,
  required String cwd,
  String? uname,
}) {
  final lines = <String>[
    'хост: $host:$port',
    'пользователь: $user',
    'подключение: $serverName',
    'текущий каталог: $cwd',
  ];
  if (uname != null && uname.trim().isNotEmpty) {
    lines.add('система: ${uname.trim()}');
  }
  return lines.join('\n');
}
