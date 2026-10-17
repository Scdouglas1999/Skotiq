// Conversational sequence builder: LLM provider abstraction.
//
// This file is the single source of truth for "talk to a remote LLM and get
// back a string". The conversational builder service owns the prompt + the
// JSON-validation-feedback loop; providers below only know how to *send*
// a (system, user) pair to a specific API shape and *return* the raw model
// reply.
//
// Why an abstraction:
//   * OpenAI, OpenRouter, LM Studio and Ollama (all in "OpenAI compatible
//     mode") share one wire format — `POST /v1/chat/completions` with
//     `{model, messages: [...]}`. They cover the vast majority of cloud
//     and self-hosted models the user is likely to reach for.
//   * Anthropic's `POST /v1/messages` API is just different enough to
//     warrant its own implementation (top-level `system` field, `messages`
//     without role=system, `anthropic-version` header, `x-api-key` instead
//     of `Bearer`).
//   * Ollama exposes both a native `/api/chat` endpoint *and* an
//     OpenAI-compatible facade at `/v1/chat/completions`. We provide a
//     dedicated implementation that talks to the *native* endpoint so it
//     works against Ollama installs that haven't enabled the OpenAI
//     compatibility layer, and because Ollama's native streaming is more
//     reliable than the compat shim.
//
// All providers are constructed with a `http.Client` so tests can inject a
// `MockClient` (see `test/services/conversational_builder/`). The base URL
// and model name are *always* configurable — there are no hard-coded
// endpoints.
//
// Every provider raises an [LlmProviderException] carrying the failing status
// code + response body when the upstream returns non-2xx. The conversational
// builder service surfaces it through the dialog UI, so "the model gave invalid
// JSON" and "your API key is expired" read differently.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Wire-level exception raised by all [LlmProvider] implementations when
/// the upstream returns a non-success status or the body fails to decode.
///
/// We deliberately keep this a single class rather than a sealed
/// hierarchy: the UI only needs to surface a string, and tests gain
/// nothing from `is AuthException` vs `is RateLimitException` switches.
/// The [statusCode] + [body] fields are exposed so callers (and tests)
/// can still discriminate on raw codes when they care.
class LlmProviderException implements Exception {
  /// Provider that raised this — useful when more than one is configured
  /// (Anthropic + Ollama, say) and we want the error message to identify
  /// which one failed.
  final String providerName;

  /// HTTP status from the upstream, or 0 for non-HTTP failures (DNS,
  /// socket timeout, JSON decode).
  final int statusCode;

  /// Human-readable message, intended for display in the dialog.
  final String message;

  /// Raw response body (or stringified exception) — surfaced in logs and
  /// the "show details" expansion in the dialog.
  final String body;

  const LlmProviderException({
    required this.providerName,
    required this.statusCode,
    required this.message,
    this.body = '',
  });

  @override
  String toString() =>
      'LlmProviderException($providerName, status=$statusCode): $message';
}

/// Diagnostic envelope returned by [LlmProvider.testConnection]. The
/// Settings screen "Test connection" button surfaces both the success
/// boolean and the failure-mode message.
class LlmConnectionTestResult {
  final bool success;
  final String message;

  /// Round-trip wall-clock time for the test request, in milliseconds.
  /// Surfaced so the user can see if "slow" providers (e.g. a local
  /// Ollama on CPU) are going to be too laggy for interactive use.
  final int roundTripMs;

  const LlmConnectionTestResult({
    required this.success,
    required this.message,
    required this.roundTripMs,
  });
}

/// Token-usage report. Some providers (OpenAI, Anthropic) return token
/// counts in their response; others (Ollama, LM Studio) don't. When a
/// provider has no usage info, [LlmResponse.usage] is null and the
/// "tokens consumed" line is omitted from the history entry.
class LlmUsage {
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;

  const LlmUsage({
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
  });

  Map<String, dynamic> toJson() => {
    'prompt_tokens': promptTokens,
    'completion_tokens': completionTokens,
    'total_tokens': totalTokens,
  };

  factory LlmUsage.fromJson(Map<String, dynamic> json) => LlmUsage(
    promptTokens: (json['prompt_tokens'] as num?)?.toInt() ?? 0,
    completionTokens: (json['completion_tokens'] as num?)?.toInt() ?? 0,
    totalTokens: (json['total_tokens'] as num?)?.toInt() ?? 0,
  );
}

/// Result of a single LLM round-trip. Holds the raw text the model
/// produced (no parsing — that's the conversational builder's job) and
/// optional usage info.
class LlmResponse {
  final String text;
  final LlmUsage? usage;

  const LlmResponse({required this.text, this.usage});
}

/// Provider config record — the immutable bag of "everything the user
/// supplied for this provider" that gets passed into the constructor.
/// Keeps the constructors of the three providers terse and lets the
/// settings layer save/load a single record per provider.
class LlmProviderConfig {
  /// Base URL (no trailing slash, no path). For OpenAI:
  /// `https://api.openai.com`. For LM Studio: `http://localhost:1234`.
  /// For Anthropic: `https://api.anthropic.com`. For Ollama:
  /// `http://localhost:11434`.
  final String baseUrl;

  /// Model identifier. Free-text — the upstream validates.
  final String model;

  /// API key (bearer / x-api-key). May be empty for local providers
  /// (Ollama, LM Studio without auth).
  final String apiKey;

  /// Optional version pin sent to Anthropic via `anthropic-version`.
  /// Ignored by the OpenAI-compatible and Ollama providers.
  final String anthropicVersion;

  /// Max tokens to generate. Defaults to a generous 4096 so a complex
  /// multi-target sequence fits without truncation.
  final int maxTokens;

  /// Sampling temperature. Defaults to 0.2 — sequence JSON is a
  /// structured-output task and we want the model to stick close to the
  /// schema, not be "creative".
  final double temperature;

  /// Per-request timeout. Set high enough that slow self-hosted models
  /// (a 70B on a single GPU) still complete; the dialog's spinner
  /// surfaces progress to the user.
  final Duration requestTimeout;

  const LlmProviderConfig({
    required this.baseUrl,
    required this.model,
    this.apiKey = '',
    this.anthropicVersion = '2023-06-01',
    this.maxTokens = 4096,
    this.temperature = 0.2,
    this.requestTimeout = const Duration(seconds: 90),
  });

  LlmProviderConfig copyWith({
    String? baseUrl,
    String? model,
    String? apiKey,
    String? anthropicVersion,
    int? maxTokens,
    double? temperature,
    Duration? requestTimeout,
  }) {
    return LlmProviderConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      apiKey: apiKey ?? this.apiKey,
      anthropicVersion: anthropicVersion ?? this.anthropicVersion,
      maxTokens: maxTokens ?? this.maxTokens,
      temperature: temperature ?? this.temperature,
      requestTimeout: requestTimeout ?? this.requestTimeout,
    );
  }
}

/// The single interface every concrete provider implements. Two methods:
///   * [generate] — send a (systemPrompt, userPrompt) pair, return the
///     raw model reply.
///   * [testConnection] — send a 1-token "ping" so the Settings screen
///     can confirm credentials before the user tries the dialog for
///     real.
///
/// Implementations are stateless beyond their constructor args — the
/// underlying `http.Client` is reused across calls, and the conversational
/// builder service holds a single provider instance per build.
abstract class LlmProvider {
  /// Stable display name — surfaced in the dialog header ("Building
  /// sequence with OpenAI…") and used as the provider key in the
  /// history table.
  String get name;

  /// The provider kind, which round-trips the user's choice through settings
  /// storage without coupling settings to a class hierarchy.
  LlmProviderKind get kind;

  /// True iff the provider has every credential / endpoint it needs to
  /// make a real request. The conversational builder dialog refuses to
  /// open when this is false and offers a "Configure" deep-link to the
  /// AI Assistant settings section.
  bool get isConfigured;

  /// Send a single (system, user) message pair to the upstream and
  /// return the model's raw reply. Throws [LlmProviderException] on
  /// non-2xx or decode failures — silent fallback hides bugs.
  Future<LlmResponse> generate({
    required String systemPrompt,
    required String userPrompt,
  });

  /// Cheap end-to-end smoke test. Returns a [LlmConnectionTestResult]
  /// with `success=true` on a 2xx ping or `success=false` + a human-
  /// readable error message. Never throws — the Settings UI relies on
  /// the result envelope to render the snackbar.
  Future<LlmConnectionTestResult> testConnection();

  /// Release any resources (the underlying http.Client) when the
  /// provider is discarded. Safe to call multiple times.
  void close();
}

/// Discrete tag for each provider kind we ship. New kinds get a new
/// enum value AND a new branch in `LlmProviderFactory.create`.
enum LlmProviderKind {
  /// OpenAI / OpenRouter / LM Studio / any "OpenAI compatible" API.
  openAiCompatible,

  /// Anthropic's `/v1/messages` API.
  anthropic,

  /// Ollama's native `/api/chat` (NOT the OpenAI compat shim).
  ollama,
}

/// Display label for each provider kind — used by the settings selector.
extension LlmProviderKindLabel on LlmProviderKind {
  String get label {
    switch (this) {
      case LlmProviderKind.openAiCompatible:
        return 'OpenAI-compatible (OpenAI, OpenRouter, LM Studio…)';
      case LlmProviderKind.anthropic:
        return 'Anthropic Claude';
      case LlmProviderKind.ollama:
        return 'Ollama (local)';
    }
  }

  /// Storage key — must remain stable for forwards/backwards-compat of
  /// the settings record.
  String get storageKey {
    switch (this) {
      case LlmProviderKind.openAiCompatible:
        return 'openai_compatible';
      case LlmProviderKind.anthropic:
        return 'anthropic';
      case LlmProviderKind.ollama:
        return 'ollama';
    }
  }

  static LlmProviderKind fromStorageKey(String? key) {
    switch (key) {
      case 'anthropic':
        return LlmProviderKind.anthropic;
      case 'ollama':
        return LlmProviderKind.ollama;
      case 'openai_compatible':
      default:
        return LlmProviderKind.openAiCompatible;
    }
  }
}

/// Factory that produces a concrete provider instance for the given
/// kind + config. Used by the settings provider and the dialog so the
/// "which provider class implements this kind" lookup lives in exactly
/// one place.
class LlmProviderFactory {
  /// Optional http.Client injection — production callers pass null
  /// (factory creates an unrestricted client); tests inject a
  /// MockClient.
  final http.Client Function() httpClientFactory;

  LlmProviderFactory({http.Client Function()? httpClientFactory})
    : httpClientFactory = httpClientFactory ?? (() => http.Client());

  LlmProvider create(LlmProviderKind kind, LlmProviderConfig config) {
    switch (kind) {
      case LlmProviderKind.openAiCompatible:
        return OpenAiCompatibleProvider(
          config: config,
          httpClient: httpClientFactory(),
        );
      case LlmProviderKind.anthropic:
        return AnthropicProvider(
          config: config,
          httpClient: httpClientFactory(),
        );
      case LlmProviderKind.ollama:
        return OllamaLocalProvider(
          config: config,
          httpClient: httpClientFactory(),
        );
    }
  }
}

// OpenAI-compatible (OpenAI, OpenRouter, LM Studio, anything else that
// speaks `POST /v1/chat/completions` with the standard schema).

class OpenAiCompatibleProvider implements LlmProvider {
  final LlmProviderConfig config;
  final http.Client _http;

  OpenAiCompatibleProvider({
    required this.config,
    required http.Client httpClient,
  }) : _http = httpClient;

  @override
  String get name => 'OpenAI-compatible';

  @override
  LlmProviderKind get kind => LlmProviderKind.openAiCompatible;

  /// LM Studio + many self-hosted gateways allow an empty key. The
  /// model name is the only universally-required field. Base URL gates
  /// the request entirely so we require both.
  @override
  bool get isConfigured => config.baseUrl.isNotEmpty && config.model.isNotEmpty;

  Uri get _endpoint =>
      Uri.parse(_joinUrl(config.baseUrl, '/v1/chat/completions'));

  Map<String, String> _headers() {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (config.apiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${config.apiKey}';
    }
    return headers;
  }

  @override
  Future<LlmResponse> generate({
    required String systemPrompt,
    required String userPrompt,
  }) async {
    final body = jsonEncode({
      'model': config.model,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userPrompt},
      ],
      'temperature': config.temperature,
      'max_tokens': config.maxTokens,
      // Many OpenAI-compatible servers (including OpenAI itself) support
      // a JSON-output hint. Including it is harmless on backends that
      // don't recognise the key.
      'response_format': {'type': 'json_object'},
    });

    final http.Response response;
    try {
      response = await _http
          .post(_endpoint, headers: _headers(), body: body)
          .timeout(config.requestTimeout);
    } on TimeoutException {
      throw LlmProviderException(
        providerName: name,
        statusCode: 0,
        message:
            'Request timed out after '
            '${config.requestTimeout.inSeconds}s.',
      );
    } catch (e) {
      throw LlmProviderException(
        providerName: name,
        statusCode: 0,
        message: 'Network error: $e',
        body: e.toString(),
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LlmProviderException(
        providerName: name,
        statusCode: response.statusCode,
        message: _readableError(response),
        body: response.body,
      );
    }

    final decoded = _decodeJson(response.body, providerName: name);
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      throw LlmProviderException(
        providerName: name,
        statusCode: response.statusCode,
        message: 'Response missing "choices" array.',
        body: response.body,
      );
    }
    final firstChoice = choices.first;
    if (firstChoice is! Map) {
      throw LlmProviderException(
        providerName: name,
        statusCode: response.statusCode,
        message: 'choices[0] is not a JSON object.',
        body: response.body,
      );
    }
    final message = firstChoice['message'];
    if (message is! Map || message['content'] is! String) {
      throw LlmProviderException(
        providerName: name,
        statusCode: response.statusCode,
        message: 'choices[0].message.content missing or not a string.',
        body: response.body,
      );
    }
    final text = message['content'] as String;
    return LlmResponse(text: text, usage: _parseOpenAiUsage(decoded['usage']));
  }

  @override
  Future<LlmConnectionTestResult> testConnection() async {
    final stopwatch = Stopwatch()..start();
    try {
      final resp = await generate(
        systemPrompt: 'You respond with the single character: ok',
        userPrompt: 'ping',
      );
      stopwatch.stop();
      return LlmConnectionTestResult(
        success: true,
        message:
            'Connected. Sample reply: '
            '${resp.text.length > 60 ? '${resp.text.substring(0, 60)}…' : resp.text}',
        roundTripMs: stopwatch.elapsedMilliseconds,
      );
    } on LlmProviderException catch (e) {
      stopwatch.stop();
      return LlmConnectionTestResult(
        success: false,
        message: e.message,
        roundTripMs: stopwatch.elapsedMilliseconds,
      );
    } catch (e) {
      stopwatch.stop();
      return LlmConnectionTestResult(
        success: false,
        message: 'Unexpected error: $e',
        roundTripMs: stopwatch.elapsedMilliseconds,
      );
    }
  }

  @override
  void close() => _http.close();
}

// Anthropic (`POST /v1/messages`).

class AnthropicProvider implements LlmProvider {
  final LlmProviderConfig config;
  final http.Client _http;

  AnthropicProvider({required this.config, required http.Client httpClient})
    : _http = httpClient;

  @override
  String get name => 'Anthropic Claude';

  @override
  LlmProviderKind get kind => LlmProviderKind.anthropic;

  /// Anthropic always requires an API key (no public anonymous tier).
  @override
  bool get isConfigured =>
      config.baseUrl.isNotEmpty &&
      config.model.isNotEmpty &&
      config.apiKey.isNotEmpty;

  Uri get _endpoint => Uri.parse(_joinUrl(config.baseUrl, '/v1/messages'));

  Map<String, String> _headers() {
    return <String, String>{
      'Content-Type': 'application/json',
      'x-api-key': config.apiKey,
      'anthropic-version': config.anthropicVersion,
    };
  }

  @override
  Future<LlmResponse> generate({
    required String systemPrompt,
    required String userPrompt,
  }) async {
    final body = jsonEncode({
      'model': config.model,
      // Anthropic's `system` is a top-level field, NOT in messages.
      'system': systemPrompt,
      'messages': [
        {'role': 'user', 'content': userPrompt},
      ],
      'max_tokens': config.maxTokens,
      'temperature': config.temperature,
    });

    final http.Response response;
    try {
      response = await _http
          .post(_endpoint, headers: _headers(), body: body)
          .timeout(config.requestTimeout);
    } on TimeoutException {
      throw LlmProviderException(
        providerName: name,
        statusCode: 0,
        message:
            'Request timed out after '
            '${config.requestTimeout.inSeconds}s.',
      );
    } catch (e) {
      throw LlmProviderException(
        providerName: name,
        statusCode: 0,
        message: 'Network error: $e',
        body: e.toString(),
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LlmProviderException(
        providerName: name,
        statusCode: response.statusCode,
        message: _readableError(response),
        body: response.body,
      );
    }

    final decoded = _decodeJson(response.body, providerName: name);
    final content = decoded['content'];
    if (content is! List || content.isEmpty) {
      throw LlmProviderException(
        providerName: name,
        statusCode: response.statusCode,
        message: 'Response missing "content" array.',
        body: response.body,
      );
    }
    // Concatenate text blocks — most replies are a single block but the
    // schema supports more.
    final buf = StringBuffer();
    for (final block in content) {
      if (block is Map && block['type'] == 'text' && block['text'] is String) {
        buf.write(block['text'] as String);
      }
    }
    final text = buf.toString();
    if (text.isEmpty) {
      throw LlmProviderException(
        providerName: name,
        statusCode: response.statusCode,
        message: 'Response contained no text blocks.',
        body: response.body,
      );
    }
    return LlmResponse(
      text: text,
      usage: _parseAnthropicUsage(decoded['usage']),
    );
  }

  @override
  Future<LlmConnectionTestResult> testConnection() async {
    final stopwatch = Stopwatch()..start();
    try {
      final resp = await generate(
        systemPrompt: 'You respond with the single character: ok',
        userPrompt: 'ping',
      );
      stopwatch.stop();
      return LlmConnectionTestResult(
        success: true,
        message:
            'Connected. Sample reply: '
            '${resp.text.length > 60 ? '${resp.text.substring(0, 60)}…' : resp.text}',
        roundTripMs: stopwatch.elapsedMilliseconds,
      );
    } on LlmProviderException catch (e) {
      stopwatch.stop();
      return LlmConnectionTestResult(
        success: false,
        message: e.message,
        roundTripMs: stopwatch.elapsedMilliseconds,
      );
    } catch (e) {
      stopwatch.stop();
      return LlmConnectionTestResult(
        success: false,
        message: 'Unexpected error: $e',
        roundTripMs: stopwatch.elapsedMilliseconds,
      );
    }
  }

  @override
  void close() => _http.close();
}

// Ollama (native `POST /api/chat`).
//
// Ollama returns NDJSON streaming chunks by default. We pass `stream:false`
// so we get a single JSON object back — simpler to parse and matches the
// "wait for the full reply, then validate" loop the builder service runs.

class OllamaLocalProvider implements LlmProvider {
  final LlmProviderConfig config;
  final http.Client _http;

  OllamaLocalProvider({required this.config, required http.Client httpClient})
    : _http = httpClient;

  @override
  String get name => 'Ollama';

  @override
  LlmProviderKind get kind => LlmProviderKind.ollama;

  /// Ollama has no auth in the default config. Only base URL + model
  /// are required.
  @override
  bool get isConfigured => config.baseUrl.isNotEmpty && config.model.isNotEmpty;

  Uri get _endpoint => Uri.parse(_joinUrl(config.baseUrl, '/api/chat'));

  @override
  Future<LlmResponse> generate({
    required String systemPrompt,
    required String userPrompt,
  }) async {
    final body = jsonEncode({
      'model': config.model,
      'stream': false,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userPrompt},
      ],
      'options': {
        'temperature': config.temperature,
        'num_predict': config.maxTokens,
      },
      // Ollama 0.1.30+ supports `format: 'json'` to force JSON output.
      'format': 'json',
    });

    final http.Response response;
    try {
      response = await _http
          .post(
            _endpoint,
            headers: {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(config.requestTimeout);
    } on TimeoutException {
      throw LlmProviderException(
        providerName: name,
        statusCode: 0,
        message:
            'Request timed out after '
            '${config.requestTimeout.inSeconds}s.',
      );
    } catch (e) {
      throw LlmProviderException(
        providerName: name,
        statusCode: 0,
        message: 'Network error: $e',
        body: e.toString(),
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LlmProviderException(
        providerName: name,
        statusCode: response.statusCode,
        message: _readableError(response),
        body: response.body,
      );
    }

    final decoded = _decodeJson(response.body, providerName: name);
    final message = decoded['message'];
    if (message is! Map || message['content'] is! String) {
      throw LlmProviderException(
        providerName: name,
        statusCode: response.statusCode,
        message: 'Response missing message.content string.',
        body: response.body,
      );
    }
    return LlmResponse(
      text: message['content'] as String,
      usage: _parseOllamaUsage(decoded),
    );
  }

  @override
  Future<LlmConnectionTestResult> testConnection() async {
    final stopwatch = Stopwatch()..start();
    try {
      final resp = await generate(
        systemPrompt: 'You respond with the single character: ok',
        userPrompt: 'ping',
      );
      stopwatch.stop();
      return LlmConnectionTestResult(
        success: true,
        message:
            'Connected to Ollama. Sample reply: '
            '${resp.text.length > 60 ? '${resp.text.substring(0, 60)}…' : resp.text}',
        roundTripMs: stopwatch.elapsedMilliseconds,
      );
    } on LlmProviderException catch (e) {
      stopwatch.stop();
      return LlmConnectionTestResult(
        success: false,
        message: e.message,
        roundTripMs: stopwatch.elapsedMilliseconds,
      );
    } catch (e) {
      stopwatch.stop();
      return LlmConnectionTestResult(
        success: false,
        message: 'Unexpected error: $e',
        roundTripMs: stopwatch.elapsedMilliseconds,
      );
    }
  }

  @override
  void close() => _http.close();
}

// Internal helpers

String _joinUrl(String baseUrl, String path) {
  final trimmedBase = baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;
  final trimmedPath = path.startsWith('/') ? path : '/$path';
  return '$trimmedBase$trimmedPath';
}

Map<String, dynamic> _decodeJson(String body, {required String providerName}) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException(
        'Top-level response was ${decoded.runtimeType}, not a JSON object.',
      );
    }
    return decoded;
  } catch (e) {
    throw LlmProviderException(
      providerName: providerName,
      statusCode: 0,
      message: 'Failed to decode JSON response: $e',
      body: body,
    );
  }
}

/// Map an HTTP error into a single-line human-readable message. Some
/// providers (OpenAI, Anthropic) return rich `{error: {message: "..."}}`
/// envelopes; we fish those out so the user sees "Invalid API key"
/// rather than "Got 401".
String _readableError(http.Response response) {
  try {
    final decoded = jsonDecode(response.body);
    if (decoded is Map) {
      final err = decoded['error'];
      if (err is Map && err['message'] is String) {
        return '${response.statusCode}: ${err['message']}';
      }
      if (err is String) return '${response.statusCode}: $err';
    }
  } catch (_) {
    // Body wasn't JSON — fall through to the generic message below.
  }
  // Truncate ridiculous HTML error pages so the snackbar stays readable.
  final body = response.body.length > 200
      ? '${response.body.substring(0, 200)}…'
      : response.body;
  return '${response.statusCode}: $body';
}

LlmUsage? _parseOpenAiUsage(dynamic raw) {
  if (raw is! Map) return null;
  return LlmUsage(
    promptTokens: (raw['prompt_tokens'] as num?)?.toInt() ?? 0,
    completionTokens: (raw['completion_tokens'] as num?)?.toInt() ?? 0,
    totalTokens: (raw['total_tokens'] as num?)?.toInt() ?? 0,
  );
}

LlmUsage? _parseAnthropicUsage(dynamic raw) {
  if (raw is! Map) return null;
  final input = (raw['input_tokens'] as num?)?.toInt() ?? 0;
  final output = (raw['output_tokens'] as num?)?.toInt() ?? 0;
  return LlmUsage(
    promptTokens: input,
    completionTokens: output,
    totalTokens: input + output,
  );
}

LlmUsage? _parseOllamaUsage(Map<String, dynamic> raw) {
  // Ollama reports `prompt_eval_count` + `eval_count` on completion.
  final prompt = (raw['prompt_eval_count'] as num?)?.toInt();
  final eval = (raw['eval_count'] as num?)?.toInt();
  if (prompt == null && eval == null) return null;
  return LlmUsage(
    promptTokens: prompt ?? 0,
    completionTokens: eval ?? 0,
    totalTokens: (prompt ?? 0) + (eval ?? 0),
  );
}
