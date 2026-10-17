import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:skotiq_core/skotiq_core.dart';
// TailnetDetector is the single source of truth for host reachability
// classification (LAN vs Tailscale tailnet vs public). Reused here so the
// scheme/timeout tuning matches the QR/pairing validator exactly.
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart'
    show PushDeliveryTargets, TailnetDetector, buildSkotiqServerUri;
import 'package:path/path.dart' as p;
import '../models/settings/app_settings.dart' as models;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

// Import pure Dart types from backend_types for return types
import '../models/errors/skotiq_error.dart' as dart_error;
// Error parsing: parse the headless server's structured error
// envelope ({code, message, details}) into a typed [ServerError] so the
// mobile companion can branch on the machine-readable `code` instead of
// substring-matching the message text.
import 'remote_display_jpeg.dart';
import 'skotiq_exception.dart'
    show ImagingException, IoException, ValidationException;

part 'network_backend/remote_operations.dart';
part 'network_backend/remote_calibration_catalog_operations.dart';
part 'network_backend/remote_database_plugin_operations.dart';
part 'network_backend/remote_log_operations.dart';
part 'network_backend/remote_live_view_operations.dart';
part 'network_backend/domain_operations.dart';
part 'network_backend/session_science_operations.dart';
part 'network_backend/planning_accessory_operations.dart';
part 'network_backend/planning_data_operations.dart';
part 'network_backend/observing_list_operations.dart';
part 'network_backend/device_operations.dart';
part 'network_backend/guiding_operations.dart';
part 'network_backend/sequencer_operations.dart';
part 'network_backend/replay_debug_operations.dart';
part 'network_backend/stacking_operations.dart';
part 'network_backend/post_session_operations.dart';
part 'network_backend/depthlock_operations.dart';
part 'network_backend/imaging_profile_operations.dart';
part 'network_backend/webrtc_subscription.dart';
part 'network_backend/wire_models.dart';
part 'network_backend/wire_history_models.dart';
part 'network_backend/connection_lifecycle.dart';
part 'network_backend/event_tracking.dart';
part 'network_backend/http_transport.dart';
part 'network_backend/wire_decoding.dart';

/// Network backend implementation that communicates with a headless server
///
/// This backend uses HTTP REST API and WebSocket for real-time events
/// and is used by the Mobile app to control a remote Desktop/Headless instance.
abstract class _NetworkBackendTransport {
  static const _requestIdHeader = 'x-request-id';

  final String serverHost;
  final int serverPort;
  final int webSocketPort;

  /// ID returned by the most recent successful profile save. The backend role
  /// method returns `Future<void>`; this client also exposes the saved id so
  /// remote creates never have to rediscover a row by a non-unique profile
  /// name.
  String? _lastSavedProfileId;
  String? get lastSavedProfileId => _lastSavedProfileId;

  /// URL scheme for the REST/SSE transport: `'http'` (plaintext, the LAN
  /// default) or `'https'` (TLS, used when the server is exposed over a
  /// tailnet / the wider Internet and presents a certificate). The WebSocket
  /// scheme is derived from this: `https` ⇒ `wss`, `http` ⇒ `ws` (see
  /// [_wsScheme]). Normalised to lower-case in the constructor and validated
  /// to be exactly one of the two accepted values — an unrecognised scheme
  /// throws rather than silently defaulting.
  final String scheme;

  /// Optional server-identity fingerprint pinned by the client (typically the
  /// `shortServerFingerprint` carried in the pairing QR / saved-server
  /// record). When non-null and non-empty, the `/api/info` handshake verifies
  /// the server's advertised `fingerprint` matches before the WebSocket is
  /// opened; a mismatch is a fail-closed terminal error (the connection is
  /// refused and the state goes to [BackendConnectionState.error]) so a
  /// man-in-the-middle on a hostile network cannot impersonate the rig the
  /// operator paired with. Null disables pinning (LAN / first-pair flows where
  /// the fingerprint is not yet known).
  final String? pinnedFingerprint;

  String? authToken;
  final Future<String?> Function()? refreshAuthToken;
  final Duration webSocketHeartbeatInterval;
  final Duration webSocketHeartbeatTimeout;

  /// Per-request timeout applied to the JSON HTTP helpers' transient-retry
  /// wrapper ([_retryableRequest]). Defaults are tuned in the constructor:
  /// LAN connections get a 30 s ceiling; remote (tailnet / Internet)
  /// connections traverse a relay or DERP hop with higher and more variable
  /// latency, so they get a longer one and a slow-but-alive link is not torn
  /// down mid-request.
  final Duration requestTimeout;

  /// `true` iff [serverHost] is a Tailscale *endpoint* — a tailnet IP literal
  /// (`100.64.0.0/10` or `fd7a:115c::/32`) OR a MagicDNS `*.ts.net` hostname
  /// (see [TailnetDetector.isTailscaleEndpoint]). Drives the remote-tuned
  /// timeout defaults and lets callers/telemetry distinguish a LAN session
  /// from one riding the tailnet. LAN, loopback, mDNS `.local`, and public
  /// hosts are all `false`.
  ///
  /// MagicDNS `*.ts.net` names count as remote: they traverse the same
  /// DERP-relayed path as a `100.x` literal and need the same relaxed timeouts.
  final bool isRemoteHost;

  WebSocketChannel? _wsChannel;
  StreamSubscription? _wsSubscription;
  Timer? _webSocketHeartbeatTimer;
  final StreamController<SkotiqEvent> _eventController =
      StreamController<SkotiqEvent>.broadcast();
  final StreamController<Map<String, dynamic>> _pushNotificationController =
      StreamController<Map<String, dynamic>>.broadcast();

  final StreamController<Map<String, dynamic>> _polarAlignController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Persistent HTTP client for connection reuse.
  /// Using a single client avoids TCP connection churn and enables
  /// keep-alive connections for better performance.
  ///
  /// Why: dart:io `HttpClient` is retained for the binary streaming paths
  /// (image thumbnail/download, raw image bytes, FITS write) that rely on
  /// chunked response streaming. The JSON helper layer below uses
  /// `package:http` so it can be injected with a `MockClient` in tests.
  late final HttpClient _httpClient;

  /// `package:http` client used by the JSON HTTP helpers (`_get`, `_post`,
  /// `_put`, `_delete`, `_downloadBytes`, `_postRaw`, `_postRawBytes`, and
  /// `_checkServerCompatibility`). Injectable so tests can substitute a
  /// `MockClient` without spinning up a real HTTP server.
  final http.Client _http;

  /// Whether `_http` was constructed internally and therefore must be closed
  /// in `dispose`. When a caller injects a client (e.g. a test fake), the
  /// caller owns its lifecycle.
  final bool _ownsHttpClient;

  // Connection state management
  BackendConnectionState _connectionState = BackendConnectionState.disconnected;
  final StreamController<BackendConnectionState> _connectionStateController =
      StreamController<BackendConnectionState>.broadcast();
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;
  DateTime? _lastWebSocketMessageAt;
  bool _disposed = false;
  bool _disconnecting = false;
  bool _webSocketHeartbeatPausedForLifecycle = false;
  int _requestCounter = 0;
  static const int _maxReconnectDelay = 30; // Max 30 seconds

  /// In-flight connect/disconnect requests keyed by `<deviceType>:<deviceId>`.
  /// A slow connect can otherwise be re-issued by an impatient UI (or by the
  /// connect dialog firing twice), piling duplicate POSTs onto the host's
  /// serial bus. While a connect is pending we return the SAME future instead
  /// of sending a second POST. Connect/disconnect deliberately do NOT use the
  /// retry path, so a request that times out is never auto-resent — host-side
  /// idempotency + non-retry together stop the serial-mount pile-up.
  final Map<String, Future<void>> _inFlightConnectOps = {};

  /// Latches `true` the first time a connection attempt reaches the
  /// `connected` state. Used to distinguish the initial-handshake `connecting`
  /// transition from subsequent `reconnecting` attempts so the UI can render
  /// distinct messaging on each.
  bool _hasEverConnected = false;

  /// The auth token the host last told us is invalid (`403 Invalid
  /// authentication token`). Non-null ⇒ every further request with the same
  /// token is guaranteed to fail, so we fail fast locally instead of
  /// feeding the server's auth-failure rate limiter (which escalates the
  /// whole client into `429` lockouts). Cleared when [authToken] changes or
  /// on an explicit reconnect. Distinct from [_authRejected]: this is the
  /// definitive "token itself is dead" signal, so HTTP callers consult it
  /// too.
  String? _rejectedAuthToken;

  /// Terminal auth-failure latch for the connection lifecycle. Set when the
  /// server rejects our credentials — either an HTTP `403 Invalid
  /// authentication token` or a WebSocket upgrade refused with `403` —
  /// because retrying the same credentials cannot succeed and every retry
  /// deepens the server-side auth lockout. Puts the backend in
  /// [BackendConnectionState.error] until an explicit reconnect clears it.
  bool _authRejected = false;

  /// Identity payload sent on `collaboration.join` after the WS
  /// handshake completes. The server overrides the `viewerId` with the
  /// authenticated principal's digest but we still send our
  /// derived value so the wire shape stays unchanged for hosts that
  /// pre-date the override and so the server can log impersonation
  /// attempts when our identity doesn't match. Display name appears in
  /// the viewer slot list on the desktop UI; defaults are derived in the
  /// mobile bootstrap and injected via [collaborationIdentity].
  String? _collaborationViewerId;
  String? _collaborationDeviceName;
  String? _collaborationDisplayName;

  // Ping/pong round-trip latency tracking. The WebSocket heartbeat already
  // exchanges {type:"ping"} / {type:"pong"} every `webSocketHeartbeatInterval`,
  // so this just records the send timestamp and computes the delta when the
  // matching pong arrives. We don't attach an id to pings (the server replies
  // to every ping with a single pong), so we just keep the most recent send
  // timestamp.
  DateTime? _pendingPingSentAt;
  Duration? _lastLatency;
  final StreamController<Duration> _latencyController =
      StreamController<Duration>.broadcast();

  // Client-side event sequencing + replay state.
  //
  // `_lastSeenEventSeq` is the monotonic seq of the most recent event we
  // accepted from the server. Null until the first event with a non-null
  // seq is observed (which is also the cursor we send back as `?since=`
  // on a reconnect to ask the server to replay anything we missed).
  //
  // `_serverInstanceId` is the UUID the server stamps on every outbound
  // event; a change in this value means the server restarted and our
  // cached seq cursor is now meaningless (the new server starts counting
  // from 0).
  //
  // `_previousServerInstanceId` snapshots the last instance we successfully
  // attached to so that, on the NEXT reconnect, we can compare against
  // whatever the new server advertises and reset the cursor if they
  // differ. This is the reactive path; the in-band check inside the WS
  // message handler covers the rarer "instance changes mid-stream" case.
  int? _lastSeenEventSeq;
  String? _serverInstanceId;
  String? _previousServerInstanceId;

  /// Heartbeat-timeout default for LAN sessions. The watchdog tears the
  /// socket down if no frame (including the server's pong) arrives within this
  /// window. 45 s tolerates a few missed 15 s heartbeats on a flaky LAN.
  static const Duration _lanHeartbeatTimeout = Duration(seconds: 45);

  /// Heartbeat-timeout default for remote (tailnet / Internet) sessions. A
  /// DERP-relayed tailnet hop can stall for several seconds during a network
  /// transition (Wi-Fi→cellular handoff, NAT rebind) without the session
  /// actually being dead; a 90 s window rides those out instead of forcing a
  /// full reconnect cycle the operator would see as a dropout.
  static const Duration _remoteHeartbeatTimeout = Duration(seconds: 90);

  /// TCP connection-establishment timeout for the binary-streaming
  /// [HttpClient]. LAN: 10 s. Remote: 20 s (a cold tailnet path may need a
  /// DERP handshake before the first byte).
  static const Duration _lanConnectionTimeout = Duration(seconds: 10);
  static const Duration _remoteConnectionTimeout = Duration(seconds: 20);

  /// Per-request ceiling for the JSON helper retry wrapper. LAN: 30 s
  /// (unchanged). Remote: 60 s.
  static const Duration _lanRequestTimeout = Duration(seconds: 30);
  static const Duration _remoteRequestTimeout = Duration(seconds: 60);

  _NetworkBackendTransport({
    required this.serverHost,
    this.serverPort = 8080,
    this.webSocketPort = 8080, // WebSocket is on same port as HTTP
    String scheme = 'http',
    this.pinnedFingerprint,
    this.authToken,
    this.refreshAuthToken,
    Duration? webSocketHeartbeatInterval,
    Duration? webSocketHeartbeatTimeout,
    Duration? requestTimeout,
    Duration? connectionTimeout,
    http.Client? httpClient,
    bool autoConnectWebSocket = true,
  }) : scheme = _normalizeScheme(scheme),
       isRemoteHost = TailnetDetector.isTailscaleEndpoint(serverHost),
       webSocketHeartbeatInterval =
           webSocketHeartbeatInterval ?? const Duration(seconds: 15),
       // Remote/LAN-aware timeout defaults. When the caller passes an explicit
       // value it always wins (tests, advanced config); otherwise we pick the
       // ceiling appropriate to the host's reachability tier. LAN behaviour is
       // byte-for-byte unchanged from before this feature.
       webSocketHeartbeatTimeout =
           webSocketHeartbeatTimeout ??
           (TailnetDetector.isTailscaleEndpoint(serverHost)
               ? _remoteHeartbeatTimeout
               : _lanHeartbeatTimeout),
       requestTimeout =
           requestTimeout ??
           (TailnetDetector.isTailscaleEndpoint(serverHost)
               ? _remoteRequestTimeout
               : _lanRequestTimeout),
       _http = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null {
    // Initialize persistent HTTP client with connection pooling
    _httpClient = HttpClient()
      ..idleTimeout = const Duration(seconds: 30)
      ..connectionTimeout =
          connectionTimeout ??
          (isRemoteHost ? _remoteConnectionTimeout : _lanConnectionTimeout);
    // Connect WebSocket immediately. Tests that only exercise the HTTP
    // request/response path can disable this to avoid background timers
    // and reconnect storms.
    if (autoConnectWebSocket) {
      connect();
    }
  }

  /// Validate + lower-case the URL scheme. Only `http` and `https` are
  /// transports this backend speaks; anything else is a caller bug and throws
  /// (no silent coercion to a default that would mask the mistake).
  static String _normalizeScheme(String scheme) {
    final lowered = scheme.trim().toLowerCase();
    if (lowered == 'http' || lowered == 'https') {
      return lowered;
    }
    throw ArgumentError.value(
      scheme,
      'scheme',
      "NetworkBackend scheme must be 'http' or 'https'",
    );
  }

  /// WebSocket scheme derived from [scheme]: `https` ⇒ `wss`, `http` ⇒ `ws`.
  String get _wsScheme => scheme == 'https' ? 'wss' : 'ws';

  /// Build a REST API URI for [endpoint] (the path segment after `/api/`),
  /// honouring the configured [scheme]. The [endpoint] may itself carry an
  /// inline query string (e.g. `'calibration/darks/7?deleteFile=true'`); any
  /// inline params are preserved and the optional [queryParameters] are merged
  /// on top (explicit params win on key collision). Every REST URI is built
  /// here, so the scheme is decided in one place.
  Uri _apiUri(String endpoint, [Map<String, String>? queryParameters]) {
    final base = buildSkotiqServerUri(
      scheme: scheme,
      host: serverHost,
      port: serverPort,
      pathAndQuery: '/api/$endpoint',
    );
    if (queryParameters == null || queryParameters.isEmpty) {
      return base;
    }
    return base.replace(
      queryParameters: {...base.queryParameters, ...queryParameters},
    );
  }

  /// Build a WebSocket URI for [path] (e.g. `/events`, `/ws/live-view`),
  /// honouring the derived [_wsScheme]. [queryParameters] are merged on.
  Uri _wsUri(String path, [Map<String, String>? queryParameters]) {
    return Uri(
      scheme: _wsScheme,
      host: serverHost,
      port: webSocketPort,
      path: path,
      queryParameters: (queryParameters == null || queryParameters.isEmpty)
          ? null
          : queryParameters,
    );
  }

  bool get dispatchPluginNodesLocally => false;

  /// Stream of connection state changes
  Stream<BackendConnectionState> get connectionStateStream =>
      _connectionStateController.stream;

  /// Current connection state
  BackendConnectionState get connectionState => _connectionState;

  /// True when the host definitively rejected the current credentials —
  /// an HTTP `403 Invalid authentication token` or a refused WebSocket
  /// upgrade — and further requests are being refused locally instead of
  /// hammering the server's auth-failure rate limiter. Callers (remote
  /// session sync, background pollers) should treat this as a terminal
  /// state — surface "re-pair required" rather than scheduling retries.
  /// Cleared when the token is swapped or an explicit reconnect is
  /// requested.
  bool get isAuthTokenRejected => _authRejected;

  /// Stream of WebSocket ping/pong round-trip times. Emits a [Duration]
  /// every time the server's pong is received after we send a ping.
  /// Subscribers (e.g. the mobile NetworkStatusIndicator) use this to
  /// surface latency to the operator. Hidden when disconnected — when
  /// the heartbeat stops firing, no new values are emitted.
  Stream<Duration> get latencyStream => _latencyController.stream;

  /// The most recent ping/pong round-trip time, or null if none has been
  /// observed yet (initial connect, or post-disconnect).
  Duration? get lastLatency => _lastLatency;

  /// Monotonic sequence number of the last event we accepted from
  /// the server. Null before any seq-bearing event has been received (e.g.
  /// fresh connection, or talking to a an earlier build server).
  ///
  /// Used together with [serverInstanceId] to build the `?since=N&instance=
  /// UUID` query string on a reconnect so the server can replay events we
  /// missed during the disconnect window.
  int? get lastSeenEventSeq => _lastSeenEventSeq;

  /// UUID identifying the server instance we're currently attached
  /// to. Null until the first event (or `/api/info` response) discloses
  /// it. Changes when the server restarts; observing a change is the
  /// trigger to invalidate [lastSeenEventSeq].
  String? get serverInstanceId => _serverInstanceId;

  void setCollaborationIdentity({
    required String viewerId,
    required String deviceName,
    required String displayName,
  }) => _setCollaborationIdentity(
    viewerId: viewerId,
    deviceName: deviceName,
    displayName: displayName,
  );

  Future<void> reconnectNow() => _reconnectNow();

  Future<bool> testConnection() => _testConnection();

  Future<void> connect() => _connect();

  void pauseWebSocketHeartbeatForAppLifecycle() =>
      _pauseWebSocketHeartbeatForAppLifecycle();

  void resumeWebSocketHeartbeatForAppLifecycle() =>
      _resumeWebSocketHeartbeatForAppLifecycle();

  Future<void> disconnect() => _disconnect();

  void dispose() => _dispose();

  Stream<SkotiqEvent> get eventStream => _eventController.stream;

  /// Implemented by the device-operations mixin. Keeping this hook on the
  /// transport base lets WebSocket equipment events invalidate discovery
  /// results without coupling the transport layer to device API details.
  void invalidateDeviceCache();

  /// Stream of push notifications received from the desktop server.
  ///
  /// Each map contains 'title', 'body', 'priority', 'eventType', 'category',
  /// and 'timestamp' fields as sent by PushNotificationService.
  Stream<Map<String, dynamic>> get pushNotificationStream =>
      _pushNotificationController.stream;
}

class NetworkBackend extends _NetworkBackendTransport
    with
        _NetworkBackendRemoteOperations,
        _NetworkBackendRemoteCalibrationCatalogOperations,
        _NetworkBackendRemoteDatabasePluginOperations,
        _NetworkBackendRemoteLogOperations,
        _NetworkBackendRemoteLiveViewOperations,
        _NetworkBackendDomainOperations,
        _NetworkBackendSessionScienceOperations,
        _NetworkBackendPlanningAccessoryOperations,
        _NetworkBackendDeviceOperations,
        _NetworkBackendGuidingOperations,
        _NetworkBackendSequencerOperations,
        _NetworkBackendReplayDebugOperations,
        _NetworkBackendStackingOperations,
        _NetworkBackendPostSessionOperations,
        _NetworkBackendImagingProfileOperations,
        _NetworkBackendPlanningDataOperations,
        _NetworkBackendObservingListOperations,
        _NetworkBackendDepthLockOperations
    implements
        SkotiqBackend,
        EnvironmentalStatusBackend,
        DomeStatusBackend {
  static const _requestIdHeader = _NetworkBackendTransport._requestIdHeader;

  NetworkBackend({
    required super.serverHost,
    super.serverPort,
    super.webSocketPort,
    super.scheme,
    super.pinnedFingerprint,
    super.authToken,
    super.refreshAuthToken,
    super.webSocketHeartbeatInterval,
    super.webSocketHeartbeatTimeout,
    super.requestTimeout,
    super.connectionTimeout,
    super.httpClient,
    super.autoConnectWebSocket,
  });
}
