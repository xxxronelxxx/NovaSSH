import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova/features/ai/ai_client.dart';

/// Talks to a throwaway local OpenAI-compatible server: this checks the wire
/// format and error handling without touching any real provider.
void main() {
  late HttpServer server;
  late String base;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}/v1';
    server.listen((request) async {
      final auth = request.headers.value('authorization');
      if (auth != 'Bearer test-key') {
        request.response.statusCode = 401;
        request.response.write('{"error":{"message":"bad key"}}');
        await request.response.close();
        return;
      }
      // OpenCode Go rejects requests without a session id.
      final session = request.headers.value('x-opencode-session');
      if (session == null || !session.startsWith('ses_')) {
        request.response.statusCode = 400;
        request.response.write(
          '{"error":{"type":"MissingSessionID","message":"missing"}}',
        );
        await request.response.close();
        return;
      }
      expect(request.headers.value('user-agent'), contains('NovaSSH'));
      if (request.uri.path.endsWith('/models')) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {'id': 'b-model', 'name': 'Model B'},
              {'id': 'a-model'},
            ],
          }),
        );
        await request.response.close();
        return;
      }
      final body = await utf8.decoder.bind(request).join();
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      expect(decoded['model'], 'a-model');
      expect(decoded['messages'], isA<List>());
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'choices': [
            {
              'message': {
                'role': 'assistant',
                'content': '```bash\ndf -h\n```',
              },
            },
          ],
        }),
      );
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('lists models and asks for one clean command', () async {
    final client = AiClient(
      endpoint: base,
      apiKey: 'test-key',
      model: 'a-model',
    );
    final models = await client.fetchModels();
    expect(models.map((m) => m.id), ['a-model', 'b-model']);

    final command = await client.askCommand(
      question: 'как узнать место на диске',
      context: 'хост: example',
    );
    expect(command, 'df -h');
  });

  test('every request carries the Go session and client headers', () async {
    final client = AiClient(
      endpoint: base,
      apiKey: 'test-key',
      model: 'a-model',
      sessionId: 'ses_nova_test',
    );
    expect(await client.fetchModels(), isNotEmpty);
    expect(await client.askCommand(question: 'uptime'), 'df -h');
    expect(client.sessionId, 'ses_nova_test');
  });

  test('a wrong key is reported in plain language', () async {
    final client = AiClient(endpoint: base, apiKey: 'wrong', model: 'a-model');
    expect(
      () => client.fetchModels(),
      throwsA(
        isA<AiException>().having(
          (e) => e.message,
          'message',
          contains('неверный API-ключ'),
        ),
      ),
    );
  });
}
