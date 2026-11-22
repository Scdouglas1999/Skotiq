import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart';

import 'event_wire_samples.g.dart';

/// Which events the bridge calls critical (the persistent banner, the
/// audible alert), at each severity they could come with. Written from the
/// classification as it stands, so moving alarms to severity alone shows
/// here as the rows it changes.

EventCategory _categoryOf(EventPayload payload) => switch (payload) {
  EventPayload_Equipment() => EventCategory.equipment,
  EventPayload_Imaging() => EventCategory.imaging,
  EventPayload_Guiding() => EventCategory.guiding,
  EventPayload_Sequencer() => EventCategory.sequencer,
  EventPayload_Safety() => EventCategory.safety,
  EventPayload_System() => EventCategory.system,
  EventPayload_PolarAlignment() => EventCategory.polarAlignment,
  _ => EventCategory.system,
};

String _row(EventPayload payload) {
  final alarms = [
    for (final severity in EventSeverity.values)
      if (isCriticalEvent(
        SkotiqEvent(
          eventId: BigInt.zero,
          timestamp: 0,
          severity: severity,
          category: _categoryOf(payload),
          payload: payload,
        ),
      ))
        severity.name,
  ];
  final inner = switch (payload) {
    EventPayload_Sequencer(:final field0) => '$field0',
    _ => '${(payload as dynamic).field0}',
  };
  final name = inner.split('(').first;
  return '$name: ${alarms.join(',')}';
}

/// The events that alarm at more than critical severity today; every other
/// event alarms only when it comes critical.
const _beyondSeverity = {
  'ImagingEvent.exposureFailed: info,warning,error,critical',
  'ImagingEvent.exposureFailedOld: info,warning,error,critical',
  'SequencerEvent.failed: info,warning,error,critical',
  'SequencerEvent.error: error,critical',
  'SafetyEvent.weatherUnsafe: info,warning,error,critical',
  'SafetyEvent.emergencyStop: info,warning,error,critical',
  'SystemEvent.error: info,warning,error,critical',
  'SystemEvent.diskSpaceLow: info,warning,error,critical',
};

void main() {
  test('which events alarm, at which severity', () {
    final rows = <String>{for (final p in eventWireSamples) _row(p)};
    expect(
      rows.where((r) => !r.endsWith(': critical')).toSet(),
      _beyondSeverity,
    );
    expect(rows.length, greaterThan(100), reason: 'every variant is sampled');
  });
}
