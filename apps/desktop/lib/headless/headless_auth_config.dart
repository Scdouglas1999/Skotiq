import 'dart:io';

import '../headless_api/auth_policy.dart';
import '../headless_api/handlers/pairing_handlers.dart' show PairingMode;
import 'headless_env.dart';

/// Resolved server configuration derived from CLI arguments and environment
/// variables. Immutable snapshot passed into the service bootstrap so the
/// startup path reads a single coherent set of values.
class HeadlessAuthConfig {
  final String? token;
  final bool requireAuth;

  /// Explicit opt-in to the legacy fully-open behaviour. When true, every
  /// endpoint is served without a bearer token even if configured or persisted
  /// pairing tokens exist (the server logs a prominent warning). Default false
  /// = FAIL CLOSED: an unconfigured server serves only the
  /// pairing/dashboard bootstrap surface.
  ///
  /// Distinct from [bindLocalOnly]: this governs whether requests are
  /// *authenticated*, not which interface the socket binds to.
  final bool allowUnauthenticated;
  final bool bindLocalOnly;
  final int port;
  final Map<String, HeadlessTokenScope> scopedTokens;

  /// Fine-grained tokens, each carrying a per-resource [HeadlessAuthGrant]
  /// (e.g. "control camera but not mount"). Sourced from
  /// `SKOTIQ_SCOPED_TOKEN` / repeated `--scoped-token=`.
  final Map<String, HeadlessAuthGrant> fineGrainedTokens;
  final List<String> corsAllowedOrigins;
  final bool pairingPrintCodes;
  final PairingMode pairingMode;
  final bool tlsEnabled;
  final String? tlsCertPath;
  final String? tlsKeyPath;

  HeadlessAuthConfig({
    this.token,
    this.requireAuth = false,
    this.allowUnauthenticated = false,
    this.bindLocalOnly = true,
    this.port = 8080,
    this.scopedTokens = const {},
    this.fineGrainedTokens = const {},
    this.corsAllowedOrigins = const [],
    this.pairingPrintCodes = false,
    this.pairingMode = PairingMode.lanOpen,
    this.tlsEnabled = false,
    this.tlsCertPath,
    this.tlsKeyPath,
  });
}

/// Parse the headless server configuration from CLI [args] and environment
/// variables. Environment is read first (the systemd/docker idiom) and CLI
/// flags override or extend it. See `main_headless.dart`'s doc comment for the
/// full flag/variable reference.
HeadlessAuthConfig parseHeadlessAuthConfig(List<String> args) {
  String? token;
  var requireAuth = false;
  // Serve-open escape hatch (authentication), distinct from the LAN-bind flag
  // below (network exposure). Default off => FAIL CLOSED.
  var allowUnauthenticated = envFlag('SKOTIQ_ALLOW_UNAUTHENTICATED');
  var allowUnauthenticatedLan = envFlag('SKOTIQ_ALLOW_UNAUTHENTICATED_LAN');
  var port = 8080;
  final scopedTokens = <String, HeadlessTokenScope>{};
  final fineGrainedTokens = <String, HeadlessAuthGrant>{};
  final corsAllowedOrigins = <String>[];
  var pairingPrintCodes = envFlag('SKOTIQ_PAIRING_PRINT_CODES');
  // Default to one-tap LAN pairing; operators can tighten to code-required.
  final pairingMode = PairingMode.fromWire(
    Platform.environment['SKOTIQ_PAIRING_MODE'],
  );
  var tlsEnabled = envFlag('SKOTIQ_TLS');
  String? tlsCertPath = trimToNull(Platform.environment['SKOTIQ_TLS_CERT']);
  String? tlsKeyPath = trimToNull(Platform.environment['SKOTIQ_TLS_KEY']);

  token = Platform.environment['SKOTIQ_AUTH_TOKEN'];
  _addScopedTokenFromEnv(
    scopedTokens,
    'SKOTIQ_VIEW_TOKEN',
    HeadlessTokenScope.view,
  );
  _addScopedTokenFromEnv(
    scopedTokens,
    'SKOTIQ_CONTROL_TOKEN',
    HeadlessTokenScope.control,
  );
  // Fine-grained tokens: SKOTIQ_SCOPED_TOKEN carries one or more
  // `<token>=<grant-spec>` entries separated by `;`, e.g.
  // `secretA=camera:control,mount:view;secretB=admin`.
  final envScoped = Platform.environment['SKOTIQ_SCOPED_TOKEN'];
  if (envScoped != null && envScoped.trim().isNotEmpty) {
    for (final entry in envScoped.split(';')) {
      _addFineGrainedToken(fineGrainedTokens, entry);
    }
  }
  if (Platform.environment['SKOTIQ_PORT'] != null) {
    port = int.tryParse(Platform.environment['SKOTIQ_PORT']!) ?? 8080;
  }

  // Why env-first: SKOTIQ_CORS_ORIGINS is the systemd/docker idiom; CLI
  // overrides allow operators to extend the list at launch time.
  final envCors = Platform.environment['SKOTIQ_CORS_ORIGINS'];
  if (envCors != null && envCors.trim().isNotEmpty) {
    for (final raw in envCors.split(',')) {
      final trimmed = raw.trim();
      if (trimmed.isNotEmpty) {
        corsAllowedOrigins.add(trimmed);
      }
    }
  }

  for (final arg in args) {
    if (arg.startsWith('--auth-token=')) {
      token = arg.substring('--auth-token='.length);
    } else if (arg == '--require-auth') {
      requireAuth = true;
    } else if (arg == '--allow-unauthenticated') {
      allowUnauthenticated = true;
    } else if (arg == '--allow-unauthenticated-lan') {
      allowUnauthenticatedLan = true;
    } else if (arg.startsWith('--view-token=')) {
      _addScopedToken(
        scopedTokens,
        arg.substring('--view-token='.length),
        HeadlessTokenScope.view,
      );
    } else if (arg.startsWith('--control-token=')) {
      _addScopedToken(
        scopedTokens,
        arg.substring('--control-token='.length),
        HeadlessTokenScope.control,
      );
    } else if (arg.startsWith('--scoped-token=')) {
      _addFineGrainedToken(
        fineGrainedTokens,
        arg.substring('--scoped-token='.length),
      );
    } else if (arg.startsWith('--port=')) {
      port = int.tryParse(arg.substring('--port='.length)) ?? port;
    } else if (arg.startsWith('--cors-origin=')) {
      final value = arg.substring('--cors-origin='.length).trim();
      if (value.isNotEmpty) {
        corsAllowedOrigins.add(value);
      }
    } else if (arg == '--pairing-print-codes') {
      pairingPrintCodes = true;
    } else if (arg == '--tls') {
      tlsEnabled = true;
    } else if (arg.startsWith('--tls-cert=')) {
      tlsCertPath = trimToNull(arg.substring('--tls-cert='.length));
    } else if (arg.startsWith('--tls-key=')) {
      tlsKeyPath = trimToNull(arg.substring('--tls-key='.length));
    }
  }

  if (token != null && token.trim().isEmpty) {
    token = null;
  }

  // Explicit cert/key paths imply TLS even without --tls; otherwise the
  // operator's paths would be silently ignored. Same rule for the env-var
  // equivalents — passing SKOTIQ_TLS_CERT must enable TLS.
  if (tlsCertPath != null || tlsKeyPath != null) {
    tlsEnabled = true;
  }

  final hasAuthentication =
      token != null ||
      requireAuth ||
      scopedTokens.isNotEmpty ||
      fineGrainedTokens.isNotEmpty;
  return HeadlessAuthConfig(
    token: token,
    requireAuth: requireAuth,
    allowUnauthenticated: allowUnauthenticated,
    bindLocalOnly: !hasAuthentication && !allowUnauthenticatedLan,
    port: port,
    scopedTokens: Map.unmodifiable(scopedTokens),
    fineGrainedTokens: Map.unmodifiable(fineGrainedTokens),
    corsAllowedOrigins: List.unmodifiable(corsAllowedOrigins),
    pairingPrintCodes: pairingPrintCodes,
    pairingMode: pairingMode,
    tlsEnabled: tlsEnabled,
    tlsCertPath: tlsCertPath,
    tlsKeyPath: tlsKeyPath,
  );
}

void _addScopedTokenFromEnv(
  Map<String, HeadlessTokenScope> scopedTokens,
  String envName,
  HeadlessTokenScope scope,
) {
  _addScopedToken(scopedTokens, Platform.environment[envName], scope);
}

void _addScopedToken(
  Map<String, HeadlessTokenScope> scopedTokens,
  String? token,
  HeadlessTokenScope scope,
) {
  final normalizedToken = token?.trim();
  if (normalizedToken == null || normalizedToken.isEmpty) {
    return;
  }
  scopedTokens[normalizedToken] = scope;
}

/// Parse one `<token>=<grant-spec>` entry and register it. The token is split
/// on the FIRST `=` so a grant spec containing `:` and `,` survives intact
/// (e.g. `secret=camera:control,mount:view`). Malformed entries (no `=`, empty
/// token, or an unparseable spec) are skipped silently — a fail-closed launch
/// is preferable to crashing the daemon on a typo'd env var.
void _addFineGrainedToken(
  Map<String, HeadlessAuthGrant> fineGrainedTokens,
  String entry,
) {
  final trimmed = entry.trim();
  if (trimmed.isEmpty) return;
  final eq = trimmed.indexOf('=');
  if (eq <= 0) return;
  final token = trimmed.substring(0, eq).trim();
  final spec = trimmed.substring(eq + 1).trim();
  if (token.isEmpty || spec.isEmpty) return;
  final grant = HeadlessAuthGrant.parseSpec(spec);
  if (grant == null) return;
  fineGrainedTokens[token] = grant;
}
