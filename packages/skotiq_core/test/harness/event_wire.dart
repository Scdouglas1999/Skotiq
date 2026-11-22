// Events as the two transports deliver them: the FFI host's wire event, which
// carries the typed event it was made from, and a linked client's, which the
// codec decodes from the type and data the host sent. Both are built from a
// typed payload, so a test cannot feed a shape no producer sends.

import 'dart:convert';

import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/backend.dart' show wireEventFromTyped;
import 'package:skotiq_core/models.dart';

/// The family a payload belongs to.
bridge.EventCategory categoryOfPayload(bridge.EventPayload payload) =>
    switch (payload) {
      bridge.EventPayload_Equipment() => bridge.EventCategory.equipment,
      bridge.EventPayload_Imaging() ||
      bridge.EventPayload_DepthLock() => bridge.EventCategory.imaging,
      bridge.EventPayload_Guiding() => bridge.EventCategory.guiding,
      bridge.EventPayload_Sequencer() => bridge.EventCategory.sequencer,
      bridge.EventPayload_Safety() => bridge.EventCategory.safety,
      bridge.EventPayload_System() => bridge.EventCategory.system,
      bridge.EventPayload_PolarAlignment() ||
      bridge.EventPayload_PolarAlignmentStatus() ||
      bridge.EventPayload_PolarAlignmentImage() =>
        bridge.EventCategory.polarAlignment,
    };

/// How an event reaches a reader.
enum EventPath { ffi, network }

/// [payload] as the FFI host's event stream carries it.
SkotiqEvent ffiWireEvent(
  bridge.EventPayload payload, {
  bridge.EventSeverity severity = bridge.EventSeverity.info,
  int timestamp = 1,
  String? deviceId,
}) => wireEventFromTyped(
  bridge.SkotiqEvent(
    eventId: BigInt.from(timestamp),
    timestamp: timestamp,
    severity: severity,
    category: categoryOfPayload(payload),
    payload: payload,
    deviceId: deviceId,
  ),
);

/// [payload] as a linked client receives it from its host.
SkotiqEvent networkWireEvent(
  bridge.EventPayload payload, {
  bridge.EventSeverity severity = bridge.EventSeverity.info,
  int timestamp = 1,
  String? deviceId,
}) {
  final sent = ffiWireEvent(
    payload,
    severity: severity,
    timestamp: timestamp,
    deviceId: deviceId,
  );
  final json = jsonDecode(jsonEncode(sent.toJson())) as Map<String, dynamic>;
  return SkotiqEvent.fromJson(json);
}

/// [payload] over [path].
SkotiqEvent wireEventOver(
  EventPath path,
  bridge.EventPayload payload, {
  bridge.EventSeverity severity = bridge.EventSeverity.info,
  int timestamp = 1,
  String? deviceId,
}) => switch (path) {
  EventPath.ffi => ffiWireEvent(
    payload,
    severity: severity,
    timestamp: timestamp,
    deviceId: deviceId,
  ),
  EventPath.network => networkWireEvent(
    payload,
    severity: severity,
    timestamp: timestamp,
    deviceId: deviceId,
  ),
};

/// An event of a type no producer of this release sends, for the rows that
/// show a reader ignores it.
SkotiqEvent unsentWireEvent(
  EventCategory category,
  String eventType, [
  Map<String, dynamic> data = const {},
]) => SkotiqEvent(
  timestamp: 1,
  severity: EventSeverity.info,
  category: category,
  eventType: eventType,
  data: data,
);
