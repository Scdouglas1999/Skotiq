import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

import '../models/backend/event_types.dart' as core;
import '../models/backend/host_runtime_update.dart' show isHostSyncEnvelope;
import '../utils/logging_service.dart';

/// The two forms an event takes: the typed union the native side sends
/// ([bridge.SkotiqEvent]) and the event type plus data map that travels
/// between a host and its clients ([core.SkotiqEvent]). The generated codec in
/// `skotiq_bridge` owns the names; this file only joins the two envelopes.

/// The typed event each wire event stands for, kept beside it so an event is
/// encoded or decoded once however many readers want its typed form.
final Expando<_Typed> _typedOf = Expando<_Typed>('typed event');

class _Typed {
  const _Typed(this.event);
  final bridge.SkotiqEvent? event;
}

/// The wire form of a native event.
core.SkotiqEvent wireEventFromTyped(bridge.SkotiqEvent event) {
  final (eventType, data) = bridge.encodeEventPayload(event.payload);
  final wire = core.SkotiqEvent(
    timestamp: event.timestamp,
    severity: _wireSeverity(event.severity),
    category: _wireCategory(event.category),
    eventType: eventType,
    data: data,
  );
  _typedOf[wire] = _Typed(event);
  return wire;
}

/// The typed event a host sent as [event], or null when this build cannot
/// rebuild it: an event type it does not know (a newer host's, or one of the
/// job, session, catalog and host-sync envelopes that only exist on the
/// wire, and the events the host makes in Dart), or data missing a field the
/// event cannot be built without. Such an event is left
/// out of the typed stream instead of becoming something the host never said.
bridge.SkotiqEvent? typedEventFromWire(core.SkotiqEvent event) =>
    (_typedOf[event] ??= _Typed(_decode(event))).event;

/// The equipment event [event] carries; null for any other event.
bridge.EquipmentEvent? equipmentEventOf(core.SkotiqEvent event) {
  if (event.category != core.EventCategory.equipment) return null;
  return switch (typedEventFromWire(event)?.payload) {
    bridge.EventPayload_Equipment(:final field0) => field0,
    _ => null,
  };
}

/// The imaging event [event] carries; null for any other event, a DepthLock
/// event included.
bridge.ImagingEvent? imagingEventOf(core.SkotiqEvent event) {
  if (event.category != core.EventCategory.imaging) return null;
  return switch (typedEventFromWire(event)?.payload) {
    bridge.EventPayload_Imaging(:final field0) => field0,
    _ => null,
  };
}

/// Whether [event] may be from the camera [cameraId]: an imaging event either
/// names no camera (a native one: the native side drives a single active
/// camera) or names this one. On a dual-camera rig the guide camera publishes
/// onto the same stream, so an event naming another camera is never ours.
/// The capture service and the Flat Wizard attribute frames by this.
bool eventMayBeFromCamera(core.SkotiqEvent event, String cameraId) {
  for (final key in const ['deviceId', 'device_id', 'cameraId', 'camera_id']) {
    final raw = event.data[key];
    if (raw != null &&
        raw.toString().isNotEmpty &&
        raw.toString() != cameraId) {
      return false;
    }
  }
  return true;
}

/// The guiding event [event] carries; null for any other event.
bridge.GuidingEvent? guidingEventOf(core.SkotiqEvent event) {
  if (event.category != core.EventCategory.guiding) return null;
  return switch (typedEventFromWire(event)?.payload) {
    bridge.EventPayload_Guiding(:final field0) => field0,
    _ => null,
  };
}

/// The safety event [event] carries; null for any other event.
bridge.SafetyEvent? safetyEventOf(core.SkotiqEvent event) {
  if (event.category != core.EventCategory.safety) return null;
  return switch (typedEventFromWire(event)?.payload) {
    bridge.EventPayload_Safety(:final field0) => field0,
    _ => null,
  };
}

/// The system event [event] carries; null for any other event.
bridge.SystemEvent? systemEventOf(core.SkotiqEvent event) {
  if (event.category != core.EventCategory.system) return null;
  return switch (typedEventFromWire(event)?.payload) {
    bridge.EventPayload_System(:final field0) => field0,
    _ => null,
  };
}

bridge.SkotiqEvent? _decode(core.SkotiqEvent event) {
  if (isHostSyncEnvelope(event) || core.isHostMadeEvent(event)) return null;
  final category = _typedCategory(event.category);
  if (category == null) return null;
  final severity = _typedSeverity(event.severity);
  final bridge.EventPayload? payload;
  try {
    payload = bridge.decodeEventPayload(
      category,
      event.eventType,
      event.data,
      severity: severity,
    );
  } on FormatException catch (error) {
    _reportUndecodable(event, error.message);
    return null;
  }
  if (payload == null) {
    _reportUndecodable(event, 'no event of that type in this release');
    return null;
  }
  final rawDeviceId = event.data['device_id'];
  return bridge.SkotiqEvent(
    eventId: BigInt.from(event.timestamp),
    timestamp: event.timestamp,
    severity: severity,
    category: category,
    payload: payload,
    deviceId: rawDeviceId is String && rawDeviceId.isNotEmpty
        ? rawDeviceId
        : null,
  );
}

/// The event kinds already reported as undecodable, so a kind that arrives
/// several times a second is logged once.
final Set<String> _reportedUndecodable = <String>{};

/// Host and client run the same release and share one codec, so an event this
/// build cannot read is a defect: every reader of it misses it, a `Stopped`
/// included.
void _reportUndecodable(core.SkotiqEvent event, String why) {
  final kind = '${event.category.name}/${event.eventType}';
  if (!_reportedUndecodable.add(kind)) return;
  Log.warning(
    'Dropped a $kind event this build cannot read ($why). Later $kind '
    'events that cannot be read are dropped without another line.',
    source: 'BridgeEventCodec',
  );
}

core.EventSeverity _wireSeverity(bridge.EventSeverity severity) =>
    switch (severity) {
      bridge.EventSeverity.info => core.EventSeverity.info,
      bridge.EventSeverity.warning => core.EventSeverity.warning,
      bridge.EventSeverity.error => core.EventSeverity.error,
      bridge.EventSeverity.critical => core.EventSeverity.critical,
    };

bridge.EventSeverity _typedSeverity(core.EventSeverity severity) =>
    switch (severity) {
      core.EventSeverity.info => bridge.EventSeverity.info,
      core.EventSeverity.warning => bridge.EventSeverity.warning,
      core.EventSeverity.error => bridge.EventSeverity.error,
      core.EventSeverity.critical => bridge.EventSeverity.critical,
    };

core.EventCategory _wireCategory(bridge.EventCategory category) =>
    switch (category) {
      bridge.EventCategory.equipment => core.EventCategory.equipment,
      bridge.EventCategory.imaging => core.EventCategory.imaging,
      bridge.EventCategory.guiding => core.EventCategory.guiding,
      bridge.EventCategory.sequencer => core.EventCategory.sequencer,
      bridge.EventCategory.safety => core.EventCategory.safety,
      bridge.EventCategory.system => core.EventCategory.system,
      bridge.EventCategory.polarAlignment => core.EventCategory.polarAlignment,
    };

bridge.EventCategory? _typedCategory(core.EventCategory category) =>
    switch (category) {
      core.EventCategory.equipment => bridge.EventCategory.equipment,
      core.EventCategory.imaging => bridge.EventCategory.imaging,
      core.EventCategory.guiding => bridge.EventCategory.guiding,
      core.EventCategory.sequencer => bridge.EventCategory.sequencer,
      core.EventCategory.safety => bridge.EventCategory.safety,
      core.EventCategory.system => bridge.EventCategory.system,
      core.EventCategory.polarAlignment => bridge.EventCategory.polarAlignment,
      core.EventCategory.job ||
      core.EventCategory.session ||
      core.EventCategory.catalog => null,
    };
