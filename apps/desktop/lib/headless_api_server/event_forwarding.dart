part of '../headless_api_server.dart';

extension _HeadlessApiServerEventForwarding on HeadlessApiServer {
  /// Broadcast an event to all connected WebSocket clients.
  ///
  /// every SkotiqEvent is stamped with a monotonic `seq` and the
  /// server-instance UUID, then appended to the replay ring buffer BEFORE
  /// fan-out to sockets. Map-typed events (legacy callers passing raw
  /// JSON) are coerced through SkotiqEvent.fromWireJson so SSE,
  /// snapshot consumers, and future replay subscribers see a consistent
  /// shape.
  ///
  /// SkotiqEvents whose `eventType` is in the command-completion
  /// table get their originating `correlatingCommandId` stamped from the
  /// correlator on a best-effort basis.
  ///
  /// The replay buffer append is done BEFORE the early-return on empty
  /// sockets: SSE clients and the snapshot endpoint can still pick up
  /// the buffered events even if no WS clients are connected.
  ///
  /// Returns the STAMPED event so a second sink — the run-watch SSE/snapshot
  /// fan-out — can carry the same server `seq` and instance id the WebSocket
  /// path does, rather than re-stamping (which would double-count the sequence)
  /// or forwarding the raw, seq-less original. Null when the payload was not an
  /// event we could sequence; that sink then keeps the raw payload, which has
  /// no seq to key on regardless.
  SkotiqEvent? _broadcastEventImpl(dynamic event) {
    final stamped = _stampEventForBroadcast(event);
    if (stamped == null) {
      // Non-event payload (e.g. raw map without the canonical fields).
      // Don't sequence it but still emit so legacy callers continue to
      // work. These payloads bypass the replay buffer by design.
      _emitRawEvent(event);
      return null;
    }
    _eventReplayBuffer.append(stamped);
    _emitStampedEvent(stamped);
    return stamped;
  }

  /// Stamp a SkotiqEvent (or coerce a Map into one) with the next
  /// sequence number, the server-instance id, and any matching commandId.
  ///
  /// Returns null when [raw] is neither a SkotiqEvent nor an
  /// event-shaped Map that we can reconstruct. The caller falls back to a
  /// non-sequenced raw emit in that case.
  SkotiqEvent? _stampEventForBroadcast(dynamic raw) {
    SkotiqEvent? base;
    if (raw is SkotiqEvent) {
      base = raw;
    } else if (raw is Map<String, dynamic>) {
      try {
        base = SkotiqEvent.fromWireJson(raw);
      } on FormatException {
        return null;
      }
    } else {
      return null;
    }

    _eventSeq += 1;
    final operation = operationForCompletionEvent(base.eventType);
    final deviceId = base.data['deviceId'] is String
        ? base.data['deviceId'] as String
        : null;
    String? correlatingCommandId = base.correlatingCommandId;
    if (correlatingCommandId == null && operation != null) {
      correlatingCommandId = _commandCorrelator.stampEvent(
        operation: operation,
        deviceId: deviceId,
      );
    }
    return base.copyWith(
      seq: _eventSeq,
      serverInstanceId: _serverInstanceId,
      correlatingCommandId: correlatingCommandId,
    );
  }

  /// Serialise a stamped event and push to every connected socket.
  void _emitStampedEvent(SkotiqEvent stamped) {
    if (_sockets.isEmpty) return;
    final jsonEvent = _encodeStampedEventForWire(stamped);
    if (jsonEvent == null) return;
    for (final socket in List.of(_sockets)) {
      try {
        socket.sink.add(jsonEvent);
      } catch (e) {
        _logWarning('Error broadcasting to socket: $e');
      }
    }
  }

  /// Encode a stamped event into the WebSocket wire envelope. Returns
  /// null if encoding failed (logged inside).
  String? _encodeStampedEventForWire(
    SkotiqEvent stamped, {
    bool replay = false,
  }) {
    try {
      final json = stamped.toJson();
      if (stamped.category == EventCategory.guiding &&
          stamped.eventType == 'GuideStep') {
        final data = json['data'];
        if (data is Map<String, dynamic>) {
          final raRaw = data['RADistanceRaw'];
          final decRaw = data['DECDistanceRaw'];
          if (raRaw is num && !data.containsKey('raPx')) {
            data['raPx'] = raRaw.toDouble();
          }
          if (decRaw is num && !data.containsKey('decPx')) {
            data['decPx'] = decRaw.toDouble();
          }
        }
      }
      return jsonEncode(
        _eventJsonSafe({'type': 'event', if (replay) 'replay': true, ...json}),
      );
    } catch (e) {
      _logError('Error encoding event for broadcast: $e');
      return null;
    }
  }

  /// Fallback emit path for non-event payloads. Bypasses the ring buffer
  /// and sequence stamping.
  void _emitRawEvent(dynamic event) {
    if (_sockets.isEmpty) return;
    String jsonEvent;
    try {
      if (event is Map<String, dynamic>) {
        jsonEvent = jsonEncode(_eventJsonSafe({'type': 'event', ...event}));
      } else {
        jsonEvent = jsonEncode(_eventJsonSafe(event));
      }
    } catch (e) {
      _logError('Error encoding non-event payload for broadcast: $e');
      return;
    }
    for (final socket in List.of(_sockets)) {
      try {
        socket.sink.add(jsonEvent);
      } catch (e) {
        _logWarning('Error broadcasting non-event payload: $e');
      }
    }
  }

  /// Recursively make bridge-originated payloads safe for `dart:convert`.
  /// flutter_rust_bridge maps Rust u64/i64 values nested in event data to
  /// Dart BigInt; jsonEncode cannot serialize those values directly.
  Object? _eventJsonSafe(Object? value) {
    if (value is BigInt) {
      final maxSafeInteger = BigInt.from(9007199254740991);
      if (value >= -maxSafeInteger && value <= maxSafeInteger) {
        return value.toInt();
      }
      return value.toString();
    }
    if (value is Map) {
      return value.map(
        (key, nested) => MapEntry(key.toString(), _eventJsonSafe(nested)),
      );
    }
    if (value is Iterable) {
      return value.map(_eventJsonSafe).toList(growable: false);
    }
    return value;
  }

  void _broadcastCollaborationState(LiveCollaborationState state) {
    if (_sockets.isEmpty) return;
    final payload = jsonEncode({
      'type': 'collaboration_state',
      'state': state.toJson(),
    });
    for (final socket in List.of(_sockets)) {
      try {
        socket.sink.add(payload);
      } catch (e) {
        _logWarning('Error broadcasting collaboration state: $e');
      }
    }
  }

  /// Forward push notifications from a [PushNotificationService] stream to all
  /// connected WebSocket clients. Notifications are sent verbatim (the service
  /// emits the `type: 'push_notification'` envelope) so the mobile client can
  /// distinguish them from `type: 'event'` broadcasts and surface them as
  /// system notifications instead of UI updates.
  ///
  /// Why on the server rather than the service: the WebSocket fan-out lives
  /// here. Re-subscribing replaces any previous subscription so the GUI can
  /// safely call this every time the backend changes.
  ///
  /// in addition to the WS fan-out, each notification is also handed
  /// to the LAN UDP broadcaster (when configured) so phones whose WebSocket
  /// has dropped still wake on critical alerts. The broadcaster filters by
  /// severity (critical-only by default) and supplies its own HMAC-signed
  /// wire frame; see lan_push_broadcaster.dart for the protocol spec.
  void _setPushNotificationStream(
    Stream<Map<String, dynamic>> notificationStream,
  ) {
    _pushNotificationSubscription?.cancel();
    _pushNotificationSubscription = notificationStream.listen(
      (notification) {
        // Always do the WS fan-out — even if no sockets are attached, we
        // still kick the LAN broadcaster + remote delivery so a phone that
        // can't keep its WS open still gets the alert.
        if (_sockets.isNotEmpty) {
          final String encoded;
          try {
            encoded = jsonEncode(notification);
          } catch (e) {
            _logWarning('Error encoding push notification: $e');
            return;
          }
          for (final socket in List.of(_sockets)) {
            try {
              socket.sink.add(encoded);
            } catch (e) {
              _logWarning('Error broadcasting push notification: $e');
            }
          }
        }

        // LAN UDP broadcaster + remote (FCM/APNs) delivery hooks.
        // Building the wire frame is cheap; if neither sink is wired we
        // skip the encode entirely.
        final broadcaster = _lanPushBroadcaster;
        final remote = _remotePushDelivery;
        if (broadcaster == null && remote == null) {
          return;
        }
        final frame = _buildPushFrameFromNotification(notification);
        if (frame == null) {
          return;
        }
        if (broadcaster != null && broadcaster.isStarted) {
          // Fire-and-forget — sendCriticalPush is non-blocking on the
          // happy path. Errors inside the broadcaster surface via its own
          // logger, so we don't need a try/catch here.
          unawaited(broadcaster.sendCriticalPush(frame));
        }
        if (remote != null) {
          unawaited(_deliverRemotePush(remote, frame));
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _logError('Push notification stream error: $error');
      },
    );
  }

  /// Coerce a `push_notification` JSON envelope into a wire-format
  /// [PushNotificationFrame]. Returns null when the envelope is missing
  /// required fields — those are logged so a malformed producer is
  /// visible rather than silently dropped.
  PushNotificationFrame? _buildPushFrameFromNotification(
    Map<String, dynamic> notification,
  ) {
    final title = notification['title'];
    final body = notification['body'];
    final priority = notification['priority'];
    final eventType = notification['eventType'];
    final category = notification['category'];
    final deepLink = notification['deepLink'];
    final timestamp = notification['timestamp'];
    if (title is! String || body is! String) {
      _logWarning(
        'Push notification missing title/body — skipping LAN fan-out',
        fields: {'envelope_keys': notification.keys.toList()},
      );
      return null;
    }
    // Map the existing PushNotificationPriority labels (low/normal/high/
    // critical) onto the wire-protocol severity labels. Anything other
    // than critical/warning collapses to `info`. The broadcaster's
    // severity filter (critical-only by default) takes care of dropping
    // the lower tiers without further work here.
    final severity = switch (priority) {
      'critical' => 'critical',
      'high' => 'warning',
      _ => 'info',
    };
    final eventDeviceMap = <String, Object?>{};
    if (eventType is String) eventDeviceMap['eventType'] = eventType;
    if (category is String) eventDeviceMap['category'] = category;
    // The tap payload, when the producer supplied one. Carried on the LAN/FCM
    // copies as well as the WebSocket copy, so a push that arrives over the
    // UDP path opens the same screen as the one that arrives over the socket.
    if (deepLink is String && deepLink.isNotEmpty) {
      eventDeviceMap['deepLink'] = deepLink;
    }
    final ts = timestamp is int
        ? DateTime.fromMillisecondsSinceEpoch(timestamp)
        : DateTime.now();
    return PushNotificationFrame(
      id: HeadlessApiServer._generateUuidV4(),
      severity: severity,
      title: title,
      body: body,
      data: eventDeviceMap,
      timestamp: ts,
      serverFingerprint: _serverFingerprint,
    );
  }

  Future<void> _deliverRemotePush(
    RemotePushDelivery remote,
    PushNotificationFrame frame,
  ) async {
    try {
      await remote.deliver(frame);
    } on UnimplementedError catch (e) {
      // Expected when the FCM/APNs scaffold is in place but no operator
      // has wired the cloud-side credentials. Log once-per-frame at
      // debug-level severity so the missing setup is visible without
      // spamming the operator's error log.
      _logInfo('Remote push delivery not configured: $e');
    } catch (e, st) {
      _logWarning('Remote push delivery failed: $e\n$st');
    }
  }

  /// replace the LAN push broadcaster post-construction (used by
  /// `desktop_app_bootstrap.dart` so the broadcaster's lifecycle is tied
  /// to the GUI's settings toggle rather than the server's constructor).
  /// Pass null to disable.
  void _setLanPushBroadcaster(LanPushBroadcaster? broadcaster) {
    _lanPushBroadcaster = broadcaster;
  }

  /// register a remote (FCM/APNs) delivery hook. By default both
  /// scaffolds throw [UnimplementedError]; the headless server logs
  /// those as informational so the operator can see "remote push not
  /// configured" without taking down the LAN broadcaster.
  void _setRemotePushDelivery(RemotePushDelivery? delivery) {
    _remotePushDelivery = delivery;
  }

  /// bind an [UpdateController] to the server. The controller's
  /// `events` stream is subscribed and every variant translated into a
  /// `SkotiqEvent` with `category: EventCategory.system`. Routes
  /// under `/api/system/version` + `/api/system/update/*` are installed
  /// on the next [start()] call.
  ///
  /// Pass null to detach (e.g. on shutdown so the WS broadcast stream
  /// does not keep delivering events after the underlying service has
  /// been disposed).
  void _setUpdateController(UpdateController? controller) {
    _updateEventSubscription?.cancel();
    _updateEventSubscription = null;
    if (controller == null) {
      _updateHandlers = null;
      return;
    }
    _updateHandlers = UpdateHandlers(
      controller: controller,
      jobManager: _jobManager,
    );
    _updateEventSubscription = controller.events.listen(
      (event) {
        final severity =
            event is UpdateFailedEvent || event is UpdateVerificationFailedEvent
            ? EventSeverity.error
            : EventSeverity.info;
        broadcastEvent(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: severity,
            category: EventCategory.system,
            eventType: event.type,
            data: event.data,
          ),
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        _logError('UpdateController event stream error: $error');
      },
    );
  }
}
