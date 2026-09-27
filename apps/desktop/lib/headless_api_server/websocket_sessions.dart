part of '../headless_api_server.dart';

extension _HeadlessApiServerWebSocketSessions on HeadlessApiServer {
  // WebSocket handler

  /// Upgrade wrapper that captures the query parameters off the original
  /// request before shelf_web_socket strips them. The replay logic lives
  /// here so it runs BEFORE the socket is added to [_sockets] and starts
  /// receiving live events (otherwise replay vs live would interleave).
  void _handleWebSocketWithQuery(
    WebSocketChannel socket,
    Map<String, String> query,
    String? authIdentity,
  ) {
    _socketAuthIdentities[socket] = authIdentity;
    // replay on reconnect. Accept `?since=<int>&instance=<uuid>`. If
    // both are valid AND the instance matches AND the seq is within the
    // ring buffer's covered range, replay the missed events BEFORE
    // attaching the live broadcast stream. Otherwise send a
    // `resync_required` advisory so the client can decide how to recover.
    final sinceStr = query['since'];
    final instance = query['instance'];
    if (sinceStr != null && sinceStr.isNotEmpty) {
      final since = int.tryParse(sinceStr);
      if (since == null) {
        // Malformed since= — treat as a fresh subscribe to avoid leaking
        // information about the seq cursor; log a warning.
        _logWarning(
          'WS upgrade with malformed ?since=$sinceStr; '
          'falling back to live-only subscription',
        );
      } else if (instance != null && instance != _serverInstanceId) {
        _sendResyncRequired(socket, reason: 'instance_changed');
      } else {
        final replay = _eventReplayBuffer.eventsSince(since);
        if (replay == null) {
          _sendResyncRequired(socket, reason: 'missed_too_many');
        } else {
          for (final ev in replay) {
            final encoded = _encodeStampedEventForWire(ev, replay: true);
            if (encoded == null) continue;
            try {
              socket.sink.add(encoded);
            } catch (e) {
              _logWarning('Error replaying event to socket: $e');
              break;
            }
          }
        }
      }
    }

    _handleWebSocket(socket, null);
  }

  /// Send the `resync_required` advisory frame and let the client decide
  /// (call snapshot, drop cached state, etc.). The socket is NOT closed;
  /// the live stream continues so the client can keep receiving fresh
  /// events while it rehydrates.
  void _sendResyncRequired(WebSocketChannel socket, {required String reason}) {
    try {
      socket.sink.add(
        jsonEncode({
          'type': 'resync_required',
          'reason': reason,
          'currentSeq': _eventSeq,
          'currentInstance': _serverInstanceId,
          if (_eventReplayBuffer.oldestSeq != null)
            'oldestRetainedSeq': _eventReplayBuffer.oldestSeq,
        }),
      );
    } catch (e) {
      _logWarning('Error sending resync_required to socket: $e');
    }
  }

  void _handleWebSocket(WebSocketChannel socket, String? protocol) {
    _sockets.add(socket);
    _socketLastSeenAt[socket] = DateTime.now();
    _publishConnectedClientCount();
    _ensureWebSocketHeartbeatTimer();
    _logInfo('New WebSocket connection');
    socket.sink.add(
      jsonEncode({
        'type': 'collaboration_state',
        'state': _collaborationManager.state.toJson(),
      }),
    );

    socket.stream.listen(
      (message) {
        // Handle incoming messages (e.g. pings)
        try {
          _socketLastSeenAt[socket] = DateTime.now();
          final data = jsonDecode(message) as Map<String, dynamic>;
          if (data['type'] == 'ping') {
            socket.sink.add(
              jsonEncode({
                'type': 'pong',
                'timestamp': DateTime.now().toUtc().toIso8601String(),
              }),
            );
          } else if (data['type'] == 'pong') {
            return;
          } else {
            _handleCollaborationSocketMessage(socket, data);
          }
        } on Object catch (e) {
          // Why: malformed inbound socket frame must not tear down the socket
          // listener — the remote client may recover on the next frame. We
          // log the parse error so a flood of malformed frames is visible in
          // diagnostics; we deliberately do NOT close the socket here because
          // that's `onError`'s job.
          _logWarning('WebSocket inbound frame parse failed: $e');
        }
      },
      onDone: () {
        _removeWebSocket(socket);
        _logInfo('WebSocket disconnected');
      },
      onError: (error) {
        _removeWebSocket(socket);
        _logWarning('WebSocket error: $error');
      },
    );
  }

  void _removeWebSocket(WebSocketChannel socket) {
    final viewerId = _socketViewerIds.remove(socket);
    if (viewerId != null) {
      _collaborationManager.removeViewer(viewerId);
    }
    _socketAuthIdentities.remove(socket);
    _socketLastSeenAt.remove(socket);
    _sockets.remove(socket);
    _publishConnectedClientCount();
    if (_sockets.isEmpty) {
      _webSocketHeartbeatTimer?.cancel();
      _webSocketHeartbeatTimer = null;
    }
  }

  void _ensureWebSocketHeartbeatTimer() {
    if (webSocketHeartbeatInterval <= Duration.zero ||
        _webSocketHeartbeatTimer != null) {
      return;
    }

    _webSocketHeartbeatTimer = Timer.periodic(webSocketHeartbeatInterval, (_) {
      final now = DateTime.now();
      for (final socket in List.of(_sockets)) {
        final lastSeenAt = _socketLastSeenAt[socket];
        if (lastSeenAt != null &&
            now.difference(lastSeenAt) > webSocketHeartbeatTimeout) {
          _logWarning('Closing stale WebSocket after heartbeat timeout');
          _removeWebSocket(socket);
          unawaited(socket.sink.close());
          continue;
        }

        try {
          socket.sink.add(
            jsonEncode({
              'type': 'ping',
              'timestamp': now.toUtc().toIso8601String(),
            }),
          );
        } catch (e) {
          _logWarning('WebSocket heartbeat failed: $e');
          _removeWebSocket(socket);
        }
      }
    });
  }

  void _handleCollaborationSocketMessage(
    WebSocketChannel socket,
    Map<String, dynamic> data,
  ) {
    final type = data['type'] as String?;
    // the authoritative viewer identity for THIS socket is the
    // digest of the bearer token that authenticated the upgrade. When
    // the socket has no auth identity (auth disabled, or a legacy
    // pre-ticket connection), we fall back to the client-supplied
    // viewerId to keep the existing wire shape working — that is the
    // explicit "auth disabled" path and the operator opted in.
    final authIdentity = _socketAuthIdentities[socket];
    switch (type) {
      case 'collaboration.join':
        final clientViewerId = data['viewerId'] as String?;
        final name = data['name'] as String?;
        if (name == null || name.isEmpty) {
          socket.sink.add(
            jsonEncode({
              'type': 'error',
              'message': 'collaboration.join requires a name',
            }),
          );
          return;
        }
        // Resolve the actual viewer id. The auth identity wins
        // whenever it is available; any mismatching client value is
        // logged at WARNING (potential impersonation attempt) but does
        // NOT fail the join — the server simply substitutes the real
        // identity so legitimate clients that pre-date this gate keep
        // working unchanged.
        final effectiveViewerId = authIdentity ?? clientViewerId;
        if (effectiveViewerId == null || effectiveViewerId.isEmpty) {
          socket.sink.add(
            jsonEncode({
              'type': 'error',
              'message':
                  'collaboration.join requires viewerId when auth is disabled',
            }),
          );
          return;
        }
        if (authIdentity != null &&
            clientViewerId != null &&
            clientViewerId.isNotEmpty &&
            clientViewerId != authIdentity) {
          _logWarning(
            '[COLLAB] Socket attempted to claim viewerId=$clientViewerId '
            'but authenticated as ${HeadlessApiServer._redactBearer(authIdentity)}; '
            'substituting authenticated identity.',
            fields: {
              'attemptedViewerId': clientViewerId,
              'authenticatedViewerId': authIdentity,
              'event': 'collaboration_join_impersonation_attempt',
            },
          );
        }
        _socketViewerIds[socket] = effectiveViewerId;
        _collaborationManager.upsertViewer(effectiveViewerId, name);
        return;
      case 'collaboration.leave':
        // the client cannot remove a viewer slot it does not
        // own. We always use the socket's authoritative identity (or
        // the id this socket previously bound to) regardless of what
        // the payload says.
        final viewerId =
            _socketViewerIds.remove(socket) ??
            authIdentity ??
            (data['viewerId'] as String?);
        if (viewerId != null) {
          _collaborationManager.removeViewer(viewerId);
        }
        return;
      case 'collaboration.preview':
        final preview = data['preview'];
        if (preview != null && preview is! Map<String, dynamic>) {
          socket.sink.add(
            jsonEncode({
              'type': 'error',
              'message':
                  'collaboration.preview requires preview to be an object',
            }),
          );
          return;
        }
        _collaborationManager.updatePreview(preview as Map<String, dynamic>?);
        return;
      case 'collaboration.chat':
        final clientViewerId = data['viewerId'] as String?;
        final viewerName = data['viewerName'] as String?;
        final message = data['message'] as String?;
        if (viewerName == null || message == null) {
          socket.sink.add(
            jsonEncode({
              'type': 'error',
              'message': 'collaboration.chat requires viewerName and message',
            }),
          );
          return;
        }
        // same impersonation rule as collaboration.join — the
        // authenticated identity, not the client-supplied id, signs the
        // chat row so a client cannot put words in someone else's mouth.
        final viewerId = authIdentity ?? clientViewerId;
        if (viewerId == null) {
          socket.sink.add(
            jsonEncode({
              'type': 'error',
              'message':
                  'collaboration.chat requires viewerId when auth is disabled',
            }),
          );
          return;
        }
        if (authIdentity != null &&
            clientViewerId != null &&
            clientViewerId.isNotEmpty &&
            clientViewerId != authIdentity) {
          _logWarning(
            '[COLLAB] Chat impersonation attempt from socket '
            '(claimed=$clientViewerId actual=${HeadlessApiServer._redactBearer(authIdentity)}); '
            'substituting authenticated identity.',
          );
        }
        _collaborationManager.addChat(
          viewerId: viewerId,
          viewerName: viewerName,
          message: message,
        );
        return;
      case 'collaboration.annotation':
        final annotationId = data['annotationId'] as String?;
        final clientViewerId = data['viewerId'] as String?;
        final kind = data['kind'] as String?;
        final payload = data['payload'];
        if (annotationId == null ||
            kind == null ||
            payload is! Map<String, dynamic>) {
          socket.sink.add(
            jsonEncode({
              'type': 'error',
              'message':
                  'collaboration.annotation requires annotationId, kind, and payload',
            }),
          );
          return;
        }
        final viewerId = authIdentity ?? clientViewerId;
        if (viewerId == null) {
          socket.sink.add(
            jsonEncode({
              'type': 'error',
              'message':
                  'collaboration.annotation requires viewerId when auth is disabled',
            }),
          );
          return;
        }
        if (authIdentity != null &&
            clientViewerId != null &&
            clientViewerId.isNotEmpty &&
            clientViewerId != authIdentity) {
          _logWarning(
            '[COLLAB] Annotation impersonation attempt from socket '
            '(claimed=$clientViewerId actual=${HeadlessApiServer._redactBearer(authIdentity)}); '
            'substituting authenticated identity.',
          );
        }
        _collaborationManager.addAnnotation(
          annotationId: annotationId,
          viewerId: viewerId,
          kind: kind,
          payload: payload,
        );
        return;
      case 'session_handoff.set':
        if (!_socketMayChangeSessionHandoff(socket, authIdentity, 'POST')) {
          return;
        }
        final handoff = data['handoff'];
        if (handoff != null && handoff is! Map<String, dynamic>) {
          socket.sink.add(
            jsonEncode({
              'type': 'error',
              'message': 'session_handoff.set requires handoff to be an object',
            }),
          );
          return;
        }
        _collaborationManager.setSessionHandoff(
          handoff as Map<String, dynamic>?,
        );
        return;
      case 'session_handoff.clear':
        if (!_socketMayChangeSessionHandoff(socket, authIdentity, 'DELETE')) {
          return;
        }
        _collaborationManager.setSessionHandoff(null);
        return;
      default:
        // Unknown collaboration message type: tell the client rather than
        // silently dropping it (a typo or a newer client talking to an older
        // server would otherwise just see no effect with no signal).
        socket.sink.add(
          jsonEncode({
            'type': 'error',
            'message':
                'Unknown collaboration message type: '
                '${type ?? '(missing "type")'}',
          }),
        );
        return;
    }
  }

  /// Whether this socket's token may do over the socket what
  /// `[method] /api/session-handoff` allows over HTTP.
  ///
  /// The HTTP route transfers session ownership and is admin-only, but the
  /// socket applied no check at all: any token that could open the event
  /// stream, a view-only phone included, could set or clear the handoff. The
  /// token's current grant is looked up per message, so a token revoked while
  /// its socket stays open loses the right with it. A socket with no identity
  /// exists only on a server deliberately run without authentication.
  bool _socketMayChangeSessionHandoff(
    WebSocketChannel socket,
    String? authIdentity,
    String method,
  ) {
    if (authIdentity == null) {
      return true;
    }
    final grant = _grantForIdentity(authIdentity);
    if (grant != null &&
        HeadlessAuthPolicy.permits(
          grant: grant,
          method: method,
          path: '/api/session-handoff',
        )) {
      return true;
    }
    _logWarning(
      '[AUTH] Refused session handoff change over the event socket for '
      '${HeadlessApiServer._redactBearer(authIdentity)}: the token may not '
      '$method /api/session-handoff',
    );
    socket.sink.add(
      jsonEncode({
        'type': 'error',
        'message':
            'Changing the session handoff needs an admin token; this '
            'connection is not allowed to.',
      }),
    );
    return false;
  }
}
