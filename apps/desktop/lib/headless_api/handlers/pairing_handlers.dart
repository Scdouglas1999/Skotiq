/// HTTP handlers for the headless API's first-run pairing flow.
///
/// The host generates a pairing code; the dashboard or mobile companion user
/// retypes it into the Pair sheet, and the server mints a long-lived bearer
/// token in exchange. The code itself is NEVER returned in any HTTP response
/// body, and is NEVER written to the [LoggingService] — those entries are
/// served to authenticated clients over `/api/logs/recent` and
/// `/api/logs/tail`, so logging the code would publish it to the network.
///
/// The code reaches the operator through host-local channels only:
///   * an owner-only (0600) `pairing-code.txt` in the app-support directory,
///     written on every start — this is what makes code pairing usable on an
///     unattended headless appliance with no GUI;
///   * stdout, when the operator opted in with `--pairing-print-codes`.
///
/// Endpoints owned by this class:
///   * `POST /api/pairing/start` — begin a fresh pairing attempt. The code is
///     written to the operator's `pairing-code.txt` + (optionally) printed to
///     stdout when [pairingPrintCodes] is true.
///   * `POST /api/pairing/verify` — exchange a typed code for a session
///     token. Successful verify mints a `control`-scoped token when the
///     client names no scope; a named `requestedScope` is minted as asked,
///     so `view` yields read-only and `admin` stays opt-in.
///   * `GET /api/pairing/active` — admin-only diagnostic listing of
///     unused, unexpired pairing codes (so a headless operator on a
///     paired admin client can retrieve a code without watching
///     stdout).
///
/// All three endpoints are gated by [PairingAttemptTracker] so a brute-
/// force on the verify endpoint locks the offending client out for the
/// configured backoff window.
library;

import 'dart:io';

import 'package:skotiq_core/skotiq_core.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

import '../auth/pairing_attempt_tracker.dart';
import '../auth/pairing_service.dart';
import '../auth_policy.dart';
import '../request_context.dart';
import '../response_helpers.dart';
import '../validation.dart';

/// How a brand-new device is allowed to pair.
///
/// [lanOpen] (the default) lets a device on the same private LAN pair with one
/// tap and no code — being on the rig's own network is the trust boundary, the
/// same model as Chromecast/Sonos/ASIAIR. Remote (tailnet/relay/public) clients
/// always fall back to the code flow regardless of mode. [codeRequired] tightens
/// even LAN pairing to require the code (surfaced via the browser `/pair` page).
enum PairingMode {
  lanOpen('lan-open'),
  codeRequired('code-required');

  const PairingMode(this.wire);

  /// Stable wire/string form used in config + `/api/info`.
  final String wire;

  static PairingMode fromWire(String? value) => switch (value?.trim()) {
    'code-required' || 'codeRequired' || 'code' => PairingMode.codeRequired,
    _ => PairingMode.lanOpen,
  };
}

/// Returns the real TCP source [InternetAddress] when it is a non-loopback
/// private LAN address (RFC1918 / link-local), else null.
///
/// Trust is decided from the socket address shelf_io records
/// (`shelf.io.connection_info`), NEVER from client-supplied headers like
/// `x-forwarded-for` (those are trivially spoofable). Loopback is deliberately
/// rejected: a self-hosted relay tunnels remote clients in over loopback, so
/// treating loopback as "local" would let a remote relay client one-tap pair.
/// Tailnet CGNAT (100.64.0.0/10, fd7a:115c::/32) is rejected too — remote
/// access keeps using the code flow.
InternetAddress? lanTrustedSourceAddress(Request request) {
  final info = request.context['shelf.io.connection_info'];
  if (info is! HttpConnectionInfo) return null;
  final addr = info.remoteAddress;
  return isPrivateLanAddress(addr) ? addr : null;
}

/// True for non-loopback RFC1918 / link-local / ULA addresses, excluding the
/// Tailscale CGNAT ranges. See [lanTrustedSourceAddress] for the rationale.
bool isPrivateLanAddress(InternetAddress addr) {
  if (addr.isLoopback) return false;
  final bytes = addr.rawAddress;
  if (addr.type == InternetAddressType.IPv4 && bytes.length == 4) {
    final a = bytes[0], b = bytes[1];
    if (a == 10) return true; // 10.0.0.0/8
    if (a == 172 && b >= 16 && b <= 31) return true; // 172.16.0.0/12
    if (a == 192 && b == 168) return true; // 192.168.0.0/16
    if (a == 169 && b == 254) return true; // 169.254.0.0/16 link-local
    // 100.64.0.0/10 (CGNAT/Tailscale) and all public ranges → not LAN-trusted.
    return false;
  }
  if (addr.type == InternetAddressType.IPv6 && bytes.length == 16) {
    // Tailscale ULA fd7a:115c::/32 sits inside fc00::/7 — exclude it first.
    if (bytes[0] == 0xfd &&
        bytes[1] == 0x7a &&
        bytes[2] == 0x11 &&
        bytes[3] == 0x5c) {
      return false;
    }
    if ((bytes[0] & 0xfe) == 0xfc) return true; // fc00::/7 unique-local
    if (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) {
      return true; // fe80::/10 link-local
    }
    return false;
  }
  return false;
}

/// Returns the real TCP peer [InternetAddress] recorded by shelf_io
/// (`shelf.io.connection_info`), or null when the request did not arrive
/// over a real socket (e.g. an in-process [Request] in a unit test).
///
/// Unlike [lanTrustedSourceAddress] this does NOT filter by address class:
/// loopback and public peers are returned verbatim. It is the spoof-proof
/// anchor for the rate-limit / brute-force-lockout key, which must never be
/// derivable from client-supplied headers like `x-forwarded-for`.
InternetAddress? socketPeerAddress(Request request) {
  final info = request.context['shelf.io.connection_info'];
  if (info is! HttpConnectionInfo) return null;
  return info.remoteAddress;
}

/// Computes the rate-limit / brute-force-lockout client key for [request].
///
/// By DEFAULT (the documented direct-bind `0.0.0.0:8080` deployment with no
/// reverse proxy) the key is the real TCP socket peer address. The
/// `x-forwarded-for` / `x-real-ip` headers are attacker-controlled in that
/// topology, so honouring them would let a client rotate the header to dodge
/// both the pairing lockout ([PairingAttemptTracker]) and the bearer-token
/// failure limiter ([TokenResolver]).
///
/// [trustForwardedHeaders] is set ONLY when the operator has explicitly
/// configured the appliance to sit behind the documented local reverse proxy
/// (loopback nginx that injects the forwarding headers). Even then the headers
/// are believed only when the socket peer is loopback, so a direct LAN/WAN
/// client can never forge the key.
///
/// Falls back to the requested host when no socket connection info is present
/// (in-process requests); forwarded headers are never trusted on that path.
String headlessRateLimitClientKey(
  Request request, {
  required bool trustForwardedHeaders,
}) {
  final peer = socketPeerAddress(request);
  if (trustForwardedHeaders && peer != null && peer.isLoopback) {
    final forwardedFor = request.headers['x-forwarded-for'];
    if (forwardedFor != null && forwardedFor.trim().isNotEmpty) {
      return forwardedFor.split(',').first.trim();
    }
    final realIp = request.headers['x-real-ip'];
    if (realIp != null && realIp.trim().isNotEmpty) {
      return realIp.trim();
    }
  }
  if (peer != null) {
    return peer.address;
  }
  return request.requestedUri.host;
}

/// Function the handler calls when a successful verify mints a fresh
/// session token. The server-side implementation appends the token +
/// grant to its in-memory `_pairedSessionTokens` map so subsequent
/// authenticated requests resolve immediately.
typedef RecordPairedSession =
    void Function(String sessionToken, HeadlessAuthGrant grant);

/// Function the handler calls to look up the [PairingService], lazily
/// constructing one on first use. The server's implementation also
/// (re-)installs the revocation listener whenever a fresh service is
/// minted so revoke/expiry events propagate to the in-memory map
/// regardless of whether the service was injected at boot or lazily
/// created here.
typedef EnsurePairingService = PairingService Function();

/// Function the handler calls to compute a stable rate-limit / lockout key
/// for the request. The server implementation derives it from the real TCP
/// socket peer via [headlessRateLimitClientKey] so a spoofed forwarding
/// header cannot reset the per-client pairing lockout.
typedef RateLimitClientKey = String Function(Request request);

/// Clears the BEARER-TOKEN failure bucket ([TokenResolver]) for a client key.
///
/// Distinct from [PairingAttemptTracker], which counts failed *pairing*
/// attempts. The two limiters are independent, and only clearing the pairing
/// one left a freshly-paired operator locked out: see the call sites.
typedef ClearAuthFailures = void Function(String clientKey);

/// HTTP handlers for the pairing endpoints. Constructed once per
/// server; the lifecycle callbacks make the dependency on the server's
/// private state explicit so the handler stays decoupled from the
/// HeadlessApiServer class.
/// Basename of the operator-readable file that carries the current pairing
/// code on a headless appliance.
const String kPairingCodeFileName = 'pairing-code.txt';

class PairingHandlers {
  final PairingAttemptTracker pairingAttempts;
  final EnsurePairingService ensurePairingService;
  final RecordPairedSession recordPairedSession;
  final RateLimitClientKey rateLimitClientKey;

  /// Invoked on a SUCCESSFUL pairing so the client's bearer-token failure
  /// bucket is reset. The auth middleware checks that bucket BEFORE resolving
  /// the token — the resolve is an O(N*L) constant-time scan, so letting
  /// unauthenticated callers drive it is a CPU-burn vector — which makes its
  /// own clear-on-success unreachable while the client is limited. Without an
  /// explicit clear here, a client that tripped the limiter with a stale token
  /// stays locked out while holding a brand-new valid one.
  final ClearAuthFailures clearAuthFailures;
  final bool pairingPrintCodes;

  /// Directory that receives [kPairingCodeFileName]. Defaults to the parent of
  /// the [LoggingService] log directory (the app-support root), which is where
  /// a headless operator already goes looking. Injectable so tests can point
  /// it at a temp dir.
  final String? operatorCodeDirectory;

  /// Resolves the active pairing policy at request time (operators can change
  /// it without restarting in future; today it's fixed at boot).
  final PairingMode Function() pairingMode;
  final LoggingService logger;

  PairingHandlers({
    required this.pairingAttempts,
    required this.ensurePairingService,
    required this.recordPairedSession,
    required this.rateLimitClientKey,
    required this.clearAuthFailures,
    required this.pairingPrintCodes,
    required this.pairingMode,
    required this.logger,
    this.operatorCodeDirectory,
  });

  void _logInfo(String message) =>
      logger.info(message, source: 'PairingHandlers');
  void _logWarning(String message) =>
      logger.warning(message, source: 'PairingHandlers');
  void _logError(String message) =>
      logger.error(message, source: 'PairingHandlers');

  /// Resolve the directory the pairing-code file lives in, or `null` when no
  /// location can be determined (logging never initialised).
  String? get _resolvedCodeDirectory {
    final injected = operatorCodeDirectory;
    if (injected != null && injected.isNotEmpty) return injected;
    final logDir = logger.logDirectory;
    if (logDir == null || logDir.isEmpty) return null;
    // `<appSupport>/logs` -> `<appSupport>`.
    return p.dirname(logDir);
  }

  /// Absolute path of the operator's pairing-code file, or `null`.
  String? get pairingCodeFilePath {
    final dir = _resolvedCodeDirectory;
    if (dir == null) return null;
    return p.join(dir, kPairingCodeFileName);
  }

  /// Write [code] where a headless operator can actually read it.
  ///
  /// Deliberately NOT the structured log. `LoggingService.log()` does not
  /// write the on-disk `skotiq.log.<date>` file at all — that file carries
  /// only the native Rust tracing output — it appends to an in-memory ring
  /// buffer that is served over HTTP by `/api/logs/recent` and `/api/logs/tail`.
  /// Logging the code would therefore do the exact inverse of what this
  /// endpoint intends: the code would never reach the operator's disk, while
  /// any already authenticated client could harvest it over the network.
  ///
  /// The file is written 0600 and lives outside the logs directory, so it is
  /// not enumerable or downloadable through `/api/logs/files/...` (those routes
  /// only ever serve `skotiq.log*`).
  Future<String?> _writeOperatorPairingCode(
    String code,
    DateTime expiresAt,
  ) async {
    final path = pairingCodeFilePath;
    if (path == null) {
      _logWarning(
        'No app-support directory resolved; the pairing code could not be '
        'written for the operator. Start the host with '
        '--pairing-print-codes to read it from stdout.',
      );
      return null;
    }
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        'code=$code\n'
        'expires=${expiresAt.toUtc().toIso8601String()}\n',
        flush: true,
      );
      // Owner-only: anyone who can read this file can pair with the rig.
      if (!Platform.isWindows) {
        final chmod = await Process.run('chmod', ['600', path]);
        if (chmod.exitCode != 0) {
          _logWarning(
            'Could not restrict permissions on the pairing-code file at '
            '$path (chmod exit ${chmod.exitCode}).',
          );
        }
      }
      return path;
    } catch (e) {
      _logError('Failed to write the pairing-code file at $path: $e');
      return null;
    }
  }

  /// Remove the operator's pairing-code file once the code can no longer be
  /// used, so a spent secret does not linger on disk.
  Future<void> _clearOperatorPairingCode() async {
    final path = pairingCodeFilePath;
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (e) {
      _logWarning('Failed to clear the pairing-code file at $path: $e');
    }
  }

  /// `POST /api/pairing/start` — begin a fresh pairing attempt.
  ///
  /// Rate-limited by [PairingAttemptTracker] keyed on the client's IP
  /// (or the supplied forwarded-for header). On success the response
  /// body intentionally omits the code itself — only the
  /// `expiresAt` / `expiresInSeconds` envelope is returned; the code goes to
  /// the host-local, owner-only [kPairingCodeFileName] and, when
  /// [pairingPrintCodes] is true, to stdout. It is never logged, because the
  /// log is remotely readable.
  Future<Response> handlePairingStart(Request request) async {
    final requestId = requestIdFrom(request);
    final clientKey = rateLimitClientKey(request);

    final lockedFor = pairingAttempts.retryAfter(clientKey);
    if (lockedFor != null) {
      _logWarning(
        '[PAIR][$requestId] start rate-limited from $clientKey '
        'retry=${lockedFor.inSeconds}s',
      );
      return jsonRateLimited(
        {
          'error': 'Pairing attempts temporarily locked',
          'retryAfterSeconds': lockedFor.inSeconds < 1
              ? 1
              : lockedFor.inSeconds,
          'requestId': requestId,
        },
        headers: {
          requestIdHeader: requestId,
          'retry-after': (lockedFor.inSeconds < 1 ? 1 : lockedFor.inSeconds)
              .toString(),
        },
      );
    }

    final service = ensurePairingService();
    final result = await service.startPairing();

    // Put the code where the operator can read it: an owner-only file on the
    // host's own disk. The HTTP response deliberately omits the code, and the
    // structured log MUST NOT carry it either — `LoggingService` entries are
    // served over the network by /api/logs/recent and /api/logs/tail, so a log
    // line containing the code would hand it to exactly the remote caller this
    // endpoint is trying to keep it away from.
    final codePath = await _writeOperatorPairingCode(
      result.code,
      result.expiresAt,
    );

    // The log records that pairing started and WHERE to read the code — never
    // the code itself. The dashboard polls for success on /api/pairing/verify
    // with the user-typed code.
    _logInfo(
      '[PAIR][$requestId] Pairing started; the code is valid for '
      '${service.codeLifetime.inMinutes} minutes and was written to '
      '${codePath ?? '(no operator-readable location available)'}',
    );

    // When the headless operator passed --pairing-print-codes (or set
    // SKOTIQ_PAIRING_PRINT_CODES=true), ALSO echo the code to stdout as a
    // convenience for an attended console/journalctl session. This stays
    // opt-in so accidental stdout capture in a CI/recording context does not
    // leak the code; the always-written 0600 file above is what makes code
    // pairing usable on an unattended appliance.
    if (pairingPrintCodes) {
      // ignore: avoid_print
      print(
        '[PAIRING] code=${result.code} '
        'expires=${result.expiresAt.toUtc().toIso8601String()}',
      );
    }
    return jsonOk(
      {
        'expiresAt': result.expiresAt.toUtc().toIso8601String(),
        'expiresInSeconds': result.expiresAt
            .difference(DateTime.now())
            .inSeconds,
        // WHERE the code went, so a client can name a next step that exists on
        // the rig it is talking to. The run-watch pairing wall used to send a
        // headless operator to the desktop app's Remote Access screen, which on
        // an appliance is not there, while the code sat in the file below.
        //
        // The code itself, and the absolute path it lives at, stay off this
        // wire: `/api/pairing/start` is unauthenticated, so the answer names
        // the delivery channels and nothing an unauthenticated caller could use
        // to read the secret or to learn the host's directory layout.
        'codeDelivery': {
          'operatorFile': codePath != null,
          'operatorFileName': kPairingCodeFileName,
          'console': pairingPrintCodes,
        },
      },
      headers: {requestIdHeader: requestId},
    );
  }

  /// `POST /api/pairing/lan-claim` — one-tap pairing for a device on the local
  /// network. No code required: see [lanTrustedSourceAddress] for the trust
  /// model. Accepted only when the pairing mode is [PairingMode.lanOpen] AND the
  /// TCP source is a non-loopback private LAN address. Always mints a
  /// `control`-scoped token (admin needs the explicit code flow). Rate-limited
  /// like the code endpoints.
  ///
  /// Body (all optional): `{deviceId?, deviceName?, deviceType?}`.
  Future<Response> handleLanClaim(Request request) async {
    final requestId = requestIdFrom(request);
    final clientKey = rateLimitClientKey(request);

    final lockedFor = pairingAttempts.retryAfter(clientKey);
    if (lockedFor != null) {
      final retryAfter = lockedFor.inSeconds < 1 ? 1 : lockedFor.inSeconds;
      return jsonRateLimited(
        {
          'error': 'Pairing attempts temporarily locked',
          'retryAfterSeconds': retryAfter,
          'requestId': requestId,
        },
        headers: {
          requestIdHeader: requestId,
          'retry-after': retryAfter.toString(),
        },
      );
    }

    if (pairingMode() != PairingMode.lanOpen) {
      return jsonForbidden(
        {
          'error': 'lan_pairing_disabled',
          'message':
              'One-tap LAN pairing is disabled on this appliance. Pair with a '
              'code instead.',
          'pairingMode': pairingMode().wire,
          'requestId': requestId,
        },
        headers: {requestIdHeader: requestId},
      );
    }

    final source = lanTrustedSourceAddress(request);
    if (source == null) {
      _logWarning(
        '[PAIR][$requestId] lan-claim refused: source $clientKey is not a '
        'trusted private-LAN address',
      );
      return jsonForbidden(
        {
          'error': 'not_local_network',
          'message':
              'One-tap pairing is only available from the local network. For '
              'remote access, pair with a code.',
          'requestId': requestId,
        },
        headers: {requestIdHeader: requestId},
      );
    }

    final payload = await _readJsonBodyTolerant(request);
    final deviceId =
        optionalString(payload, 'deviceId', maxLength: 128) ??
        'lan:${source.address.replaceAll(':', '_')}';
    final deviceName =
        optionalString(payload, 'deviceName', maxLength: 128) ?? 'LAN device';
    final deviceType =
        optionalString(payload, 'deviceType', maxLength: 32) ?? 'mobile';

    // Mint through the exact tested code path: generate a code server-side and
    // consume it immediately. The code is never transmitted, so this reuses all
    // the verify-path persistence/expiry behaviour without a parallel mint.
    final service = ensurePairingService();
    final start = await service.startPairing();
    final verify = await service.verifyPairing(
      code: start.code,
      deviceId: deviceId,
      deviceName: deviceName,
      deviceType: deviceType,
      authGrantSpec: 'control',
    );
    if (verify.outcome != PairingVerifyOutcome.success ||
        verify.sessionToken == null) {
      _logError(
        '[PAIR][$requestId] lan-claim internal mint failed: ${verify.outcome}',
      );
      return jsonInternalServerError(
        {
          'error': 'lan_claim_failed',
          'message': 'Could not complete LAN pairing.',
          'requestId': requestId,
        },
        headers: {requestIdHeader: requestId},
      );
    }

    final token = verify.sessionToken!;
    recordPairedSession(
      token,
      HeadlessAuthGrant.fromCoarse(HeadlessTokenScope.control),
    );
    pairingAttempts.clear(clientKey);
    clearAuthFailures(clientKey);
    _logInfo(
      '[PAIR][$requestId] LAN one-tap pairing granted to device=$deviceId '
      'from ${source.address}',
    );
    return jsonOk(
      {
        'token': token,
        'tokenScope': headlessTokenScopeName(HeadlessTokenScope.control),
        'expiresAt': verify.expiresAt!.toUtc().toIso8601String(),
        'pairing': 'lan',
      },
      headers: {requestIdHeader: requestId},
    );
  }

  /// Reads a JSON object body, tolerating an empty/absent body (every field on
  /// lan-claim is optional, so a bodyless POST must not 400).
  Future<Map<String, dynamic>> _readJsonBodyTolerant(Request request) async {
    try {
      return await readJsonObject(request);
    } on BadRequestError {
      return <String, dynamic>{};
    }
  }

  /// `GET /api/pairing/active` — admin-only diagnostic listing of
  /// currently-valid pairing sessions. Behind the auth middleware (the
  /// path is NOT in `publicPaths`) and gated to admin scope via
  /// `_adminOnlyPaths`; the handler itself does not need a secondary
  /// scope check.
  ///
  /// Returns `{ sessions: [{code, expiresAt, expiresInSeconds}, ...] }`.
  Future<Response> handlePairingActiveList(Request request) async {
    final requestId = requestIdFrom(request);
    try {
      final service = ensurePairingService();
      // Query the underlying Drift DB directly — TokenManager has no need to
      // expose unused pairing sessions because the only consumer is this
      // admin-facing diagnostic. Walking the DB rather than caching in
      // memory keeps the source of truth in one place.
      final allSessions = await service.database
          .select(service.database.pairingSessions)
          .get();
      final now = DateTime.now();
      final sessions = <Map<String, Object?>>[];
      for (final row in allSessions) {
        if (row.isUsed) continue;
        if (!row.expiresAt.isAfter(now)) continue;
        sessions.add({
          'code': row.pairingCode,
          'expiresAt': row.expiresAt.toUtc().toIso8601String(),
          'expiresInSeconds': row.expiresAt.difference(now).inSeconds,
        });
      }
      return jsonOk(
        {'sessions': sessions},
        headers: {requestIdHeader: requestId},
      );
    } catch (e) {
      _logError('[PAIR][$requestId] Failed to list active sessions: $e');
      return jsonInternalServerError(
        {'error': 'Failed to list active pairing sessions: $e'},
        headers: {requestIdHeader: requestId},
      );
    }
  }

  /// `POST /api/pairing/verify` — exchange a typed code for a session
  /// token.
  ///
  /// Body: `{code, deviceId?, deviceName?, deviceType?, requestedScope?}`.
  /// Defaults to `control` scope (imaging + devices) when `requestedScope` is
  /// absent; `admin` is opt-in via `requestedScope=admin` so a scanned QR or
  /// LAN pairing cannot silently gain backup/filesystem privileges. Every
  /// scope that IS named is minted as asked — see [_resolveRequestedGrant] —
  /// so `requestedScope=view` yields a read-only token and never widens.
  Future<Response> handlePairingVerify(Request request) async {
    final requestId = requestIdFrom(request);
    final clientKey = rateLimitClientKey(request);

    final lockedFor = pairingAttempts.retryAfter(clientKey);
    if (lockedFor != null) {
      _logWarning(
        '[PAIR][$requestId] verify rate-limited from $clientKey '
        'retry=${lockedFor.inSeconds}s',
      );
      return jsonRateLimited(
        {
          'error': 'Pairing attempts temporarily locked',
          'retryAfterSeconds': lockedFor.inSeconds < 1
              ? 1
              : lockedFor.inSeconds,
          'requestId': requestId,
        },
        headers: {
          requestIdHeader: requestId,
          'retry-after': (lockedFor.inSeconds < 1 ? 1 : lockedFor.inSeconds)
              .toString(),
        },
      );
    }

    final payload = await readJsonObject(request);
    final code = requireString(payload, 'code', maxLength: 32);
    // deviceId/deviceName/deviceType identify the dashboard instance for the
    // PairingDatabase. Defaults are conservative so a minimal browser client
    // can pair without sending hardware fingerprints.
    final deviceId =
        optionalString(payload, 'deviceId', maxLength: 128) ??
        'dashboard:${clientKey.replaceAll(':', '_')}';
    final deviceName =
        optionalString(payload, 'deviceName', maxLength: 128) ?? 'Dashboard';
    final deviceType =
        optionalString(payload, 'deviceType', maxLength: 32) ?? 'browser';
    // `requestedScope` accepts the coarse names (`view`/`control`/`admin`) AND
    // a fine-grained spec (e.g. `camera:control,mount:view`). The wider cap
    // accommodates a multi-resource spec; coarse names stay short.
    final requestedScopeRaw =
        optionalString(payload, 'requestedScope', maxLength: 256) ?? 'control';
    final requestedGrant = _resolveRequestedGrant(requestedScopeRaw);
    if (requestedGrant == null) {
      _logWarning(
        '[PAIR][$requestId] verify refused - unparseable requestedScope',
      );
      return jsonBadRequest(
        {
          'error': 'invalid_requested_scope',
          'message':
              'requestedScope is not a scope this server knows. Use "view", '
              '"control", "admin", or a resource list such as '
              '"camera:control,mount:view".',
          'requestId': requestId,
        },
        headers: {requestIdHeader: requestId},
      );
    }

    final service = ensurePairingService();
    final result = await service.verifyPairing(
      code: code,
      deviceId: deviceId,
      deviceName: deviceName,
      deviceType: deviceType,
      authGrantSpec: requestedGrant.toSpec(),
    );

    switch (result.outcome) {
      case PairingVerifyOutcome.success:
        final token = result.sessionToken!;
        recordPairedSession(token, requestedGrant);
        pairingAttempts.clear(clientKey);
        clearAuthFailures(clientKey);
        // The code is spent — do not leave it sitting on disk.
        await _clearOperatorPairingCode();
        _logInfo(
          '[PAIR][$requestId] Pairing succeeded for device=$deviceId '
          'scope=${requestedGrant.toSpec()}',
        );
        return jsonOk(
          {
            'token': token,
            'tokenScope': requestedGrant.toSpec(),
            'expiresAt': result.expiresAt!.toUtc().toIso8601String(),
          },
          headers: {requestIdHeader: requestId},
        );
      case PairingVerifyOutcome.invalidCode:
        pairingAttempts.recordFailure(clientKey);
        _logWarning('[PAIR][$requestId] Invalid pairing code from $clientKey');
        return jsonUnauthorized(
          {
            'error': 'invalid_pairing_code',
            'message': 'The pairing code is not recognised.',
            'requestId': requestId,
          },
          headers: {requestIdHeader: requestId},
        );
      case PairingVerifyOutcome.codeExpired:
        pairingAttempts.recordFailure(clientKey);
        _logWarning('[PAIR][$requestId] Expired pairing code from $clientKey');
        return jsonUnauthorized(
          {
            'error': 'pairing_code_expired',
            'message':
                'The pairing code has expired. Request a new one from the desktop console.',
            'requestId': requestId,
          },
          headers: {requestIdHeader: requestId},
        );
      case PairingVerifyOutcome.codeAlreadyUsed:
        pairingAttempts.recordFailure(clientKey);
        _logWarning('[PAIR][$requestId] Reused pairing code from $clientKey');
        return jsonUnauthorized(
          {
            'error': 'pairing_code_already_used',
            'message':
                'The pairing code has already been claimed. Request a new one.',
            'requestId': requestId,
          },
          headers: {requestIdHeader: requestId},
        );
    }
  }

  /// Resolve the client-requested scope spec to the grant the pairing
  /// receives, honouring every documented name as written: `view` mints a
  /// read-only grant, `control` the imaging + devices grant, `admin` the
  /// everything grant, and a fine-grained spec (`camera:control,mount:view`)
  /// is honoured verbatim. The default when the field is absent stays
  /// `control`, so a client that names no scope pairs exactly as before.
  ///
  /// `view` used to resolve to the `control` grant alongside `control`, which
  /// made the documented read-only request unreachable through pairing: a
  /// browser that asked for read-only was handed imaging control. Nothing in
  /// this tree asked for it — `apps/mobile` sends `control` or `admin`, and
  /// `remote_pairing_client` defaults to `control` — so honouring `view` takes
  /// nothing away from any current caller and stops the one coarse name that
  /// did not mean what it said.
  ///
  /// A spec this server cannot parse is REFUSED by the caller rather than
  /// resolved to a default: falling back to `control` handed a client that had
  /// asked for something narrower (and misspelt it) the widest non-admin grant
  /// there is. Returns null on that spec so [handlePairingVerify] can answer
  /// 400 and the client can retry with a name the server knows.
  HeadlessAuthGrant? _resolveRequestedGrant(String requestedScopeRaw) =>
      HeadlessAuthGrant.parseSpec(requestedScopeRaw);
}
