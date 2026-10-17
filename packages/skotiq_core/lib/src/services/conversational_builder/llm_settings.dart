// Conversational sequence builder: settings storage.
//
// Splits user-supplied LLM provider config into:
//   * Non-secret bits (provider kind, base URL, model name, max tokens,
//     temperature, timeout) stored in `app_settings` as a JSON blob.
//   * Secret bits (API keys) stored via [SecretsStore] / flutter_secure_storage.
//
// The split mirrors how the notification subsystem stores transport
// configs. The non-secret blob survives backups and
// the user's preferences-export flow; the secret never leaves the OS
// keyring.

import 'dart:async';
import 'dart:convert';

import '../../database/daos/settings_dao.dart';
import '../notification/secrets_store.dart';
import 'llm_provider.dart';

/// Stable storage keys used by [LlmSettingsService]. Kept centrally so a
/// future rename can be done in one place.
abstract class LlmSettingsKeys {
  /// `app_settings` row holding the JSON blob of the non-secret fields
  /// for the *currently active* provider.
  static const String activeProviderBlob = 'ai_assistant.active_provider';

  /// `app_settings` row holding the user's selected provider kind.
  /// Stored separately so the UI can render the selector even if the
  /// blob for that kind hasn't been written yet (fresh install).
  static const String activeProviderKind = 'ai_assistant.active_kind';

  /// Per-kind blob — the user can configure all three providers and
  /// switch between them without losing the previous endpoint / model.
  static String providerBlobFor(LlmProviderKind kind) =>
      'ai_assistant.provider.${kind.storageKey}';
}

/// Stable secret field keys for each provider kind. Added to the
/// notification subsystem's [SecretField] namespace by way of these
/// constants (we don't extend SecretField — it's an abstract class with
/// static constants — so we just keep them here and the SecretsStore
/// treats them as opaque field ids).
abstract class LlmSecretField {
  static const String openAiCompatibleApiKey = 'ai.openai_compatible.api_key';
  static const String anthropicApiKey = 'ai.anthropic.api_key';

  /// Ollama in its default config has no auth, but advanced users may
  /// front it with an nginx + bearer-token reverse proxy. We expose a
  /// secret slot so they can supply the token.
  static const String ollamaApiKey = 'ai.ollama.api_key';

  /// Returns the secret key for the given provider kind. Used by the
  /// settings provider and the dialog so the "which secret holds this
  /// key" lookup is in one place.
  static String fieldFor(LlmProviderKind kind) {
    switch (kind) {
      case LlmProviderKind.openAiCompatible:
        return openAiCompatibleApiKey;
      case LlmProviderKind.anthropic:
        return anthropicApiKey;
      case LlmProviderKind.ollama:
        return ollamaApiKey;
    }
  }
}

/// Sane default endpoints + models per provider kind. Surface as
/// pre-fill values on the settings form so a user who hits "Test
/// connection" immediately after picking a kind doesn't have to look up
/// the URL.
LlmProviderConfig defaultConfigFor(LlmProviderKind kind) {
  switch (kind) {
    case LlmProviderKind.openAiCompatible:
      // OpenAI's production endpoint. Users on OpenRouter / LM Studio
      // edit the base URL.
      return const LlmProviderConfig(
        baseUrl: 'https://api.openai.com',
        model: 'gpt-4o-mini',
      );
    case LlmProviderKind.anthropic:
      return const LlmProviderConfig(
        baseUrl: 'https://api.anthropic.com',
        model: 'claude-opus-4-5',
      );
    case LlmProviderKind.ollama:
      return const LlmProviderConfig(
        baseUrl: 'http://localhost:11434',
        model: 'llama3.1:8b',
        // Local models are slower — give them more room.
        requestTimeout: Duration(seconds: 180),
      );
  }
}

/// In-memory representation of the user's full AI Assistant
/// configuration: which provider is selected, plus the non-secret blob
/// for each kind they've configured at some point.
class LlmAssistantSettings {
  final LlmProviderKind activeKind;

  /// Per-kind configs. May be missing entries for kinds the user has
  /// never opened — `LlmSettingsService.load` fills missing entries
  /// with [defaultConfigFor] so the UI always has something to render.
  final Map<LlmProviderKind, LlmProviderConfig> perKind;

  const LlmAssistantSettings({required this.activeKind, required this.perKind});

  /// Convenience: the config for the currently selected provider,
  /// including the API key fetched from the secure store.
  LlmProviderConfig get activeConfig {
    final base = perKind[activeKind] ?? defaultConfigFor(activeKind);
    return base;
  }

  LlmAssistantSettings copyWith({
    LlmProviderKind? activeKind,
    Map<LlmProviderKind, LlmProviderConfig>? perKind,
  }) {
    return LlmAssistantSettings(
      activeKind: activeKind ?? this.activeKind,
      perKind: perKind ?? this.perKind,
    );
  }
}

/// Read/write the AI Assistant configuration. Used by the settings
/// provider (build screen) and the conversational builder dialog (read
/// before each request).
class LlmSettingsService {
  final SettingsDao _settingsDao;
  final SecretsStore _secrets;

  /// Optional broadcast stream surface — the settings provider exposes
  /// it as a Riverpod stream so the dialog's "Configured?" badge stays
  /// in sync without a manual ref.invalidate().
  final StreamController<void> _changes = StreamController<void>.broadcast();

  LlmSettingsService(this._settingsDao, this._secrets);

  Stream<void> get changes => _changes.stream;

  /// Read the full settings record. Missing fields fall through to the
  /// per-kind defaults so the settings UI always renders a complete
  /// form.
  Future<LlmAssistantSettings> load() async {
    final activeKindRaw = await _settingsDao.getSetting(
      LlmSettingsKeys.activeProviderKind,
    );
    final activeKind = LlmProviderKindLabel.fromStorageKey(activeKindRaw);
    final perKind = <LlmProviderKind, LlmProviderConfig>{};
    for (final kind in LlmProviderKind.values) {
      final blob = await _settingsDao.getSetting(
        LlmSettingsKeys.providerBlobFor(kind),
      );
      perKind[kind] = _decodeBlob(blob) ?? defaultConfigFor(kind);
    }
    return LlmAssistantSettings(activeKind: activeKind, perKind: perKind);
  }

  /// Persist the active provider kind. The active-config blob is left
  /// untouched — switching providers preserves each provider's last-
  /// known endpoint/model.
  Future<void> setActiveKind(LlmProviderKind kind) async {
    await _settingsDao.setSetting(
      LlmSettingsKeys.activeProviderKind,
      kind.storageKey,
    );
    _notify();
  }

  /// Persist the non-secret bits of a single provider config. The API
  /// key is NOT pulled from [config] — call [writeApiKey] separately
  /// for that. We deliberately keep the two paths separate so a user
  /// editing the endpoint never overwrites the stored secret.
  Future<void> setProviderConfig(
    LlmProviderKind kind,
    LlmProviderConfig config,
  ) async {
    await _settingsDao.setSetting(
      LlmSettingsKeys.providerBlobFor(kind),
      _encodeBlob(config),
    );
    _notify();
  }

  /// Write the API key for [kind] to the secure store. Empty string
  /// deletes the key (matching [SecretsStore.write] behaviour).
  Future<void> writeApiKey(LlmProviderKind kind, String key) async {
    await _secrets.write(LlmSecretField.fieldFor(kind), key);
    _notify();
  }

  /// Read the API key for [kind] from the secure store. Returns the
  /// empty string when no value is stored.
  Future<String> readApiKey(LlmProviderKind kind) async {
    return _secrets.read(LlmSecretField.fieldFor(kind));
  }

  /// Convenience: returns the [LlmProviderConfig] for [kind] with the
  /// stored API key spliced into the `apiKey` field. The factory uses
  /// this to construct a runtime provider.
  Future<LlmProviderConfig> hydratedConfig(LlmProviderKind kind) async {
    final base = (await load()).perKind[kind] ?? defaultConfigFor(kind);
    final key = await readApiKey(kind);
    return base.copyWith(apiKey: key);
  }

  /// Convenience: build a provider instance for the currently active
  /// kind. Returns null when the active provider isn't configured —
  /// the dialog uses this to gate its open path.
  Future<LlmProvider?> buildActiveProvider({
    required LlmProviderFactory factory,
  }) async {
    final settings = await load();
    final config = await hydratedConfig(settings.activeKind);
    final provider = factory.create(settings.activeKind, config);
    if (!provider.isConfigured) {
      provider.close();
      return null;
    }
    return provider;
  }

  void close() {
    if (!_changes.isClosed) _changes.close();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  String _encodeBlob(LlmProviderConfig config) {
    return jsonEncode({
      'baseUrl': config.baseUrl,
      'model': config.model,
      'anthropicVersion': config.anthropicVersion,
      'maxTokens': config.maxTokens,
      'temperature': config.temperature,
      'requestTimeoutSecs': config.requestTimeout.inSeconds,
    });
  }

  LlmProviderConfig? _decodeBlob(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return LlmProviderConfig(
        baseUrl: decoded['baseUrl'] as String? ?? '',
        model: decoded['model'] as String? ?? '',
        anthropicVersion:
            decoded['anthropicVersion'] as String? ?? '2023-06-01',
        maxTokens: (decoded['maxTokens'] as num?)?.toInt() ?? 4096,
        temperature: (decoded['temperature'] as num?)?.toDouble() ?? 0.2,
        requestTimeout: Duration(
          seconds: (decoded['requestTimeoutSecs'] as num?)?.toInt() ?? 90,
        ),
      );
    } catch (_) {
      // Bad JSON on disk — fall through to default. The UI will
      // overwrite on next save.
      return null;
    }
  }
}
