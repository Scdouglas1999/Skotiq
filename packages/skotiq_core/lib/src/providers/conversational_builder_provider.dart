// Conversational sequence builder: Riverpod surface.
//
// Exposes:
//   * [llmSettingsServiceProvider] — singleton wrapper around the
//     SettingsDao + SecretsStore for AI provider config.
//   * [llmProviderFactoryProvider]   — factory that materialises a
//     concrete LlmProvider given a kind + config.
//   * [llmAssistantSettingsProvider] — async snapshot of the user's
//     configuration; watched by the Settings screen and the dialog.
//   * [conversationalHistoryServiceProvider] — singleton history table.
//   * [conversationalHistoryProvider] — stream of recent entries for
//     the Sequencer history tab.
//
// The actual ConversationalBuilderService is NOT exposed as a
// long-lived provider because every build constructs a fresh provider
// instance (with its own http.Client) and tears it down on dispose.
// The dialog calls `ref.read(...)` for the factory + settings, then
// owns the builder lifecycle directly.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/conversational_builder/conversational_history_service.dart';
import '../services/conversational_builder/llm_provider.dart';
import '../services/conversational_builder/llm_settings.dart';
import 'database_provider.dart';
import 'notification_router_provider.dart' show secretsStoreProvider;

/// Settings facade: read/write provider configs + API keys. Held as a
/// singleton because it owns a broadcast controller.
final llmSettingsServiceProvider = Provider<LlmSettingsService>((ref) {
  final dao = ref.watch(settingsDaoProvider);
  final secrets = ref.watch(secretsStoreProvider);
  final service = LlmSettingsService(dao, secrets);
  ref.onDispose(service.close);
  return service;
});

/// Factory that builds a concrete provider instance. Production callers
/// get an unbounded http.Client; tests override this provider to
/// inject a MockClient.
final llmProviderFactoryProvider = Provider<LlmProviderFactory>((ref) {
  return LlmProviderFactory();
});

/// Async snapshot of the user's AI Assistant configuration. The settings
/// service has a `changes` stream; we surface it through this stream
/// provider so the Settings UI and the dialog stay in sync without
/// manual invalidation.
final llmAssistantSettingsProvider = StreamProvider<LlmAssistantSettings>((
  ref,
) async* {
  final service = ref.watch(llmSettingsServiceProvider);
  yield await service.load();
  await for (final _ in service.changes) {
    yield await service.load();
  }
});

/// History service singleton.
final conversationalHistoryServiceProvider =
    Provider<ConversationalHistoryService>((ref) {
      final database = ref.watch(databaseProvider);
      final service = ConversationalHistoryService(database);
      ref.onDispose(service.dispose);
      return service;
    });

/// Live history list for the Sequencer history tab.
final conversationalHistoryProvider =
    StreamProvider<List<ConversationalHistoryEntry>>((ref) {
      final service = ref.watch(conversationalHistoryServiceProvider);
      return service.watch();
    });
