import 'dart:io';

import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart'
    show kDefaultHeadlessPort;

import '../headless_api/auth_policy.dart';
import '../launch_arguments.dart' show LaunchOption;
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
    this.port = kDefaultHeadlessPort,
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
  var allowUnauthenticated = envFlag(LaunchOption.allowUnauthenticated.env!);
  var allowUnauthenticatedLan = envFlag(
    LaunchOption.allowUnauthenticatedLan.env!,
  );
  var port = kDefaultHeadlessPort;
  final scopedTokens = <String, HeadlessTokenScope>{};
  final fineGrainedTokens = <String, HeadlessAuthGrant>{};
  final corsAllowedOrigins = <String>[];
  var pairingPrintCodes = envFlag(LaunchOption.pairingPrintCodes.env!);
  // Default to one-tap LAN pairing; operators can tighten to code-required.
  final pairingMode = PairingMode.fromWire(
    Platform.environment['SKOTIQ_PAIRING_MODE'],
  );
  var tlsEnabled = envFlag(LaunchOption.tls.env!);
  String? tlsCertPath = trimToNull(
    Platform.environment[LaunchOption.tlsCert.env!],
  );
  String? tlsKeyPath = trimToNull(
    Platform.environment[LaunchOption.tlsKey.env!],
  );

  token = Platform.environment[LaunchOption.authToken.env!];
  _addScopedTokenFromEnv(
    scopedTokens,
    LaunchOption.viewToken.env!,
    HeadlessTokenScope.view,
  );
  _addScopedTokenFromEnv(
    scopedTokens,
    LaunchOption.controlToken.env!,
    HeadlessTokenScope.control,
  );
  // Fine-grained tokens: SKOTIQ_SCOPED_TOKEN carries one or more
  // `<token>=<grant-spec>` entries separated by `;`, e.g.
  // `secretA=camera:control,mount:view;secretB=admin`.
  final envScoped = Platform.environment[LaunchOption.scopedToken.env!];
  if (envScoped != null && envScoped.trim().isNotEmpty) {
    for (final entry in envScoped.split(';')) {
      _addFineGrainedToken(fineGrainedTokens, entry);
    }
  }
  if (Platform.environment[LaunchOption.port.env!] != null) {
    port =
        int.tryParse(Platform.environment[LaunchOption.port.env!]!) ??
        kDefaultHeadlessPort;
  }

  // Why env-first: SKOTIQ_CORS_ORIGINS is the systemd/docker idiom; CLI
  // overrides allow operators to extend the list at launch time.
  final envCors = Platform.environment[LaunchOption.corsOrigin.env!];
  if (envCors != null && envCors.trim().isNotEmpty) {
    for (final raw in envCors.split(',')) {
      final trimmed = raw.trim();
      if (trimmed.isNotEmpty) {
        corsAllowedOrigins.add(trimmed);
      }
    }
  }

  for (final arg in args) {
    final parsed = LaunchOption.read(arg);
    if (parsed == null) continue;
    final value = parsed.value;
    switch (parsed.option) {
      case LaunchOption.authToken:
        token = value;
      case LaunchOption.requireAuth:
        requireAuth = true;
      case LaunchOption.allowUnauthenticated:
        allowUnauthenticated = true;
      case LaunchOption.allowUnauthenticatedLan:
        allowUnauthenticatedLan = true;
      case LaunchOption.viewToken:
        _addScopedToken(scopedTokens, value!, HeadlessTokenScope.view);
      case LaunchOption.controlToken:
        _addScopedToken(scopedTokens, value!, HeadlessTokenScope.control);
      case LaunchOption.scopedToken:
        _addFineGrainedToken(fineGrainedTokens, value!);
      case LaunchOption.port:
        port = int.tryParse(value!) ?? port;
      case LaunchOption.corsOrigin:
        final origin = value!.trim();
        if (origin.isNotEmpty) {
          corsAllowedOrigins.add(origin);
        }
      case LaunchOption.pairingPrintCodes:
        pairingPrintCodes = true;
      case LaunchOption.tls:
        tlsEnabled = true;
      case LaunchOption.tlsCert:
        tlsCertPath = trimToNull(value);
      case LaunchOption.tlsKey:
        tlsKeyPath = trimToNull(value);
      default:
        break;
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
