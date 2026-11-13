part of '../network_backend.dart';

extension _NetworkBackendEventTracking on _NetworkBackendTransport {
  void _handleEventSideEffects(SkotiqEvent event) {
    if (event.category == EventCategory.equipment &&
        event.eventType == 'PropertyChanged' &&
        event.data['property'] == 'device_change') {
      Log.info(
        '[NetworkBackend] Device-change event invalidating discovery cache',
        source: 'NetworkBackend',
      );
      invalidateDeviceCache();
    }
  }

  /// Update the cached seq cursor + server instance after parsing an
  /// event. Detects three conditions:
  ///
  /// 1. A gap (received seq > expected seq + 1) — log a warning so the
  ///    operator and tests can see that events are missing. The cursor still
  ///    advances to the received seq so nothing wedges waiting for the
  ///    missing ones.
  ///
  /// 2. An instance-id change (server restarted mid-WS, which is rare
  ///    because the WS dies when the server dies) — log, reset the
  ///    cursor, emit BackendReconnected so providers refetch.
  ///
  /// 3. The first serverInstanceId seen — adopted as the attachment cursor.
  void _trackEventSeq(SkotiqEvent event, {required bool isReplay}) {
    if (isReplay) {
      Log.debug(
        '[NetworkBackend] Replayed event seq=${event.seq} '
        'type=${event.eventType}',
        source: 'NetworkBackend',
      );
    }

    final eventSeq = event.seq;
    final eventInstance = event.serverInstanceId;

    if (eventInstance != null && eventInstance.isNotEmpty) {
      final cached = _serverInstanceId;
      if (cached != null && cached != eventInstance) {
        Log.warning(
          '[NetworkBackend] Server instance changed mid-stream '
          '(old=$cached, new=$eventInstance); resetting seq cursor.',
          source: 'NetworkBackend',
        );
        _lastSeenEventSeq = null;
        _serverInstanceId = eventInstance;
        _previousServerInstanceId = eventInstance;
        _eventController.add(
          SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            category: EventCategory.system,
            eventType: 'BackendReconnected',
            severity: EventSeverity.info,
            data: {
              'message': 'Server instance changed mid-stream',
              'previousInstance': cached,
              'currentInstance': eventInstance,
            },
          ),
        );
      } else if (cached == null) {
        _serverInstanceId = eventInstance;
        _previousServerInstanceId = eventInstance;
      }
    }

    if (eventSeq != null) {
      final previous = _lastSeenEventSeq;
      if (previous != null && eventSeq > previous + 1) {
        final lost = eventSeq - previous - 1;
        Log.warning(
          '[NetworkBackend] Event seq gap: expected ${previous + 1}, '
          'got $eventSeq (lost $lost events)',
          source: 'NetworkBackend',
        );
      }
      _lastSeenEventSeq = eventSeq;
    }
  }
}
