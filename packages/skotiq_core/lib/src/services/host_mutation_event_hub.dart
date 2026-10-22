import 'dart:async';

import '../models/backend/event_types.dart';
import '../models/backend/host_mutation_event.dart';

/// Fan-out point for host-authoritative REST mutations.
///
/// Handlers publish here after successful writes. The hub always notifies local
/// subscribers (desktop GUI EventBus merge + host-local sync). An optional
/// [wsBroadcast] callback forwards the same envelope to WebSocket `/events`
/// clients when the embedded API server is running.
class HostMutationEventHub {
  final StreamController<SkotiqEvent> _controller =
      StreamController<SkotiqEvent>.broadcast();

  /// When set by [HeadlessApiServer], mutation events also reach remote WS
  /// subscribers. Cleared when the server stops.
  void Function(SkotiqEvent event)? wsBroadcast;

  Stream<SkotiqEvent> get stream => _controller.stream;

  void publish({
    required String entityType,
    required String action,
    String? entityId,
    Map<String, dynamic> extra = const {},
  }) {
    final event = buildHostMutationEvent(
      entityType: entityType,
      action: action,
      entityId: entityId,
      extra: extra,
    );
    if (!_controller.isClosed) {
      _controller.add(event);
    }
    wsBroadcast?.call(event);
  }

  /// Notify remote WebSocket clients without re-applying mutations on the
  /// host container (handlers that already updated local Riverpod state).
  void publishRemoteOnly({
    required String entityType,
    required String action,
    String? entityId,
    Map<String, dynamic> extra = const {},
  }) {
    final event = buildHostMutationEvent(
      entityType: entityType,
      action: action,
      entityId: entityId,
      extra: extra,
    );
    wsBroadcast?.call(event);
  }

  /// Send a prepared event to remote WebSocket clients only. Used for runtime
  /// state the host's own providers already hold.
  void broadcastRemote(SkotiqEvent event) {
    wsBroadcast?.call(event);
  }

  void dispose() {
    wsBroadcast = null;
    if (!_controller.isClosed) {
      _controller.close();
    }
  }
}
