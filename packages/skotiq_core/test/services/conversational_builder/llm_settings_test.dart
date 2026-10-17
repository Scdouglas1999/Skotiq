// LlmSettingsService secret-storage round-trip tests.
//
// Spins up an in-memory SQLite + in-memory SecureKeyValueStore so we
// can assert that secret keys go through the keyring path and never
// land in the plaintext app_settings blob.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LlmSettingsService', () {
    late SkotiqDatabase database;
    late SettingsDao dao;
    late InMemorySecureKeyValueStore secureStore;
    late SecretsStore secrets;
    late LlmSettingsService service;

    setUp(() async {
      database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      dao = SettingsDao(database);
      secureStore = InMemorySecureKeyValueStore();
      secrets = SecretsStore(secureStore);
      service = LlmSettingsService(dao, secrets);
    });

    tearDown(() async {
      service.close();
      await database.close();
    });

    test('load returns defaults when nothing persisted', () async {
      final settings = await service.load();
      expect(settings.activeKind, LlmProviderKind.openAiCompatible);
      expect(
        settings.perKind[LlmProviderKind.openAiCompatible]!.baseUrl,
        contains('openai.com'),
      );
      expect(
        settings.perKind[LlmProviderKind.ollama]!.baseUrl,
        'http://localhost:11434',
      );
    });

    test('setProviderConfig round-trips non-secret fields', () async {
      await service.setProviderConfig(
        LlmProviderKind.openAiCompatible,
        const LlmProviderConfig(
          baseUrl: 'https://openrouter.example',
          model: 'meta/llama-3.1-405b',
          maxTokens: 8192,
          temperature: 0.3,
          requestTimeout: Duration(seconds: 120),
        ),
      );
      final reloaded = await service.load();
      final cfg = reloaded.perKind[LlmProviderKind.openAiCompatible]!;
      expect(cfg.baseUrl, 'https://openrouter.example');
      expect(cfg.model, 'meta/llama-3.1-405b');
      expect(cfg.maxTokens, 8192);
      expect(cfg.temperature, closeTo(0.3, 1e-9));
      expect(cfg.requestTimeout.inSeconds, 120);
    });

    test('writeApiKey persists into SecretsStore (not app_settings)', () async {
      await service.writeApiKey(LlmProviderKind.anthropic, 'anth-secret');
      final read = await service.readApiKey(LlmProviderKind.anthropic);
      expect(read, 'anth-secret');

      // The plaintext app_settings table must NOT contain the secret.
      final all = await dao.getAllSettings();
      expect(
        all.values.any((v) => v.contains('anth-secret')),
        isFalse,
        reason: 'API key must live in SecretsStore, not app_settings.',
      );

      // The secure store must have it under the documented field key.
      expect(secureStore.values.values.any((v) => v == 'anth-secret'), isTrue);
    });

    test('setActiveKind persists and reloads', () async {
      await service.setActiveKind(LlmProviderKind.ollama);
      final reloaded = await service.load();
      expect(reloaded.activeKind, LlmProviderKind.ollama);
    });

    test('hydratedConfig splices in the stored API key', () async {
      await service.setProviderConfig(
        LlmProviderKind.openAiCompatible,
        const LlmProviderConfig(
          baseUrl: 'https://api.openai.example',
          model: 'gpt-4o',
        ),
      );
      await service.writeApiKey(LlmProviderKind.openAiCompatible, 'sk-live');
      final cfg = await service.hydratedConfig(
        LlmProviderKind.openAiCompatible,
      );
      expect(cfg.apiKey, 'sk-live');
      expect(cfg.baseUrl, 'https://api.openai.example');
    });

    test('buildActiveProvider returns null when unconfigured', () async {
      // Default Anthropic config has empty apiKey → not configured.
      await service.setActiveKind(LlmProviderKind.anthropic);
      final provider = await service.buildActiveProvider(
        factory: LlmProviderFactory(),
      );
      expect(provider, isNull);
    });
  });
}
