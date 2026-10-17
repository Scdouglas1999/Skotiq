// Shared connection-session state plus the WebSocket connection-state
// notification machine. This base mixin owns every field the connection
// flow shares (the connected server, discovery/error/status flags, the
// relay tunnel, the pairing UI navigator, the push registration) so the
// sibling mixins — discovery/pairing ops and (re)connect/disconnect ops —
// can constrain `on` it and read/write the same state.
//
// The cross-group operations the notification machine and its siblings
// invoke are declared abstract here so the mixins type-check independently
// of application order; each is implemented in exactly one sibling mixin:
//   * [_pairWithServer] — discovery/pairing ops
//   * [_connectToServer], [_connectViaRelay], [_closeActiveRelayTunnel] —
//     (re)connect/disconnect ops
part of '../main.dart';

mixin _MobileConnectionState on ConsumerState<SkotiqMobileApp> {
  /// Navigator for the connection-screen [MaterialApp]. Dialogs and the QR
  /// scanner must use this context — [State.context] sits *above* that
  /// [MaterialApp], so [Navigator.of] on it returns null in release builds.
  final GlobalKey<NavigatorState> _connectionNavigatorKey =
      GlobalKey<NavigatorState>();

  DiscoveredServer? _connectedServer;
  // v4 couch-grade remote: when connected via a self-hosted relay, this holds
  // the loopback tunnel that the whole session rides on. It MUST outlive the
  // backend connect (it is the transport) and be torn down whenever the
  // session ends. Null for direct LAN/Tailscale connections.
  RelayTunnelClient? _activeRelayTunnel;
  bool _isDiscovering = false;
  String? _error;
  String _statusMessage = '';
  final TextEditingController _ipController = TextEditingController(text: '');
  final TextEditingController _accessTokenController = TextEditingController(
    text: '',
  );
  bool _showManualEntry = false;
  bool _skippedConnection = false;
  int _connectionOperationGeneration = 0;
  // Tokens are sensitive — default to obscured. Trailing icon toggles for
  // operators who need to verify the value during pairing.
  bool _accessTokenVisible = false;

  // Liveness comes from the WebSocket heartbeat, not an HTTP poll. The
  // NetworkBackend runs the ping/pong and a backoff reconnector; this state
  // machine translates its connection-state stream into UI banners and a
  // final tear-down once the grace expires.
  StreamSubscription<BackendConnectionState>? _connectionStateSubscription;
  Timer? _disconnectGraceTimer;
  bool _connectionStale = false;

  /// Re-arms [_autoConnect] after the grace period has declared a session
  /// dead, so a phone that blips off the network overnight is reconnected by
  /// morning instead of sitting on "Please reconnect" until relaunched. Null
  /// whenever no retry is pending.
  Timer? _lostSessionRetryTimer;

  /// Consecutive automatic retries since the session was declared lost. Drives
  /// the backoff and resets on any successful connect.
  int _lostSessionRetryAttempt = 0;

  /// The server whose session we just lost, captured before [_connectedServer]
  /// is cleared. Retries re-dial *this* endpoint (and its saved token) rather
  /// than re-running generic discovery: discovery can legitimately resolve the
  /// same host by a different address (on an emulator, `10.0.2.2` instead of the
  /// paired `192.168.1.20`), and the token is keyed to the paired one — so a
  /// discovery-based retry dropped an already-paired user onto the "enter a
  /// pairing code" dialog.
  DiscoveredServer? _lostSessionServer;

  /// Phase E (iOS): registers this device's APNs token with the paired desktop
  /// for cellular critical-alert delivery. Lazily created on first use so the
  /// MethodChannel handler is only attached when we actually have a session to
  /// register against. Inert on non-iOS.
  PushRegistrationService? _pushRegistration;

  bool _checkpointChecked = false;

  /// How long the WebSocket can stay disconnected before we declare the
  /// session dead and route the user back to the connection screen. The
  /// backend's own reconnector backs off up to 30 s; we wait the full
  /// grace before kicking the user out so transient blips don't drop a
  /// running session.
  static const Duration _connectionGracePeriod = Duration(seconds: 30);

  /// Build context inside the connection [MaterialApp] tree (has Navigator,
  /// Theme, and localizations). Returns null before the first frame.
  BuildContext? get _connectionUiContext =>
      _connectionNavigatorKey.currentContext;

  bool _isCurrentConnectionOperation(int generation) =>
      mounted && generation == _connectionOperationGeneration;

  // Cross-group operations, implemented in the sibling mixins

  /// Implemented by the (re)connect/disconnect ops mixin. The notification
  /// machine drops the loopback tunnel when a session dies; the discovery
  /// and reconnect flows tear it down on their own teardown paths.
  Future<void> _closeActiveRelayTunnel();

  /// Implemented by the discovery / pairing ops mixin. The notification
  /// machine re-arms it after a lost session so the app re-attaches on its own
  /// once the network comes back, exactly as it does on a cold start.
  Future<void> _autoConnect();

  /// Implemented by the (re)connect/disconnect ops mixin. The discovery /
  /// pairing flows hand a resolved [DiscoveredServer] to it.
  Future<void> _connectToServer(DiscoveredServer server);

  /// Implemented by the (re)connect/disconnect ops mixin. The relay-connect
  /// dialog (discovery group) routes through it. The concrete override adds
  /// the saved-relay-only `presetAuthToken` / `savedServerDisplayName`
  /// parameters, which the reconnect flow supplies for itself; this contract
  /// only declares the parameters crossed from the discovery group.
  Future<void> _connectViaRelay({
    required String relayUrl,
    required String applianceId,
    bool allowInsecureTls = false,
  });

  /// Implemented by the discovery / pairing ops mixin. The reconnect flows
  /// invoke it when a fetched server requires a code. The concrete override
  /// adds the `initialCode` prefill parameter; this contract declares only
  /// the parameters the reconnect group supplies.
  Future<String?> _pairWithServer({
    required String host,
    required int port,
    String scheme = 'http',
    String? pinnedFingerprint,
  });

  void _stopConnectionMonitor() {
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    _disconnectGraceTimer?.cancel();
    _disconnectGraceTimer = null;
    // Any pending auto-retry belongs to the session we are tearing down. The
    // lost-session path re-arms it immediately afterwards; every other caller
    // (a fresh connect, dispose) genuinely wants it gone.
    _lostSessionRetryTimer?.cancel();
    _lostSessionRetryTimer = null;
    if (_connectionStale) {
      _connectionStale = false;
      // Clear the global banner so a re-connect doesn't briefly show stale.
      // Skip the write if the State has already been unmounted — the
      // provider scope is gone and the banner will be rebuilt fresh.
      if (mounted) {
        ref.read(connectionStaleProvider.notifier).state = false;
      }
    }
  }

  /// Re-arm the connect flow after the session was declared lost.
  ///
  /// Prefers re-dialling [_lostSessionServer] — the exact endpoint we were
  /// paired to, token included — and only falls back to [_autoConnect]'s
  /// discovery when we never had one. Both routes reuse the existing connect
  /// paths, so there is no second, divergent reconnect implementation to keep
  /// in sync.
  void _scheduleLostSessionRetry() {
    if (!mounted) return;
    _lostSessionRetryTimer?.cancel();
    final delay = lostSessionRetryDelay(_lostSessionRetryAttempt);
    _lostSessionRetryAttempt++;
    _lostSessionRetryTimer = Timer(delay, () async {
      _lostSessionRetryTimer = null;
      if (!mounted) return;
      // Never fight the operator: if they already reconnected, opened manual
      // entry, chose to browse the UI offline, or a connect is in flight, sit
      // this round out and look again later.
      if (_connectedServer != null ||
          _isDiscovering ||
          _showManualEntry ||
          _skippedConnection) {
        if (_connectedServer == null && !_skippedConnection) {
          _scheduleLostSessionRetry();
        }
        return;
      }
      final target = _lostSessionServer;
      if (target != null) {
        await _connectToServer(target);
      } else {
        await _autoConnect();
      }
      if (!mounted) return;
      if (_connectedServer == null && !_skippedConnection) {
        _scheduleLostSessionRetry();
      }
    });
  }

  void _setNetworkHeartbeatPaused(bool paused) {
    final backend = ref.read(backendProvider);
    if (backend is! NetworkBackend) {
      return;
    }
    if (paused) {
      backend.pauseWebSocketHeartbeatForAppLifecycle();
    } else {
      backend.resumeWebSocketHeartbeatForAppLifecycle();
    }
  }

  /// Register this device's push token (APNs on iOS, FCM on Android) with
  /// the now-connected desktop so critical alerts can reach a backgrounded
  /// or off-LAN phone. On Android builds without a provisioned Firebase
  /// project the native side reports `fcm_unconfigured` and the service
  /// stays dormant.
  ///
  /// Gated three ways so it no-ops cleanly off the happy path:
  ///   * not iOS/Android — `PushRegistrationService` also short-circuits
  ///     internally, so the channel is never touched and no
  ///     MissingPluginException can fire;
  ///   * not a [NetworkBackend] — local/FFI session, nothing to register with;
  ///   * not paired — empty deviceId, the service skips the POST.
  ///
  /// Best-effort: the service swallows and logs all network/host errors, so a
  /// failure here never disturbs the live session.
  Future<void> _registerPushToken() async {
    if (!Platform.isIOS && !Platform.isAndroid) {
      return;
    }
    final backend = ref.read(backendProvider);
    if (backend is! NetworkBackend) {
      return;
    }
    final deviceId = await MobilePairingService.deviceId();
    final service = _pushRegistration ??= PushRegistrationService();
    await service.ensureRegistered(backend: backend, deviceId: deviceId);
  }

  void _startConnectionMonitor() {
    _stopConnectionMonitor();
    // A live session again: the next drop starts its backoff from the top.
    _lostSessionRetryAttempt = 0;
    final backend = ref.read(backendProvider);
    if (backend is! NetworkBackend) {
      // Only NetworkBackend exposes the WS heartbeat. Other backends
      // either run locally (FfiBackend) or are explicitly disconnected.
      return;
    }

    _connectionStateSubscription = backend.connectionStateStream.listen((
      state,
    ) {
      if (!mounted) return;

      switch (state) {
        case BackendConnectionState.connected:
          _disconnectGraceTimer?.cancel();
          _disconnectGraceTimer = null;
          if (_connectionStale) {
            _connectionStale = false;
            ref.read(connectionStaleProvider.notifier).state = false;
            setState(() {
              _statusMessage = '';
            });
          }
          break;

        case BackendConnectionState.connecting:
          // First-time handshake in flight. Don't show the stale banner
          // yet — there was no prior session to go stale — but reset
          // the disconnect-grace timer so a slow first handshake doesn't
          // trigger the post-disconnect tear-down path.
          _disconnectGraceTimer?.cancel();
          _disconnectGraceTimer = null;
          break;

        case BackendConnectionState.error:
          // Terminal failure (e.g. version mismatch). The backend has
          // stopped retrying so we mirror the disconnected branch for
          // the stale-banner UX but skip the grace timer — there's no
          // point waiting for an automatic recovery that will never
          // happen.
          if (!_connectionStale) {
            _connectionStale = true;
            ref.read(connectionStaleProvider.notifier).state = true;
          }
          break;

        case BackendConnectionState.reconnecting:
        case BackendConnectionState.disconnected:
          // Show the stale-state banner immediately but give the backend
          // a chance to reconnect before we tear the session down.
          if (!_connectionStale) {
            _connectionStale = true;
            ref.read(connectionStaleProvider.notifier).state = true;
          }
          _disconnectGraceTimer ??= Timer(_connectionGracePeriod, () async {
            if (!mounted) return;
            final current = ref.read(backendProvider);
            if (current is! NetworkBackend ||
                current.connectionState == BackendConnectionState.connected) {
              return;
            }
            developer.log(
              'WebSocket disconnected for ${_connectionGracePeriod.inSeconds}s — declaring connection lost',
              name: 'Connection',
              level: 1000,
            );
            _stopConnectionMonitor();
            // Remember who we were talking to, so the retries below re-dial
            // that exact endpoint and token instead of re-running discovery.
            //
            // This MUST happen before the `disconnect()` below: that swaps in a
            // DisconnectedBackend, and the `backendProvider` listener in the
            // build method clears `_connectedServer` the moment it sees one. A
            // capture placed after the await therefore reads null, and every
            // retry silently falls back to discovery — which on an emulator
            // resolves the same host by a different address (10.0.2.2 rather
            // than the paired 192.168.1.20) and re-prompts an already-paired
            // user for a pairing code.
            _lostSessionServer = _connectedServer ?? _lostSessionServer;
            // Drop cached APNs registration state: the next connect may land on
            // a different desktop, and APNs hands back the same token across
            // servers. Without this the target-keyed gate in the service is the
            // only thing forcing a re-POST; resetting here is belt-and-braces
            // so a re-pair can never be assumed already-registered.
            _pushRegistration?.reset();
            try {
              await ref.read(backendProvider.notifier).disconnect();
            } catch (e, stackTrace) {
              developer.log(
                'Could not detach the lost backend session: $e',
                name: 'Connection',
                level: 1000,
                error: e,
                stackTrace: stackTrace,
              );
              if (mounted) {
                setState(() {
                  _error =
                      'Connection was lost, but local sequence startup '
                      'is still settling. Wait a moment, then disconnect.';
                });
              }
              return;
            }
            // v4 relay: the session is dead — drop the loopback tunnel too.
            unawaited(_closeActiveRelayTunnel());
            ref.read(connectionStaleProvider.notifier).state = false;
            // Audit reset the once-per-lifetime checkpoint flag so
            // a future reconnect re-runs the resume dialog if the server
            // now has a fresh interrupted sequence to recover. Without
            // this, dropping mid-session and reconnecting in the same
            // app lifecycle would silently skip the recovery prompt.
            _checkpointChecked = false;
            setState(() {
              _connectedServer = null;
              _isDiscovering = false;
              _connectionStale = false;
              _error =
                  'Connection to server lost. Retrying automatically — '
                  'or reconnect below.';
              _statusMessage = '';
            });
            // Keep trying on our own. Without this the app parked on this
            // screen forever: restoring WiFi four minutes later left it still
            // showing "Please reconnect" even though the saved server and
            // token were both still valid.
            _scheduleLostSessionRetry();
          });
          break;
      }
    });
  }
}
