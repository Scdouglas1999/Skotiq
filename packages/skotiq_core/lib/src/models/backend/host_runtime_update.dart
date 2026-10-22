import 'package:flutter/foundation.dart';

import 'event_types.dart';
import 'host_mutation_event.dart';

/// Event type of a runtime-state update on the WebSocket `/events` stream.
///
/// The imaging host publishes one whenever a piece of runtime state that only
/// its GUI process computes changes (a plate-solve result, a centering run, an
/// autofocus result, the frame on screen, ...). Linked clients apply it to the
/// same providers their screens read, so they show what the host shows.
const String hostRuntimeStateEventType = 'HostRuntimeState';

/// True for the host-to-client sync envelopes, which are applied to providers
/// directly and are not telemetry: they must stay out of the typed event
/// stream, the event log and the toast bridge.
bool isHostSyncEnvelope(SkotiqEvent event) =>
    event.eventType == hostStateChangedEventType ||
    event.eventType == hostRuntimeStateEventType;

/// One channel's latest value, as the host publishes it.
///
/// [revision] increases with every publish on the host, across channels, and is
/// what a client uses to drop a value older than the one it already applied
/// (an event can race the hydration fetch of the same channel). [origin] names
/// the linked client whose report produced this value, so that client does not
/// apply its own result a second time.
@immutable
class HostRuntimeUpdate {
  const HostRuntimeUpdate({
    required this.channel,
    required this.revision,
    this.value,
    this.origin,
  });

  final String channel;
  final int revision;

  /// The channel's encoded value; null when the host has nothing to show.
  final Map<String, dynamic>? value;
  final String? origin;

  Map<String, dynamic> toJson() => {
    'channel': channel,
    'revision': revision,
    'value': value,
    if (origin != null) 'origin': origin,
  };

  /// Null when [json] is not a runtime update (a missing channel or revision).
  static HostRuntimeUpdate? fromJson(Map<String, dynamic> json) {
    final channel = json['channel'];
    final revision = json['revision'];
    if (channel is! String || channel.isEmpty || revision is! num) return null;
    final value = json['value'];
    final origin = json['origin'];
    return HostRuntimeUpdate(
      channel: channel,
      revision: revision.toInt(),
      value: value is Map ? Map<String, dynamic>.from(value) : null,
      origin: origin is String && origin.isNotEmpty ? origin : null,
    );
  }

  SkotiqEvent toEvent() => SkotiqEvent(
    timestamp: DateTime.now().millisecondsSinceEpoch,
    severity: EventSeverity.info,
    category: EventCategory.system,
    eventType: hostRuntimeStateEventType,
    data: toJson(),
  );
}
