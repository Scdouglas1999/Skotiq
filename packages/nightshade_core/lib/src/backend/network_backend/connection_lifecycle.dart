part of '../network_backend.dart';

extension _NetworkBackendConnectionLifecycle on _NetworkBackendTransport {
  /// Identity broadcast on every `collaboration.join` frame sent
  /// after the WS handshake succeeds. Call this BEFORE [connect] (or
  /// before the auto-reconnect timer fires) so the very first join after
  /// the handshake carries the right values. Subsequent reconnects reuse
  /// whatever was last set here. The `viewerId` is derived from the
  /// authenticated token (typically `computeServerFingerprint(authToken)`
  /// — the same digest the server stamps on the socket context). When
  /// authentication is disabled and the caller has no token, pass any
  /// stable per-device identifier; the server will accept it because the
  /// "authenticated identity" override is null.
  ///
  /// `displayName` is what appears in the host UI's viewer slot list. The
  /// mobile companion sets it to `"PLATFORM · MODEL"` by default.
  void _setCollaborationIdentity({
    required String viewerId,
    required String deviceName,
    required String displayName,
  }) {
    _collaborationViewerId = viewerId;
    _collaborationDeviceName = deviceName;
    _collaborationDisplayName = displayName;
  }

  /// Manually trigger an immediate WebSocket reconnection attempt.
  ///
  /// Cancels any pending exponential-backoff reconnect timer and calls
  /// [connect] right away. Used by the mobile UI's "Reconnect now" button
  /// so the operator doesn't have to wait the full backoff window before
  /// retrying a failed connection.
  ///
  /// The reconnect attempt counter is reset so the next failure starts
  /// fresh from a 1s backoff (rather than continuing the previous chain).
  Future<void> _reconnectNow() async {
    if (_disposed) {
      return;
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    // A manual reconnect is the operator's way out of a latched auth
    // rejection (after re-pairing / swapping the token) — clear the
    // terminal flags so this attempt actually reaches the wire.
    _authRejected = false;
    _rejectedAuthToken = null;
    developer.log(
      '[NetworkBackend] Manual reconnect requested',
      name: 'NetworkBackend',
      level: 800,
    );
    await connect();
  }

  /// Update connection state and notify listeners
  void _updateConnectionState(BackendConnectionState newState) {
    if (_connectionState != newState) {
      _connectionState = newState;
      _connectionStateController.add(newState);
      developer.log(
        '[NetworkBackend] Connection state changed to: $newState',
        name: 'NetworkBackend',
        level: 800,
      );
    }
  }

  /// Test connectivity to server
  Future<bool> _testConnection() async {
    try {
      final compatibility = await _checkServerCompatibility();
      if (!compatibility.isCompatible) {
        developer.log(
          'Connection rejected: ${compatibility.message}',
          name: 'NetworkBackend',
          level: 900,
        );
        return false;
      }

      return true;
    } catch (e) {
      developer.log(
        'Connection test failed: $e',
        name: 'NetworkBackend',
        level: 900,
        error: e,
      );
      return false;
    }
  }

  Future<RemoteApiCompatibilityResult> _checkServerCompatibility() async {
    final uri = _apiUri('info');
    final headers = <String, String>{
      RemoteApiCompatibility.apiVersionHeader: RemoteApiCompatibility
          .clientApiVersion
          .format(),
      _NetworkBackendTransport._requestIdHeader: _nextRequestId('compat'),
    };
    // The handshake probe gets a fixed short ceiling regardless of the
    // request-timeout tuning: it runs before we commit to the connection, so a
    // server that can't answer /api/info promptly should surface as
    // unreachable rather than hang the connect UI. Remote tailnet paths get a
    // little more slack than the LAN 3 s since a cold DERP route can add a
    // round-trip or two before the first byte.
    final probeTimeout = isRemoteHost
        ? const Duration(seconds: 6)
        : const Duration(seconds: 3);
    final response = await _http
        .get(uri, headers: headers)
        .timeout(probeTimeout);
    if (response.statusCode != 200) {
      throw HttpException(
        'GET /api/info failed with HTTP ${response.statusCode}',
        uri: uri,
      );
    }

    final info = jsonDecode(response.body) as Map<String, dynamic>;
    // Fail-closed fingerprint pinning. When the caller pinned a fingerprint
    // (paired rig), the server MUST advertise the same one or the connection is
    // refused outright — a mismatch means a different server than the one the
    // operator paired with (MITM, stale QR, or a re-keyed host). Throwing here
    // propagates to [connect], which surfaces it as a terminal
    // [BackendConnectionState.error] rather than spinning on reconnect.
    _verifyPinnedFingerprint(info['fingerprint']);
    // Surface the server instance UUID so the WS connect can decide
    // whether the seq cursor we cached on the previous attachment is still
    // valid against the server we're about to talk to. If the field is
    // missing the server pre-dates this change and we just skip replay (live-only).
    final advertisedInstance = info['serverInstanceId'];
    if (advertisedInstance is String && advertisedInstance.isNotEmpty) {
      _reconcileInstanceFromInfo(advertisedInstance);
    }
    return RemoteApiCompatibility.check(
      info['apiVersion'] as String? ?? info['version'] as String?,
    );
  }

  /// Enforce the pinned-fingerprint contract against the value the server
  /// advertised in its `/api/info` envelope. No-op when [pinnedFingerprint] is
  /// null/empty (pinning disabled). Throws a typed connection error on
  /// mismatch — including when the client pinned a fingerprint but the server
  /// advertised none (a downgrade an attacker could otherwise exploit).
  void _verifyPinnedFingerprint(Object? advertised) {
    final pinned = pinnedFingerprint;
    if (pinned == null || pinned.isEmpty) {
      return;
    }
    final serverFp = advertised is String ? advertised.trim() : '';
    if (serverFp.isEmpty) {
      throw dart_error.ServerIdentityMismatchError(
        expectedFingerprint: pinned,
        actualFingerprint: null,
        message:
            'Server identity could not be verified: this rig advertises no '
            'fingerprint but the saved connection is pinned to '
            '"$pinned". Refusing to connect.',
        userMessage:
            'This server could not prove its identity. Refusing to connect — '
            're-pair if you intentionally changed servers.',
      );
    }
    // Fingerprints are compared case-insensitively because the QR / mDNS / info
    // representations are all hex and may differ in case across producers; the
    // value itself is the same digest.
    if (serverFp.toLowerCase() != pinned.toLowerCase()) {
      throw dart_error.ServerIdentityMismatchError(
        expectedFingerprint: pinned,
        actualFingerprint: serverFp,
        message:
            'Server identity mismatch: expected fingerprint "$pinned" but the '
            'host at $serverHost advertised "$serverFp". Refusing to connect — '
            're-pair if you intentionally changed servers.',
        userMessage:
            'This server\'s identity does not match the one you paired with. '
            'Refusing to connect — re-pair if you intentionally changed '
            'servers.',
      );
    }
  }

  /// Compare the instance UUID advertised by `/api/info` against the
  /// one we attached to on the previous connect. If they differ, the server
  /// was restarted between our connection attempts and our cached seq
  /// cursor refers to a counter that no longer exists. Reset it so the
  /// next WS connect omits `?since=` and starts fresh.
  ///
  /// On the FIRST `/api/info` call (no previous instance recorded) we just
  /// remember the value; on later calls we diff against the cached one.
  void _reconcileInstanceFromInfo(String advertisedInstance) {
    final previous = _previousServerInstanceId;
    if (previous != null && previous != advertisedInstance) {
      developer.log(
        '[NetworkBackend] Server instance changed (old=$previous, '
        'new=$advertisedInstance); cached event seq invalidated.',
        name: 'NetworkBackend',
        level: 900,
      );
      _lastSeenEventSeq = null;
      if (!_eventController.isClosed) {
        _eventController.add(
          NightshadeEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            category: EventCategory.system,
            eventType: 'BackendReconnected',
            severity: EventSeverity.info,
            data: {
              'message': 'Server instance changed; cached state invalidated',
              'previousInstance': previous,
              'currentInstance': advertisedInstance,
            },
          ),
        );
      }
    }
    _serverInstanceId = advertisedInstance;
    _previousServerInstanceId = advertisedInstance;
  }

  /// Initialize the WebSocket connection for real-time events
  Future<void> _connect() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (_disposed || _disconnecting) {
      return;
    }
    // A latched auth rejection is terminal for these credentials: the
    // host already told us the token is invalid, so every retry just
    // feeds its per-IP failure limiter toward another `429` lockout.
    // Stay in `error` until [reconnectNow] clears the latch (operator
    // re-paired / swapped token) or a fresh token arrives via
    // refreshAuthToken.
    if (_authRejected) {
      _enterAuthRejectedState();
      return;
    }

    // Set once the upgrade carries a freshly minted one-shot ticket. The
    // mint is itself an authenticated request, so its success proves the
    // bearer was accepted moments ago; see the refusal handling below.
    var upgradeUsedTicket = false;
    try {
      _stopWebSocketHeartbeat();
      // Distinguish "first-time connect" from "reconnecting after
      // a previously-healthy session" so the UI can render distinct
      // messaging. The latch flips on the first successful handshake
      // and stays true for the lifetime of this backend instance — a
      // dispose+recreate (via BackendNotifier swap) starts the cycle
      // over, which is the intended UX for "I changed servers".
      _updateConnectionState(
        _hasEverConnected
            ? BackendConnectionState.reconnecting
            : BackendConnectionState.connecting,
      );

      final compatibility = await _checkServerCompatibility();
      if (!compatibility.isCompatible) {
        developer.log(
          'Connection rejected: ${compatibility.message}',
          name: 'NetworkBackend',
          level: 900,
        );
        // Version mismatch is a terminal condition — the caller must
        // upgrade or downgrade one side before retrying. Emit `error`
        // rather than `disconnected` so the UI surfaces this as an
        // unrecoverable failure (no spinning "reconnecting…" forever).
        _updateConnectionState(BackendConnectionState.error);
        return;
      }

      final queryParameters = <String, String>{};
      if (authToken != null && authToken!.isNotEmpty) {
        // Prefer the one-shot WS ticket so the bearer token stays out of the
        // WebSocket URL (logs/proxies/history). Falls back to ?token= for
        // servers that predate the ticket endpoint.
        final wsTicket = await _mintWsTicket();
        // The ticket mint is itself an authenticated request — if it just
        // latched a rejection (dead token → 403), don't compound it with
        // a doomed upgrade attempt.
        if (_authRejected) {
          _enterAuthRejectedState();
          return;
        }
        if (wsTicket != null) {
          queryParameters['ticket'] = wsTicket;
          upgradeUsedTicket = true;
        } else {
          queryParameters['token'] = authToken!;
        }
      }
      queryParameters['apiVersion'] = RemoteApiCompatibility.clientApiVersion
          .format();
      // If we've previously attached to this server instance and have
      // a seq cursor to ask replay from, include both. The server-side
      // /events handler treats omitting either parameter as "fresh
      // subscribe, live-only" — which is also what we want on the very
      // first connect (no cursor yet) or after an instance change reset
      // the cursor to null.
      if (_lastSeenEventSeq != null && _serverInstanceId != null) {
        queryParameters['since'] = _lastSeenEventSeq!.toString();
        queryParameters['instance'] = _serverInstanceId!;
      }
      final wsUri = _wsUri('/events', queryParameters);
      _wsChannel = IOWebSocketChannel.connect(wsUri);
      _lastWebSocketMessageAt = DateTime.now();

      // Cancel any existing subscription before creating a new one
      await _wsSubscription?.cancel();
      _wsSubscription = _wsChannel!.stream.listen(
        (message) {
          try {
            _lastWebSocketMessageAt = DateTime.now();
            final json = jsonDecode(message as String) as Map<String, dynamic>;
            final type = json['type'] as String?;

            if (type == 'pong') {
              // Compute round-trip latency from the last ping we sent.
              // The server replies to every ping with one pong (see
              // [_startWebSocketHeartbeat] and the matching server-side
              // handler), so the most recent _pendingPingSentAt is the
              // right reference point.
              final sentAt = _pendingPingSentAt;
              if (sentAt != null) {
                final latency = DateTime.now().difference(sentAt);
                _lastLatency = latency;
                _pendingPingSentAt = null;
                if (!_latencyController.isClosed) {
                  _latencyController.add(latency);
                }
              }
              return;
            }

            if (type == 'ping') {
              _wsChannel?.sink.add(
                jsonEncode({
                  'type': 'pong',
                  'timestamp': DateTime.now().toUtc().toIso8601String(),
                }),
              );
              return;
            }

            if (type == 'collaboration_state') {
              return;
            }

            // Route push notifications to the dedicated stream
            if (type == 'push_notification') {
              _pushNotificationController.add(json);
              return;
            }

            // Server-driven advisory that the seq cursor we sent on
            // the upgrade request is no longer usable (instance changed,
            // or we asked for an event the ring buffer has already
            // evicted). The socket stays open — only the replay request
            // failed — so we drop our cached cursor, adopt whatever the
            // server's current instance is, and synthesize a
            // BackendReconnected event so downstream providers refetch
            // their cached state.
            if (type == 'resync_required') {
              final reason = json['reason'] as String? ?? 'unknown';
              final currentSeq = json['currentSeq'];
              final currentInstance = json['currentInstance'] as String?;
              developer.log(
                '[NetworkBackend] resync_required: reason=$reason '
                'currentSeq=$currentSeq currentInstance=$currentInstance',
                name: 'NetworkBackend',
                level: 900,
              );
              _lastSeenEventSeq = null;
              if (currentInstance != null && currentInstance.isNotEmpty) {
                _serverInstanceId = currentInstance;
                _previousServerInstanceId = currentInstance;
              }
              _eventController.add(
                NightshadeEvent(
                  timestamp: DateTime.now().millisecondsSinceEpoch,
                  category: EventCategory.system,
                  eventType: 'BackendReconnected',
                  severity: EventSeverity.info,
                  data: {
                    'message': 'Server requested resync',
                    'reason': reason,
                    if (currentSeq != null) 'currentSeq': currentSeq,
                    if (currentInstance != null)
                      'currentInstance': currentInstance,
                  },
                ),
              );
              return;
            }

            final event = _eventFromJson(json);
            _trackEventSeq(event, isReplay: json['replay'] == true);
            _handleEventSideEffects(event);
            _eventController.add(event);

            // Route polar alignment events to the dedicated stream
            if (event.category == EventCategory.polarAlignment) {
              _polarAlignController.add(event.data);
            }
          } catch (e) {
            developer.log(
              'Error parsing WebSocket message: $e',
              name: 'NetworkBackend',
              level: 900,
              error: e,
            );
          }
        },
        onError: (error) {
          developer.log(
            'WebSocket error: $error',
            name: 'NetworkBackend',
            level: 1000,
            error: error,
          );
          _eventController.addError(error);
          _handleConnectionFailure();
        },
        onDone: () {
          developer.log(
            'WebSocket connection closed',
            name: 'NetworkBackend',
            level: 900,
          );
          _handleConnectionFailure();
        },
      );

      // `IOWebSocketChannel.connect` returns before the HTTP upgrade
      // completes; `ready` resolves only when the server accepts it and
      // throws the refusal otherwise (401/403 auth rejection, 429 auth
      // lockout). Awaiting it is what makes `connected` mean the
      // handshake actually succeeded — previously we marked the backend
      // connected while the upgrade was still in flight, so a refused
      // upgrade surfaced as a connect → hydration fan-out → disconnect
      // thrash loop on every retry.
      await _wsChannel!.ready.timeout(requestTimeout);

      // Connection successful
      _updateConnectionState(BackendConnectionState.connected);
      _hasEverConnected = true;
      final wasReconnect = _reconnectAttempt > 0;
      _reconnectAttempt = 0; // Reset reconnect counter on success
      developer.log(
        '[NetworkBackend] WebSocket connected successfully',
        name: 'NetworkBackend',
        level: 800,
      );
      _startWebSocketHeartbeat();

      // Identify ourselves as a collaboration viewer immediately
      // after the handshake completes (auth is already validated by the
      // upgrade gate above). The server may override `viewerId` with the
      // authenticated principal's digest — we still send a value
      // so legacy hosts that lack the override keep working unchanged.
      _sendCollaborationJoin();

      // After a reconnect (not the initial connect), emit a synthetic event
      // so downstream providers know the connection is back and can refresh
      // their cached state. Events that occurred while disconnected are lost,
      // so UI components watching this stream should re-fetch latest state.
      if (wasReconnect) {
        _eventController.add(
          NightshadeEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            category: EventCategory.system,
            eventType: 'BackendReconnected',
            severity: EventSeverity.info,
            data: const {'message': 'WebSocket reconnected'},
          ),
        );
      }
    } on dart_error.ServerIdentityMismatchError catch (e) {
      // Fail-closed terminal error: the host advertised a fingerprint that does
      // not match the one we pinned (or advertised none). Do NOT schedule a
      // reconnect — spinning on a host whose identity we cannot verify is
      // exactly the man-in-the-middle window the pin exists to close. Surface
      // an unrecoverable `error` state (mirroring the version-incompatibility
      // branch above) so the operator sees a clear identity mismatch instead
      // of a perpetual "reconnecting…".
      developer.log(
        '[NetworkBackend] Server identity mismatch; refusing to connect: '
        '${e.message}',
        name: 'NetworkBackend',
        level: 1000,
        error: e,
      );
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _updateConnectionState(BackendConnectionState.error);
      return;
    } catch (e) {
      // A refused upgrade is different from a dropped socket: 401/403
      // means the auth gate rejected these credentials outright and
      // retrying them cannot succeed — it only deepens the server-side
      // auth lockout. Go terminal instead of backing off. (429 stays on
      // the normal backoff path: the lockout is transient and the next
      // attempt's ticket mint will see the underlying 403 once it
      // clears, which is what latches the terminal state.)
      //
      // A refusal of a TICKET upgrade is not evidence against the bearer:
      // the mint that produced the ticket just succeeded with it. The host
      // answers 401 "Invalid or expired WebSocket ticket" when it restarted
      // between mint and upgrade (tickets live in memory) or the upgrade
      // outlived the ticket. Back off and re-mint; if the bearer really was
      // revoked in between, the next mint's 403 latches.
      if (_authRejected || (!upgradeUsedTicket && _isAuthUpgradeRejection(e))) {
        _latchAuthRejection('WebSocket upgrade refused: $e');
        _enterAuthRejectedState();
        return;
      }
      developer.log(
        'Failed to connect WebSocket: $e',
        name: 'NetworkBackend',
        level: 1000,
        error: e,
      );
      // An upgrade we stopped waiting for can still complete. Left attached,
      // it fed events in while the backend said disconnected, stayed open on
      // the host next to the connection that replaced it, and its eventual
      // close reported the live connection as dropped.
      final abandoned = _wsChannel;
      _wsChannel = null;
      unawaited(_wsSubscription?.cancel());
      _wsSubscription = null;
      if (abandoned != null) {
        unawaited(abandoned.sink.done.catchError((Object _) {}));
        unawaited(abandoned.sink.close());
      }
      _handleConnectionFailure();
    }
  }

  /// True when [error] is the WebSocket upgrade being refused with an
  /// auth status (401/403). `IOWebSocketChannel.ready` surfaces the
  /// refusal as a `WebSocketChannelException` wrapping dart:io's
  /// "Connection to '…' was not upgraded to websocket, HTTP status
  /// code: NNN" — the status code in that message is the only surface
  /// the package exposes for the refusal, so we match on it.
  bool _isAuthUpgradeRejection(Object error) {
    final s = error.toString();
    return s.contains('status code: 401') || s.contains('status code: 403');
  }

  /// Latch the terminal auth-rejection flags. [_authRejected] stops the
  /// connection lifecycle retrying; [_rejectedAuthToken] (set only when a
  /// token was actually presented) additionally lets the HTTP helpers
  /// fail fast. Token equality is the gate on the request side, so a
  /// swapped-in replacement token passes without needing to clear this.
  void _latchAuthRejection(String via) {
    final presented = authToken;
    if (presented != null && presented.isNotEmpty) {
      _rejectedAuthToken = presented;
    }
    _authRejected = true;
    developer.log(
      '[NetworkBackend] Host rejected auth credentials ($via); '
      'failing fast until the token is replaced or reconnect is requested',
      name: 'NetworkBackend',
      level: 1000,
    );
  }

  /// Settle into the terminal auth-rejection state: cancel any pending
  /// reconnect, surface `error` to the connection chip, and emit one
  /// system event so the UI can explain WHY the session stopped instead
  /// of showing a silent disconnect. Re-entry is idempotent — the event
  /// only fires on the first transition into `error`.
  void _enterAuthRejectedState() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stopWebSocketHeartbeat();
    // Tear down any still-open socket: a mid-session revocation reaches us
    // through an HTTP 403 while the socket is technically alive, and a
    // rejected credential should not keep a channel the server no longer
    // trusts.
    unawaited(_wsSubscription?.cancel());
    _wsSubscription = null;
    unawaited(_wsChannel?.sink.close());
    _wsChannel = null;
    final firstEntry = _connectionState != BackendConnectionState.error;
    _updateConnectionState(BackendConnectionState.error);
    if (firstEntry && !_eventController.isClosed) {
      _eventController.add(
        NightshadeEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          category: EventCategory.system,
          eventType: 'AuthenticationRejected',
          severity: EventSeverity.error,
          data: const {
            'message':
                'The host rejected this device\'s access token. '
                'Re-pair or update the token to reconnect.',
          },
        ),
      );
    }
  }

  /// Handle connection failures with exponential backoff
  void _handleConnectionFailure() {
    if (_disposed || _disconnecting) {
      return;
    }
    // If a request path already latched a rejection (e.g. the host revoked
    // the token mid-session), don't arm a doomed retry — go terminal now.
    if (_authRejected) {
      _enterAuthRejectedState();
      return;
    }
    _stopWebSocketHeartbeat();
    if (_connectionState == BackendConnectionState.disconnected &&
        _reconnectTimer != null) {
      return;
    }
    _updateConnectionState(BackendConnectionState.disconnected);

    // Calculate exponential backoff: 1s, 2s, 4s, 8s, 16s, 30s (max)
    final delay = Duration(
      seconds: [
        1,
        2,
        4,
        8,
        16,
        _NetworkBackendTransport._maxReconnectDelay,
      ][_reconnectAttempt.clamp(0, 5)],
    );

    _reconnectAttempt++;
    developer.log(
      '[NetworkBackend] Reconnecting in ${delay.inSeconds}s (attempt $_reconnectAttempt)',
      name: 'NetworkBackend',
      level: 800,
    );

    _reconnectTimer = Timer(delay, () {
      if (_disposed || _disconnecting) {
        return;
      }
      if (_connectionState != BackendConnectionState.connected) {
        developer.log(
          '[NetworkBackend] Attempting reconnection...',
          name: 'NetworkBackend',
          level: 800,
        );
        connect();
      }
    });
  }

  void _startWebSocketHeartbeat() {
    _stopWebSocketHeartbeat();
    if (_webSocketHeartbeatPausedForLifecycle) {
      return;
    }
    if (webSocketHeartbeatInterval <= Duration.zero) {
      return;
    }

    _webSocketHeartbeatTimer = Timer.periodic(webSocketHeartbeatInterval, (_) {
      final lastMessageAt = _lastWebSocketMessageAt;
      if (lastMessageAt != null &&
          DateTime.now().difference(lastMessageAt) >
              webSocketHeartbeatTimeout) {
        developer.log(
          '[NetworkBackend] WebSocket heartbeat timed out',
          name: 'NetworkBackend',
          level: 900,
        );
        _wsSubscription?.cancel();
        _wsSubscription = null;
        _wsChannel?.sink.close();
        _wsChannel = null;
        _handleConnectionFailure();
        return;
      }

      try {
        // Record the send timestamp BEFORE adding to the sink so that even
        // if the sink call yields, the pong-handler will see a consistent
        // value to subtract from. Overwriting any previous unmatched ping
        // is intentional: if we send a new ping while the prior pong is
        // still in flight, the older measurement is stale and the newer
        // one is what the operator cares about.
        _pendingPingSentAt = DateTime.now();
        _wsChannel?.sink.add(
          jsonEncode({
            'type': 'ping',
            'timestamp': _pendingPingSentAt!.toUtc().toIso8601String(),
          }),
        );
      } catch (e) {
        // Don't leave a stale pending-ping timestamp behind on send failure;
        // a future successful ping would otherwise be computed against the
        // wrong sentAt and emit a wildly inflated latency.
        _pendingPingSentAt = null;
        developer.log(
          '[NetworkBackend] Failed to send WebSocket heartbeat: $e',
          name: 'NetworkBackend',
          level: 900,
          error: e,
        );
        _handleConnectionFailure();
      }
    });
  }

  /// Pause client-initiated WebSocket heartbeat pings while the mobile app is
  /// backgrounded. The socket is left open so foreground resume can continue
  /// without a full reconnect when the OS has kept the connection alive.
  void _pauseWebSocketHeartbeatForAppLifecycle() {
    if (_disposed) {
      return;
    }
    _webSocketHeartbeatPausedForLifecycle = true;
    _stopWebSocketHeartbeat();
  }

  /// Resume WebSocket heartbeat pings after the mobile app returns foreground.
  void _resumeWebSocketHeartbeatForAppLifecycle() {
    if (_disposed) {
      return;
    }
    if (!_webSocketHeartbeatPausedForLifecycle) {
      return;
    }
    _webSocketHeartbeatPausedForLifecycle = false;
    if (_connectionState == BackendConnectionState.connected &&
        _wsChannel != null) {
      _startWebSocketHeartbeat();
    }
  }

  void _stopWebSocketHeartbeat() {
    _webSocketHeartbeatTimer?.cancel();
    _webSocketHeartbeatTimer = null;
    // Drop the in-flight ping timestamp so a stale send doesn't get
    // matched against a pong from a later connection.
    _pendingPingSentAt = null;
    // Drop the cached latency so the UI doesn't display a stale value
    // while we're trying to reconnect. The next pong on a fresh
    // connection will repopulate it.
    _lastLatency = null;
  }

  /// Disconnect from the server.
  ///
  /// Emits a `collaboration.leave` frame BEFORE tearing down the
  /// socket so the server can release our viewer slot promptly rather
  /// than waiting for the WS-close handler to run. The leave is best-
  /// effort: if the sink is already dead (server crashed, network
  /// dropped) the send throws and we proceed with teardown — the
  /// server-side `onDone` handler is the backstop.
  Future<void> _disconnect() async {
    if (_disposed || _disconnecting) {
      return;
    }
    _disconnecting = true;
    try {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _sendCollaborationLeave();
      _stopWebSocketHeartbeat();
      await _wsSubscription?.cancel();
      _wsSubscription = null;
      await _wsChannel?.sink.close();
      _wsChannel = null;
      _updateConnectionState(BackendConnectionState.disconnected);
    } finally {
      _disconnecting = false;
    }
  }

  /// Send a `collaboration.join` frame on the open WebSocket.
  ///
  /// Called immediately after the upgrade handshake completes. Tolerates
  /// a missing identity (caller didn't call [setCollaborationIdentity]
  /// before [connect]) — when the viewerId is null we skip the send and
  /// log a warning, because a join with no id will be rejected by the
  /// server when auth is disabled (the server otherwise overrides it
  /// with the authenticated principal's digest, in which case the id we
  /// send doesn't matter).
  ///
  /// Send failures are logged but do not tear down the socket: the
  /// downstream event flow is independent of the collaboration slot, and
  /// a failed join just means the operator's viewer chip won't show this
  /// device — far less serious than killing the WS.
  void _sendCollaborationJoin() {
    final channel = _wsChannel;
    if (channel == null) return;
    final displayName = _collaborationDisplayName;
    final viewerId = _collaborationViewerId;
    final deviceName = _collaborationDeviceName;
    if (displayName == null || displayName.isEmpty) {
      developer.log(
        '[NetworkBackend] Skipping collaboration.join: no display name set '
        '(call setCollaborationIdentity before connect)',
        name: 'NetworkBackend',
        level: 900,
      );
      return;
    }
    try {
      // The server requires `name` (rejects an empty payload with an
      // error frame). We also send `viewerId` and `deviceName` — the
      // server overrides `viewerId` from the auth context when present
      // but still logs an impersonation warning if the value we send
      // disagrees. Sending the same value the auth path will derive is
      // therefore the correct behaviour even though the server's
      // override makes it functionally redundant.
      channel.sink.add(
        jsonEncode({
          'type': 'collaboration.join',
          if (viewerId != null && viewerId.isNotEmpty) 'viewerId': viewerId,
          if (deviceName != null && deviceName.isNotEmpty)
            'deviceName': deviceName,
          'name': displayName,
        }),
      );
    } catch (e) {
      developer.log(
        '[NetworkBackend] Failed to send collaboration.join: $e',
        name: 'NetworkBackend',
        level: 900,
        error: e,
      );
    }
  }

  /// Send a `collaboration.leave` frame, best-effort. Called from
  /// [disconnect] before the sink is closed.
  void _sendCollaborationLeave() {
    final channel = _wsChannel;
    if (channel == null) return;
    final viewerId = _collaborationViewerId;
    if (viewerId == null || viewerId.isEmpty) {
      return;
    }
    try {
      channel.sink.add(
        jsonEncode({'type': 'collaboration.leave', 'viewerId': viewerId}),
      );
    } catch (e) {
      // Closing-time failure is expected on a dead socket; log at FINE.
      developer.log(
        '[NetworkBackend] collaboration.leave send failed (socket likely '
        'already closed): $e',
        name: 'NetworkBackend',
        level: 700,
      );
    }
  }

  /// Dispose resources
  void _dispose() {
    _disposed = true;
    _disconnecting = true;
    _reconnectTimer?.cancel();
    _stopWebSocketHeartbeat();
    _wsSubscription?.cancel();
    _wsChannel?.sink.close();
    _httpClient.close(force: true);
    if (_ownsHttpClient) {
      _http.close();
    }
    _eventController.close();
    _connectionStateController.close();
    _polarAlignController.close();
    _pushNotificationController.close();
    _latencyController.close();
  }
}
