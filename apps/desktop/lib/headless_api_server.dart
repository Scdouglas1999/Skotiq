// Auth tokens must be printed to stdout transiently (NOT logged to file —
// see the security rationale around _logWarning below). These two prints
// are the only legitimate stdout writes in this file.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:skotiq_remote_protocol/wire.dart';
import 'package:skotiq_updater/skotiq_updater.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'headless_api/auth/auth_cookie.dart';
import 'headless_api/auth/cors_policy.dart';
import 'headless_api/auth/pairing_attempt_tracker.dart';
import 'headless_api/auth/pairing_service.dart';
import 'headless_api/auth/timing.dart';
import 'headless_api/auth/token_resolver.dart';
import 'headless_api/auth/ws_ticket_manager.dart';
import 'headless_api/auth_policy.dart';
import 'headless_api/command_correlator.dart';
import 'headless_api/event_replay_buffer.dart';
import 'headless_api/night_event_log.dart';
import 'headless_api/handler_timeout.dart';
import 'headless_api/handlers.dart';
import 'headless_api/push/database_push_token_store.dart';
import 'headless_api/route_table.dart';
import 'headless_api/job_manager.dart';
import 'headless_api/request_context.dart' as ctx;
import 'headless_api/response_helpers.dart';
import 'headless_api/body_limits.dart';
import 'headless_api/rate_limiting.dart';
import 'headless_api/session_ownership.dart';
import 'headless_api/validation.dart';

part 'headless_api_server/http_middleware.dart';
part 'headless_api_server/auth_middleware.dart';
part 'headless_api_server/rate_limit_middleware.dart';
part 'headless_api_server/websocket_sessions.dart';
part 'headless_api_server/handler_initialization.dart';
part 'headless_api_server/server_lifecycle.dart';
part 'headless_api_server/event_forwarding.dart';

/// Headless API server using Shelf router with modular handlers
class HeadlessApiServer {
  // Re-exported from `headless_api/request_context.dart` so handler classes
  // and route modules outside this file can share the same context keys
  // without depending on `HeadlessApiServer` directly.
  static const _requestIdContextKey = ctx.requestIdContextKey;
  static const _requestIdHeader = ctx.requestIdHeader;

  /// Shelf request-context key holding the SHA-256 digest of
  /// the authenticated bearer token. Set by [_authMiddleware] once a token
  /// resolves to a valid scope; consumed by the rate limiter and the
  /// WebSocket upgrade path. We never propagate the raw token through the
  /// request context — only the digest — so a misbehaving handler that
  /// dumps `request.context` for diagnostics cannot accidentally leak the
  /// secret to a log file.
  static const _authIdentityContextKey = ctx.authIdentityContextKey;

  /// shelf request-context key holding the bound [
  /// TokenRouteClass] for this request. Memoised in the auth middleware so
  /// the rate-limit middleware doesn't have to re-classify the path.
  static const _authRouteClassContextKey = ctx.authRouteClassContextKey;

  final int port;
  final ProviderContainer container;
  final bool bindLocalOnly;
  final bool dispatchPluginNodes;

  /// Whether a frame a remote client saves is also shown in this process's
  /// own image view (a desktop host with a window).
  final bool showApiCapturesInPreview;

  /// Whether this server runs inside the desktop app's window process or the
  /// headless daemon. Reported in `/api/info` (`hostMode`) so a client can say
  /// what it found.
  final SkotiqHostMode hostMode;

  /// Optional authentication token. If set, all API requests must include
  /// this token as a Bearer token in the Authorization header.
  /// Example: `Authorization: Bearer your-secret-token`
  ///
  /// Public endpoints (like /api/info) are exempt from authentication.
  final String? authToken;

  /// Whether authentication is required. When true and authToken is null,
  /// the server will generate a random token and print it to console.
  final bool requireAuth;

  /// Explicit opt-in to the legacy fully-open behaviour: when true AND no
  /// tokens are configured AND no session has paired yet, EVERY endpoint is
  /// served without a bearer token. This is the deliberate trusted-LAN/dev
  /// escape hatch (`--allow-unauthenticated` / `SKOTIQ_ALLOW_UNAUTHENTICATED`)
  /// and triggers a prominent startup warning.
  ///
  /// Default (false) is FAIL CLOSED: an unconfigured server still serves the
  /// pairing/discovery/dashboard bootstrap surface (so a fresh appliance can be
  /// onboarded), but every privileged endpoint returns 401 until a token is
  /// configured or a device pairs. See [_authMiddleware].
  final bool allowUnauthenticated;

  /// Additional coarse scoped tokens. The legacy [authToken] remains an admin
  /// token. Each entry is bridged to a [HeadlessAuthGrant] via
  /// [HeadlessAuthGrant.fromCoarse] so coarse and fine-grained tokens share one
  /// resolution path.
  final Map<String, HeadlessTokenScope> scopedAuthTokens;

  /// Fine-grained tokens carrying a per-resource [HeadlessAuthGrant] (e.g.
  /// "control camera but not mount"). Merged into the same constant-time token
  /// table as the coarse tokens; an entry here overrides a coarse entry with
  /// the same value.
  final Map<String, HeadlessAuthGrant> fineGrainedAuthTokens;
  final Duration webSocketHeartbeatInterval;
  final Duration webSocketHeartbeatTimeout;

  /// Extra browser/origin values allowed to issue cross-origin requests
  /// (beyond same-origin to the bound host:port). Pass as e.g.
  /// `['http://192.168.1.50:3000']`. An explicit list, never origin
  /// reflection: reflecting any origin matching host:port would let any
  /// local-loopback app bypass CORS.
  final List<String> corsAllowedOrigins;

  /// when true, every successful `POST /api/pairing/start` prints the
  /// raw pairing code to stdout (alongside the existing structured-log
  /// breadcrumb). Intended for headless operators on Pi/embedded hosts who
  /// otherwise have no way to see the code. Defaults to false because the
  /// GUI desktop bootstrap surfaces the code in its own UI.
  final bool pairingPrintCodes;

  /// Active pairing policy. [PairingMode.lanOpen] (default) lets a device on the
  /// private LAN pair with one tap and no code; [PairingMode.codeRequired]
  /// forces the code flow even on the LAN. Remote (tailnet/relay/public) clients
  /// always use the code flow regardless. Surfaced in `/api/info` so clients
  /// know whether to auto-claim or prompt for a code.
  final PairingMode pairingMode;

  /// Remote-access identifiers surfaced via `/api/info` so a client never has
  /// to read them off the appliance terminal. [tailscaleHost] is discovered
  /// from local interfaces at [start]; [relayApplianceId] is pushed in by the
  /// headless entry point via [setRelayApplianceId] when a relay uplink
  /// connects. Both null until known.
  String? _tailscaleHost;
  String? _relayApplianceId;

  /// Live snapshot of the remote-access hints for the `/api/info` view.
  ({String? tailscaleHost, String? relayApplianceId}) get remoteAccessHints =>
      (tailscaleHost: _tailscaleHost, relayApplianceId: _relayApplianceId);

  /// Called by the headless entry point when the self-hosted relay uplink
  /// reports its appliance id, so `/api/info` can surface it.
  void setRelayApplianceId(String? id) => _relayApplianceId = id;

  /// optional TLS context. When supplied, the server is bound with
  /// `shelf_io.serve(..., securityContext: tlsContext)` so the entire
  /// transport (HTTP + WebSocket upgrade) speaks HTTPS/WSS. Plain HTTP
  /// remains the default when null. The SHA-256 fingerprint surfaced via
  /// `/api/info` is rebased on the cert's SubjectPublicKeyInfo when this is
  /// set — see [_serverFingerprint].
  final SecurityContext? tlsContext;

  /// when TLS is active, the SHA-256 hex digest of the certificate's
  /// SubjectPublicKeyInfo DER. It overrides the [identitySecret] fingerprint
  /// with a cert-pinned identity anchor. Plain HTTP mode leaves this null and falls
  /// back to [identitySecret].
  final String? tlsPublicKeyFingerprint;

  /// The secret the plain-HTTP fingerprint is derived from. A linked client
  /// refuses a host whose fingerprint changed, so the host start-up passes one
  /// that survives a restart (see `hostIdentitySecret`). Without one the
  /// fingerprint holds only for this server's lifetime.
  final String? identitySecret;

  /// capacity of the in-memory ring buffer that backs WS replay on
  /// reconnect. Default 5000 events â‰ˆ 5 MB at 1 KB/event. Tuned per-deploy
  /// for memory-constrained hosts (Pi 4 / Pi 5).
  final int eventReplayBufferSize;

  HttpServer? _server;
  final List<WebSocketChannel> _sockets = [];
  final Map<WebSocketChannel, String> _socketViewerIds = {};

  /// SHA-256 digest of the bearer token that authenticated each
  /// connected socket. Populated at upgrade time from the request context
  /// that `_authMiddleware` stashed. Used as the canonical `viewerId` for
  /// `collaboration.join` messages — any client-supplied value is ignored.
  /// Null entries are tolerated for sockets that connect when auth is
  /// disabled (no token configured); those still get a viewerId, but it
  /// falls back to whatever the client provides.
  final Map<WebSocketChannel, String?> _socketAuthIdentities = {};

  /// Sockets whose upgrade request had admin access. Every other socket gets
  /// events with credential values hidden ([eventWithCredentialsHidden]).
  final Set<WebSocketChannel> _adminSockets = {};
  final Map<WebSocketChannel, DateTime> _socketLastSeenAt = {};

  /// Broadcasts [_sockets].length on every attach/drop. Broadcast (not single
  /// subscription) because both the GUI status bar and tests observe it, and it
  /// outlives individual `start()`/`stop()` cycles of the same server object.
  final StreamController<int> _connectedClientCountController =
      StreamController<int>.broadcast();
  Timer? _webSocketHeartbeatTimer;
  int _requestCounter = 0;
  StreamSubscription? _eventSubscription;
  StreamSubscription? _collaborationSubscription;
  StreamSubscription? _catalogUpdateSubscription;
  // Push-notification forwarder. Why optional: headless mode has no on-device
  // notifications to forward (the operator is remote); GUI mode wires the
  // PushNotificationService stream here so paired phones receive sequence
  // failures, weather aborts, etc. as separate WebSocket messages distinct
  // from regular event broadcasts.
  StreamSubscription? _pushNotificationSubscription;
  final LiveCollaborationSessionManager _collaborationManager =
      LiveCollaborationSessionManager();
  final EndpointRateLimiter _rateLimiter = EndpointRateLimiter();

  /// per-token / route-class bucket. Independent of the legacy
  /// endpoint window so a single token can hit dozens of different
  /// endpoints without exhausting one shared counter, while still being
  /// throttled if it floods one route class. Keys are derived from the
  /// auth-identity digest computed by [_authMiddleware]; unauthenticated
  /// requests bypass this limiter (they never reach it — auth rejects
  /// them first) so we can rely on a non-null token id at this point.
  final TokenBucketRateLimiter _tokenBucketLimiter = TokenBucketRateLimiter();

  /// The effective auth token (either provided or generated)
  late final String? _effectiveAuthToken;
  late final Map<String, HeadlessAuthGrant> _effectiveAuthTokensByValue;
  late final TokenResolver _tokenResolver;
  late final CorsAllowList _corsAllowList;
  late final WsTicketManager _wsTicketManager;
  late final AuthCookieManager _authCookieManager;
  late final PairingAttemptTracker _pairingAttempts;
  PairingService? _pairingService;

  /// Test seam for the lazy-construction path in [_ensurePairingService]:
  /// when set and no [pairingService] was injected, the factory supplies
  /// the lazily-created service (e.g. one backed by an in-memory
  /// [PairingDatabase]) instead of `PairingService()` — whose default
  /// database would resolve the real on-disk store.
  final PairingService Function()? _pairingServiceFactory;
  // Tokens minted by completed pairing flows and their scopes. Separate from
  // the configured token table because pairing tokens live in PairingDatabase
  // (Drift) and must not mutate the immutable configured-token map.
  //
  // Hydrated from `PairedDevices` at [start()] so a restart does not evict
  // paired clients. Entries are evicted synchronously by
  // [_evictPairedSessionToken] when the TokenManager surfaces a revoke or
  // expiry event.
  //
  // Bounded with LRU-on-write eviction so a pairing flood, or a very
  // long-lived appliance, cannot grow it without bound — every authenticated
  // request linearly scans this map in [_scopeForToken]. The mint routes are
  // rate-limited (see `_rateLimitedPairingPaths`); the cap is the backstop,
  // and its ceiling is far above any realistic paired-device count.
  final BoundedTokenGrantMap _pairedSessionTokens = BoundedTokenGrantMap();

  /// Pending while `start()` is still loading [_pairedSessionTokens] from the
  /// pairing database, null once it has finished. Requests wait on it (see
  /// `_pairedTokenHydrationGate`) instead of being judged against a map that
  /// is still empty.
  Future<void>? _pairedTokenHydration;

  /// The longest a request waits on [_pairedTokenHydration]. Reading the
  /// pairing database takes milliseconds; one that never answers (a stuck
  /// disk) must not hold every request, the public connect and pairing
  /// endpoints included, for as long as the process lives. Past this a
  /// request is judged on the tokens loaded so far, as it was before the gate.
  static const Duration _pairedTokenHydrationWaitLimit = Duration(seconds: 10);

  /// When each paired session token last had its device row stamped as seen.
  ///
  /// The middleware authenticates against the in-memory [_pairedSessionTokens]
  /// map, so `TokenManager.verifySessionToken` — the only other writer of
  /// `paired_devices.last_connected_at` — never runs. This map carries the
  /// stamp instead, throttled to at most one write per token per
  /// [_lastConnectedThrottle] so an actively polling client does not issue an
  /// UPDATE per request.
  final Map<String, DateTime> _pairedDeviceSeenStamps = <String, DateTime>{};
  static const Duration _lastConnectedThrottle = Duration(minutes: 1);

  /// periodic sweep that walks `PairedDevices` and drops expired
  /// rows + evicts revoked entries from [_pairedSessionTokens]. Interval is
  /// configurable mainly for tests; production runs at 60s.
  Timer? _tokenSweepTimer;
  Future<void>? _tokenSweepFuture;
  Duration get tokenSweepInterval => const Duration(seconds: 60);

  /// SHA-256 host fingerprint surfaced in `/api/info` and desktop QR codes.
  late final String _serverFingerprint;

  /// random UUID generated once at server construction time. Mirrored
  /// onto every outbound event and returned by /api/info. Clients use a
  /// mismatch to detect a server restart and abandon their seq cursor.
  late final String _serverInstanceId;

  /// monotonically increasing event sequence number, starts at 1
  /// for the first broadcast event of this server instance. Wraps would
  /// require ~9.2 quintillion events which is well past practical for
  /// the buffer's lifetime.
  int _eventSeq = 0;

  /// ring buffer of recently broadcast events for WS replay on
  /// reconnect.
  late final EventReplayBuffer _eventReplayBuffer;
  final NightEventLog _nightEventLog = NightEventLog();

  late final CommandCorrelator _commandCorrelator;

  /// Periodic sweep that evicts expired pending commands from the
  /// correlator. Cheap to run; the table is usually tiny.
  Timer? _commandCorrelatorSweepTimer;

  /// long-running operation manager. Autofocus, plate-solve,
  /// center-on-target, polar alignment, and similar multi-minute ops
  /// register as Jobs and return `{jobId}` immediately rather than
  /// holding the HTTP connection open.
  late final JobManager _jobManager;

  /// Periodic sweep that evicts terminated jobs older than the
  /// manager's retention window (default 24h). 5-minute cadence to keep
  /// the worst-case age bounded without busy-looping.
  Timer? _jobSweepTimer;

  /// Unattended driver that auto-completes a Collaborative Sky
  /// collaborative mosaic (owner: assemble + publish; participant: pull the
  /// finished mosaic) so a multi-rig collaborative night finishes with nobody
  /// watching. Started in [_startServer], stopped in [_stopServer].
  CollaborativeMosaicPoller? _collabMosaicPoller;

  /// tracks which client currently owns the rig. Destructive
  /// endpoints (sequencer start, mount slew, dome open, ...) require
  /// the caller to be the operator or return 409 with a take-over hint.
  late final SessionOwnershipManager _sessionOwnership;

  LoggingService get _logger => container.read(loggingServiceProvider);

  String _nextRequestId() {
    _requestCounter = (_requestCounter + 1) % 0xFFFFF;
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final seq = _requestCounter.toRadixString(36);
    return '$ts-$seq';
  }

  String _requestIdFrom(Request request) =>
      request.context[_requestIdContextKey] as String? ?? 'unknown';

  void _logInfo(String message, {Map<String, Object?>? fields}) =>
      _logger.info(message, source: 'HeadlessApiServer', fields: fields);
  void _logWarning(String message, {Map<String, Object?>? fields}) =>
      _logger.warning(message, source: 'HeadlessApiServer', fields: fields);
  void _logError(String message, {Map<String, Object?>? fields}) =>
      _logger.error(message, source: 'HeadlessApiServer', fields: fields);

  late final RouteTable _routeTable;

  // The handler classes the server itself calls into, beyond routing.
  late final EquipmentHandlers _equipmentHandlers;
  late final StackingHandlers _stackingHandlers;
  StreamController<SkotiqEvent>? _runWatchEventBroadcast;
  late final LiveViewStreamHandlers _liveViewStreamHandlers;
  late final LiveViewStreamHub _liveViewStreamHub;
  late final WebRtcLiveViewHandlers _webRtcLiveViewHandlers;
  StreamSubscription<CatalogEvent>? _catalogEventSubscription;

  UpdateHandlers? _updateHandlers;
  StreamSubscription<UpdateEvent>? _updateEventSubscription;

  /// LAN UDP broadcaster wired in main_headless.dart /
  /// desktop_app_bootstrap.dart. When supplied, every critical push that
  /// flows through [setPushNotificationStream] is also fanned out as a
  /// UDP datagram so backgrounded phones (Android WS-dropped, foreground-
  /// service iOS) receive the alert even when the WS is broken. Null when
  /// the server is bound loopback-only (no LAN to broadcast on).
  LanPushBroadcaster? _lanPushBroadcaster;

  /// optional cellular delivery (FCM/APNs). The base
  /// implementations throw [UnimplementedError] until an operator wires
  /// the cloud-side configuration; see
  /// `docs/remote-control.md#critical-push-notifications-fcm-apns`.
  RemotePushDelivery? _remotePushDelivery;

  HeadlessApiServer({
    required this.port,
    required this.container,
    this.bindLocalOnly = true,
    this.dispatchPluginNodes = true,
    this.showApiCapturesInPreview = false,
    this.hostMode = SkotiqHostMode.headless,
    this.authToken,
    this.requireAuth = false,
    this.allowUnauthenticated = false,
    this.scopedAuthTokens = const {},
    this.fineGrainedAuthTokens = const {},
    this.webSocketHeartbeatInterval = const Duration(seconds: 30),
    this.webSocketHeartbeatTimeout = const Duration(seconds: 90),
    this.corsAllowedOrigins = const [],
    this.pairingPrintCodes = false,
    this.pairingMode = PairingMode.lanOpen,
    this.tlsContext,
    this.tlsPublicKeyFingerprint,
    this.identitySecret,
    this.eventReplayBufferSize = 5000,
    PairingService? pairingService,
    PairingService Function()? pairingServiceFactory,
    CommandCorrelator? commandCorrelator,
    String? serverInstanceId,
    LanPushBroadcaster? lanPushBroadcaster,
    RemotePushDelivery? remotePushDelivery,
  }) : _pairingServiceFactory = pairingServiceFactory {
    _lanPushBroadcaster = lanPushBroadcaster;
    _remotePushDelivery = remotePushDelivery;
    _pairingService = pairingService;
    // fix the server-instance UUID at construction time so unit
    // tests that exercise the /api/info endpoint can observe it
    // synchronously without waiting for start().
    _serverInstanceId = serverInstanceId ?? _generateUuidV4();
    _eventReplayBuffer = EventReplayBuffer(capacity: eventReplayBufferSize);
    // caller may inject a deterministic correlator for tests; the
    // default uses Random.secure + DateTime.now.
    _commandCorrelator = commandCorrelator ?? CommandCorrelator();
    final tokensByValue = <String, HeadlessAuthGrant>{};

    if (authToken != null) {
      _effectiveAuthToken = authToken;
      tokensByValue[authToken!] = HeadlessAuthGrant.admin();
    } else if (requireAuth) {
      _effectiveAuthToken = _generateRandomToken();
      tokensByValue[_effectiveAuthToken!] = HeadlessAuthGrant.admin();
      // Why: the auto-generated token must be visible to the operator once
      // so they can configure a client, but persisting it in the log file
      // is a security defect — anyone with read access to logs would have
      // permanent admin auth. Print full to stdout (transient), redact in
      // the structured log.
      print('[AUTH] Generated authentication token: $_effectiveAuthToken');
      print(
        '[AUTH] Use this token in the Authorization header: Bearer $_effectiveAuthToken',
      );
      _logWarning(
        '[AUTH] Auto-generated token (first run): ${_redactBearer(_effectiveAuthToken)}',
      );
    } else {
      _effectiveAuthToken = null;
    }

    for (final entry in scopedAuthTokens.entries) {
      final token = entry.key.trim();
      if (token.isNotEmpty) {
        tokensByValue[token] = HeadlessAuthGrant.fromCoarse(entry.value);
      }
    }
    // Fine-grained tokens last so an explicit per-resource grant wins over a
    // coarse entry sharing the same value.
    for (final entry in fineGrainedAuthTokens.entries) {
      final token = entry.key.trim();
      if (token.isNotEmpty) {
        tokensByValue[token] = entry.value;
      }
    }
    _effectiveAuthTokensByValue = Map.unmodifiable(tokensByValue);

    // With TLS the certificate's SubjectPublicKeyInfo SHA-256 is the identity
    // a client pins (raw hex of the DER, 64 chars). Over plain HTTP it is
    // sha256("skotiq-remote-v1:" + identitySecret).
    final tlsPin = tlsPublicKeyFingerprint?.trim();
    final secret = identitySecret?.trim();
    _serverFingerprint = tlsPin != null && tlsPin.isNotEmpty
        ? tlsPin
        : computeServerFingerprint(
            secret != null && secret.isNotEmpty
                ? secret
                : _generateRandomToken(),
          );

    // Why: the resolver iterates the entire token map every lookup with
    // constant-time comparison. The map captured here is the union of the
    // configured static tokens; paired-session tokens are checked alongside
    // via [_pairedSessionTokens] (also constant-time) when present.
    _tokenResolver = TokenResolver(tokensByValue: _effectiveAuthTokensByValue);
    _corsAllowList = CorsAllowList.fromConfig(
      additionalOrigins: corsAllowedOrigins,
    );
    _wsTicketManager = WsTicketManager();
    _authCookieManager = AuthCookieManager();
    _pairingAttempts = PairingAttemptTracker();

    _routeTable = RouteTable(_initializeHandlers());
  }

  /// Sorted, deduplicated list of scope names present in the configured
  /// + paired token tables. Captured into [SystemServerView] so the
  /// extracted [SystemHandlers] can surface it on /api/info and
  /// /api/self-test without re-reading server state.
  List<String> _availableAuthScopes() {
    final scopes = _effectiveAuthTokensByValue.values
        .map((grant) => headlessTokenScopeName(grant.coarseScope))
        .toSet()
        .toList();
    scopes.sort();
    return scopes;
  }

  // Pairing flow — first-run dashboard onboarding.
  //
  // The desktop console prints the 6-digit code; the dashboard user retypes it
  // into the Pair sheet. Verifying the code mints a long-lived bearer token
  // that the dashboard then uses for all authenticated calls. The code itself
  // is never returned in the HTTP response body so a network observer (or a
  // logging proxy) cannot harvest it without console access.

  /// Returns the [PairingService], lazily constructing one on first use.
  /// Why lazy: the constructor cannot await a [PairingDatabase] open, but the
  /// service must outlive a single request. We create it on demand and reuse
  /// the same instance for the rest of the server lifetime.
  PairingService _ensurePairingService() {
    final existing = _pairingService;
    if (existing != null) return existing;
    final created = (_pairingServiceFactory ?? PairingService.new)();
    _pairingService = created;
    // ensure the revocation listener is wired even when the service
    // was lazy-constructed (i.e. the headless operator never explicitly
    // injected one but a verify call just created it). The startup
    // [_installRevocationListener] no-ops when no service exists; this is
    // the symmetric hook for the late-binding case.
    created.tokenManager.setRevocationListener(_evictPairedSessionToken);
    return created;
  }

  /// Whether [method] mutates state and therefore requires CSRF when the
  /// caller is using a cookie. Why uppercase compare: shelf passes the
  /// raw method but middleware may have lowercased it elsewhere — be
  /// defensive. Stays inline because the auth middleware (which lives
  /// here) is the only consumer.
  static bool _methodNeedsCsrf(String method) {
    final upper = method.toUpperCase();
    return upper == 'POST' ||
        upper == 'PUT' ||
        upper == 'DELETE' ||
        upper == 'PATCH';
  }

  /// Generates a cryptographically secure random token.
  static String _generateRandomToken({int length = 32}) {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = Random.secure();
    return List.generate(
      length,
      (_) => chars[random.nextInt(chars.length)],
    ).join();
  }

  /// inline UUID v4 generator used for the server-instance id. We
  /// deliberately avoid `package:uuid` so the server has no extra
  /// dependency for this single call site. RFC 4122 §4.4.
  static String _generateUuidV4() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    String hex(int n) => n.toRadixString(16).padLeft(2, '0');
    final h = bytes.map(hex).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-'
        '${h.substring(12, 16)}-${h.substring(16, 20)}-'
        '${h.substring(20)}';
  }

  /// Redact a bearer/auth token for structured-log output. Shows the first
  /// 4 + last 4 chars and masks the middle, so log readers can correlate
  /// a token across log lines without exposing the secret in plaintext.
  /// Delegates to [ctx.redactBearer] so the same redaction rule applies
  /// across the server, every extracted handler class, and the audit
  /// surfaces.
  static String _redactBearer(String token) => ctx.redactBearer(token);

  Future<void> start() => _startServer();

  Future<void> stop() => _stopServer();

  /// Stamp and fan an event out to the WebSocket clients and replay buffer,
  /// returning the stamped event so a caller can also hand the SAME stamped
  /// copy to the run-watch SSE fan-out (see [_broadcastEventImpl]). Callers
  /// that only broadcast may ignore the result.
  SkotiqEvent? broadcastEvent(dynamic event) => _broadcastEventImpl(event);

  void setPushNotificationStream(
    Stream<Map<String, dynamic>> notificationStream,
  ) => _setPushNotificationStream(notificationStream);

  void setLanPushBroadcaster(LanPushBroadcaster? broadcaster) =>
      _setLanPushBroadcaster(broadcaster);

  void setRemotePushDelivery(RemotePushDelivery? delivery) =>
      _setRemotePushDelivery(delivery);

  /// A [PushTokenStore] over this server's pairing DB — the recipient list the
  /// FCM/APNs/mock deliveries enumerate. Lazily constructs the
  /// [PairingService] (and thus opens the Drift DB) on first call, so only
  /// deployments that actually wire cellular push pay the DB-open cost.
  PushTokenStore get pushTokenStore =>
      DatabasePushTokenStore(_ensurePairingService().database);

  /// Explicit development helper that wires [MockRemotePushDelivery].
  /// delivery. Every critical push that reaches the cellular tap is then
  /// enumerated against the registered tokens (filtered by per-device prefs)
  /// and recorded into the mock's `delivered` list / logged as "would-send".
  ///
  /// Production bootstrap never calls this implicitly: a mock records a
  /// would-send but cannot page an operator, so it must only be enabled by an
  /// explicit `mock:true` push configuration or a test/dev caller.
  MockRemotePushDelivery wireMockRemotePushDelivery({
    void Function(String message)? log,
  }) {
    final mock = MockRemotePushDelivery(store: pushTokenStore, log: log);
    _setRemotePushDelivery(mock);
    return mock;
  }

  /// Phase D — load [PushConfig] from [appSupportDir] (or the
  /// `SKOTIQ_PUSH_CONFIG` env override) and wire the resulting delivery:
  ///
  ///  * a real FCM and/or APNs delivery when the operator has dropped a valid
  ///    `push_config.json` pointing at the service-account JSON / `.p8` key
  ///    (the "real when configured" path),
  ///  * an explicit [MockRemotePushDelivery] only when `mock:true`, or
  ///  * no cellular delivery when no channel is configured.
  ///
  /// All deliveries share [pushTokenStore], so each enumerates the same
  /// `device_push_tokens` rows filtered by `device_push_prefs`. Returns the
  /// wired delivery, or `null` when no real channel (and no explicit mock) is
  /// configured. Never claims a mock would-send as real delivery.
  Future<RemotePushDelivery?> wireRemotePushDelivery({
    required String appSupportDir,
    void Function(String message)? log,
  }) async {
    final store = pushTokenStore;
    PushConfig config;
    try {
      config = await PushConfig.load(appSupportDir: appSupportDir);
    } catch (_) {
      config = PushConfig.disabled;
    }
    final delivery = config.mock && !config.hasCloudChannel
        ? MockRemotePushDelivery(store: store, log: log)
        : buildRemotePushDelivery(config, store);
    if (delivery != null) {
      _setRemotePushDelivery(delivery);
    }
    return delivery;
  }

  void setUpdateController(UpdateController? controller) =>
      _setUpdateController(controller);

  /// Get the current authentication token (for logging/debugging).
  /// Returns null if authentication is disabled.
  String? get effectiveAuthToken => _effectiveAuthToken;

  /// The bound HTTP port. Useful when the server was started with port 0.
  int get actualPort => _server?.port ?? port;

  /// The same SHA-256 hex digest the server surfaces from `GET /api/info`.
  ///
  /// Either the TLS SubjectPublicKeyInfo digest when TLS is active or the
  /// [identitySecret] digest otherwise. Exposed so
  /// the mDNS advertiser can publish the value as a TXT record,
  /// keeping the QR `fingerprint`, the `/api/info` `fingerprint`, and the
  /// mDNS `fingerprint` aligned.
  String get serverFingerprint => _serverFingerprint;

  /// `true` when the server is bound with a TLS context. The mDNS `scheme`
  /// TXT record reads this so the advertised transport matches reality.
  bool get isTlsActive => tlsContext != null;

  /// `true` when a request needs a bearer token for anything beyond the
  /// public pairing and discovery surface. Only an operator's
  /// `--allow-unauthenticated` on a server with no configured token opens it;
  /// a server with no token and no opt-in is closed until a device pairs.
  bool get isAuthRequired =>
      !allowUnauthenticated || _effectiveAuthTokensByValue.isNotEmpty;

  /// random UUID identifying this server instance. Returned by
  /// /api/info and stamped on every outbound event.
  String get serverInstanceId => _serverInstanceId;

  /// current monotonic event sequence counter. 0 before any event
  /// has been broadcast.
  int get currentEventSeq => _eventSeq;

  /// oldest event seq retained in the replay buffer, or null when
  /// no events have been emitted yet.
  int? get eventReplayBufferOldestSeq => _eventReplayBuffer.oldestSeq;

  /// command correlator owned by this server. Handlers call
  /// [CommandCorrelator.beginCommand] before kicking off an action so the
  /// response can include the commandId and later events get tagged.
  CommandCorrelator get commandCorrelator => _commandCorrelator;

  /// in-memory job manager. Exposed so the GUI / tests can
  /// drive it directly without going through HTTP, and so handlers in
  /// other modules can register long-running operations through the
  /// same manager.
  JobManager get jobManager => _jobManager;

  /// operator-slot manager. Exposed so the GUI can subscribe to
  /// ownership-change events for the desktop status-bar badge, and so
  /// tests can introspect the slot without going through HTTP.
  SessionOwnershipManager get sessionOwnership => _sessionOwnership;

  /// Expose the internal collaboration manager so GUI hosts can track
  /// viewer-count changes (drives the desktop status-bar viewer badge).
  /// Why expose rather than emit yet another callback: the manager already
  /// publishes a `LiveCollaborationState` stream consumers can subscribe to,
  /// and exposing it avoids duplicating that wiring for one more listener.
  LiveCollaborationSessionManager get collaborationManager =>
      _collaborationManager;

  /// Number of remote clients currently holding an event socket open.
  ///
  /// The collaboration manager's viewer list only counts co-imaging
  /// participants, so a paired phone that just streams `/events` all night was
  /// invisible to every "is anyone connected?" indicator in the GUI. This is
  /// the socket registry itself.
  int get connectedClientCount => _sockets.length;

  /// Emits [connectedClientCount] whenever a client attaches or drops.
  Stream<int> get connectedClientCountStream =>
      _connectedClientCountController.stream;

  /// Publish the current socket count. Called from the two places that mutate
  /// [_sockets] plus shutdown, so the GUI never has to poll.
  void _publishConnectedClientCount() {
    if (_connectedClientCountController.isClosed) return;
    _connectedClientCountController.add(_sockets.length);
  }
}

class _RequestBodyLimitResult {
  final bool accepted;
  final Uint8List bytes;
  final int receivedBytes;

  const _RequestBodyLimitResult._({
    required this.accepted,
    required this.bytes,
    required this.receivedBytes,
  });

  factory _RequestBodyLimitResult.accepted(Uint8List bytes, int receivedBytes) {
    return _RequestBodyLimitResult._(
      accepted: true,
      bytes: bytes,
      receivedBytes: receivedBytes,
    );
  }

  factory _RequestBodyLimitResult.rejected(int receivedBytes) {
    return _RequestBodyLimitResult._(
      accepted: false,
      bytes: Uint8List(0),
      receivedBytes: receivedBytes,
    );
  }
}

/// Insertion-ordered map of paired-session bearer tokens to their granted
/// [HeadlessTokenScope] that evicts the least-recently-written entry once it
/// exceeds [maxEntries].
///
/// Pairing and one-tap LAN claim mint long-lived session tokens into this map,
/// and [HeadlessApiServer._scopeForToken] scans it in constant time on every
/// authenticated request that isn't a configured static token. Without a
/// ceiling a LAN flood (or a multi-year appliance) grows it without bound. Re-writing an existing key refreshes its recency (remove-then-insert)
/// so an actively re-paired token survives eviction longest; otherwise the
/// oldest entry is dropped. [maxEntries] defaults far above any realistic
/// paired-device count, so it is a backstop rather than a routine eviction
/// path — the per-endpoint rate limit on the pairing routes is the first line
/// of defence.
class BoundedTokenGrantMap extends MapBase<String, HeadlessAuthGrant> {
  BoundedTokenGrantMap({this.maxEntries = 1024})
    : assert(maxEntries > 0, 'maxEntries must be positive');

  final int maxEntries;
  final Map<String, HeadlessAuthGrant> _entries = <String, HeadlessAuthGrant>{};

  @override
  HeadlessAuthGrant? operator [](Object? key) => _entries[key];

  @override
  void operator []=(String key, HeadlessAuthGrant value) {
    // remove-then-insert so the most-recently-written key moves to the tail of
    // the insertion order and is therefore evicted last.
    _entries.remove(key);
    _entries[key] = value;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  @override
  HeadlessAuthGrant? remove(Object? key) => _entries.remove(key);

  @override
  void clear() => _entries.clear();

  @override
  Iterable<String> get keys => _entries.keys;
}
