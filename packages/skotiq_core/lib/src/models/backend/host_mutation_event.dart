import 'event_types.dart';

/// Canonical event type for REST/API mutations on the imaging host.
///
/// Remote and local clients subscribe to [HostStateChanged] on `/events` to
/// invalidate cached UI state when another client mutates host-authoritative
/// data (sequences, targets, equipment, profiles, sequencer control, etc.).
const String hostStateChangedEventType = 'HostStateChanged';

/// Entity namespaces referenced in mutation event payloads.
abstract final class HostMutationEntity {
  static const sequence = 'sequence';
  static const target = 'target';
  static const equipment = 'equipment';
  static const guider = 'guider';
  static const profile = 'profile';
  static const sequencer = 'sequencer';

  static const settings = 'settings';
  static const session = 'session';
  static const capturedImage = 'capturedImage';
  static const atlas = 'atlas';
}

/// Mutation verbs emitted after successful REST handler completion.
abstract final class HostMutationAction {
  static const created = 'created';
  static const updated = 'updated';
  static const deleted = 'deleted';
  static const connected = 'connected';
  static const disconnected = 'disconnected';
  static const started = 'started';
  static const stopped = 'stopped';
  static const paused = 'paused';
  static const resumed = 'resumed';
  static const loaded = 'loaded';
}

/// Build a [SkotiqEvent] with the standardized host-mutation schema:
/// `entityType`, `action`, optional `entityId`, plus any handler-specific
/// fields in [extra].
SkotiqEvent buildHostMutationEvent({
  required String entityType,
  required String action,
  String? entityId,
  Map<String, dynamic> extra = const {},
}) {
  return SkotiqEvent(
    timestamp: DateTime.now().millisecondsSinceEpoch,
    severity: EventSeverity.info,
    category: EventCategory.system,
    eventType: hostStateChangedEventType,
    data: {
      'entityType': entityType,
      'action': action,
      if (entityId != null && entityId.isNotEmpty) 'entityId': entityId,
      ...extra,
    },
  );
}
