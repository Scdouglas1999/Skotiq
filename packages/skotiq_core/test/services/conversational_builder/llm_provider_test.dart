// LlmProvider implementation tests.
//
// Each provider is exercised against a MockClient that asserts the
// wire shape (path, headers, body) and returns a canned response. The
// canned response also covers the error path so we know exceptions
// are raised with the right context.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('OpenAiCompatibleProvider', () {
    test('sends a /v1/chat/completions POST with bearer auth', () async {
      late http.Request seen;
      final client = MockClient((req) async {
        seen = req;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': '{"ok":true}'},
              },
            ],
            'usage': {
              'prompt_tokens': 12,
              'completion_tokens': 5,
              'total_tokens': 17,
            },
          }),
          200,
        );
      });

      final provider = OpenAiCompatibleProvider(
        httpClient: client,
        config: const LlmProviderConfig(
          baseUrl: 'https://api.openai.example',
          model: 'gpt-4o-mini',
          apiKey: 'sk-test',
        ),
      );
      final response = await provider.generate(
        systemPrompt: 'sys',
        userPrompt: 'user',
      );

      expect(
        seen.url.toString(),
        'https://api.openai.example/v1/chat/completions',
      );
      expect(seen.method, 'POST');
      expect(seen.headers['Authorization'], 'Bearer sk-test');
      final body = jsonDecode(seen.body) as Map<String, dynamic>;
      expect(body['model'], 'gpt-4o-mini');
      expect((body['messages'] as List).length, 2);
      expect((body['messages'] as List).first['role'], 'system');
      expect((body['messages'] as List).last['role'], 'user');
      expect(response.text, '{"ok":true}');
      expect(response.usage?.totalTokens, 17);
      provider.close();
    });

    test('throws LlmProviderException on non-2xx', () async {
      final client = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'error': {'message': 'Invalid API key'},
          }),
          401,
        );
      });
      final provider = OpenAiCompatibleProvider(
        httpClient: client,
        config: const LlmProviderConfig(
          baseUrl: 'https://api.openai.example',
          model: 'gpt-4o-mini',
          apiKey: 'bad',
        ),
      );
      expect(
        () => provider.generate(systemPrompt: 's', userPrompt: 'u'),
        throwsA(
          isA<LlmProviderException>().having(
            (e) => e.statusCode,
            'status',
            401,
          ),
        ),
      );
      provider.close();
    });

    test('isConfigured requires base URL + model (key optional)', () {
      expect(
        OpenAiCompatibleProvider(
          httpClient: MockClient((_) async => http.Response('', 200)),
          config: const LlmProviderConfig(baseUrl: '', model: ''),
        ).isConfigured,
        isFalse,
      );
      expect(
        OpenAiCompatibleProvider(
          httpClient: MockClient((_) async => http.Response('', 200)),
          config: const LlmProviderConfig(
            baseUrl: 'http://localhost:1234',
            model: 'local-llm',
          ),
        ).isConfigured,
        isTrue,
      );
    });
  });

  group('AnthropicProvider', () {
    test(
      'sends a /v1/messages POST with x-api-key and version headers',
      () async {
        late http.Request seen;
        final client = MockClient((req) async {
          seen = req;
          return http.Response(
            jsonEncode({
              'content': [
                {'type': 'text', 'text': '{"ok":true}'},
              ],
              'usage': {'input_tokens': 10, 'output_tokens': 4},
            }),
            200,
          );
        });
        final provider = AnthropicProvider(
          httpClient: client,
          config: const LlmProviderConfig(
            baseUrl: 'https://api.anthropic.example',
            model: 'claude-opus-4',
            apiKey: 'anth-test',
            anthropicVersion: '2024-01-01',
          ),
        );
        final res = await provider.generate(
          systemPrompt: 'sys',
          userPrompt: 'u',
        );

        expect(
          seen.url.toString(),
          'https://api.anthropic.example/v1/messages',
        );
        expect(seen.headers['x-api-key'], 'anth-test');
        expect(seen.headers['anthropic-version'], '2024-01-01');
        final body = jsonDecode(seen.body) as Map<String, dynamic>;
        expect(body['system'], 'sys');
        expect((body['messages'] as List).single['role'], 'user');
        expect(res.text, '{"ok":true}');
        expect(res.usage?.promptTokens, 10);
        expect(res.usage?.completionTokens, 4);
        expect(res.usage?.totalTokens, 14);
        provider.close();
      },
    );

    test('isConfigured requires API key', () {
      expect(
        AnthropicProvider(
          httpClient: MockClient((_) async => http.Response('', 200)),
          config: const LlmProviderConfig(
            baseUrl: 'https://api.anthropic.example',
            model: 'claude-opus-4',
          ),
        ).isConfigured,
        isFalse,
      );
    });
  });

  group('OllamaLocalProvider', () {
    test('sends a /api/chat POST without auth headers', () async {
      late http.Request seen;
      final client = MockClient((req) async {
        seen = req;
        return http.Response(
          jsonEncode({
            'message': {'role': 'assistant', 'content': '{"ok":true}'},
            'prompt_eval_count': 100,
            'eval_count': 42,
          }),
          200,
        );
      });
      final provider = OllamaLocalProvider(
        httpClient: client,
        config: const LlmProviderConfig(
          baseUrl: 'http://localhost:11434',
          model: 'llama3.1:8b',
        ),
      );
      final res = await provider.generate(systemPrompt: 's', userPrompt: 'u');

      expect(seen.url.toString(), 'http://localhost:11434/api/chat');
      // No bearer / x-api-key for default Ollama install.
      expect(seen.headers['Authorization'], isNull);
      final body = jsonDecode(seen.body) as Map<String, dynamic>;
      expect(body['model'], 'llama3.1:8b');
      expect(body['stream'], false);
      expect(body['format'], 'json');
      expect(res.text, '{"ok":true}');
      expect(res.usage?.totalTokens, 142);
      provider.close();
    });
  });

  group('LlmProviderFactory', () {
    test('produces the right provider per kind', () {
      final factory = LlmProviderFactory(
        httpClientFactory: () =>
            MockClient((_) async => http.Response('', 200)),
      );
      final openAi = factory.create(
        LlmProviderKind.openAiCompatible,
        const LlmProviderConfig(baseUrl: 'x', model: 'm'),
      );
      expect(openAi, isA<OpenAiCompatibleProvider>());
      final claude = factory.create(
        LlmProviderKind.anthropic,
        const LlmProviderConfig(baseUrl: 'x', model: 'm', apiKey: 'k'),
      );
      expect(claude, isA<AnthropicProvider>());
      final ollama = factory.create(
        LlmProviderKind.ollama,
        const LlmProviderConfig(baseUrl: 'x', model: 'm'),
      );
      expect(ollama, isA<OllamaLocalProvider>());
      openAi.close();
      claude.close();
      ollama.close();
    });
  });
}
