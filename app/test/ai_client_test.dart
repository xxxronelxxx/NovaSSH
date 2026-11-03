import 'package:flutter_test/flutter_test.dart';
import 'package:nova/features/ai/ai_client.dart';

/// The assistant must return exactly one command: providers like to wrap it in
/// markdown or prefix it with `$`, and both break a terminal paste.
void main() {
  test('strips markdown fences and the dollar prefix', () {
    expect(cleanCommand('```bash\ndf -h\n```'), 'df -h');
    expect(cleanCommand(r'$ ls -la'), 'ls -la');
    expect(cleanCommand('`uptime`'), 'uptime');
  });

  test('keeps a multi-line answer but drops empty lines', () {
    expect(
      cleanCommand('cd /var/www\n\n  && ls -la  \n'),
      'cd /var/www\n  && ls -la',
    );
  });

  test('the models endpoint is derived from the chat base', () {
    expect(
      modelsEndpoint('https://opencode.ai/zen/v1'),
      'https://opencode.ai/zen/v1/models',
    );
    expect(
      modelsEndpoint('https://opencode.ai/inference/go/openai/v1'),
      'https://opencode.ai/inference/go/v1/models',
    );
    expect(
      modelsEndpoint('https://openrouter.ai/api/v1/'),
      'https://openrouter.ai/api/v1/models',
    );
  });

  test('provider presets point at OpenAI-compatible bases', () {
    expect(aiProviders['zen']!.endpoint, 'https://opencode.ai/zen/v1');
    expect(
      aiProviders['go']!.endpoint,
      'https://opencode.ai/inference/go/openai/v1',
    );
    expect(aiProviders['openrouter']!.endpoint, 'https://openrouter.ai/api/v1');
    expect(aiKeyId('zen'), 'ai_key_zen');
  });
}
