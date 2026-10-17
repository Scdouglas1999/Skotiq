import '../models/backend/event_types.dart';

/// Wire-stable [SkotiqEvent.eventType] strings for host ↔ companion sync.
///
/// Rust-native events (e.g. equipment `Connected`) are handled separately in
/// [applyRemoteSyncEvent]; these names cover API mutations that do not pass
/// through the native EventBus.
abstract final class RemoteSyncEventTypes {
  static const sequenceUpdated = 'sequence_updated';
  static const profileChanged = 'profile_changed';
  static const framingTargetChanged = 'framing_target_changed';
  static const guiderState = 'guider_state';
  static const deviceConnected = 'device_connected';
  static const deviceDisconnected = 'device_disconnected';
}

SkotiqEvent remoteSyncEvent({
  required String eventType,
  Map<String, dynamic> data = const {},
  EventSeverity severity = EventSeverity.info,
}) {
  return SkotiqEvent(
    timestamp: DateTime.now().millisecondsSinceEpoch,
    severity: severity,
    category: EventCategory.system,
    eventType: eventType,
    data: data,
  );
}
