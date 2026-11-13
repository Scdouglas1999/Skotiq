import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

import '../models/backend/event_types.dart' as core;

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
/// job, session and catalog envelopes that only exist on the wire), or data
/// missing a field the event cannot be built without. Such an event is left
/// out of the typed stream instead of becoming something the host never said.
bridge.SkotiqEvent? typedEventFromWire(core.SkotiqEvent event) =>
    (_typedOf[event] ??= _Typed(_decode(event))).event;

bridge.SkotiqEvent? _decode(core.SkotiqEvent event) {
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
  } on FormatException {
    return null;
  }
  if (payload == null) return null;
  return bridge.SkotiqEvent(
    eventId: BigInt.from(event.timestamp),
    timestamp: event.timestamp,
    severity: severity,
    category: category,
    payload: payload,
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
