import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart';
import 'package:skotiq_core/src/models/scheduler/scheduler_status.dart';
import 'package:skotiq_core/src/providers/scheduler_provider.dart';

SkotiqEvent _event(EventCategory category, EventPayload payload) => SkotiqEvent(
  eventId: BigInt.zero,
  timestamp: 0,
  severity: EventSeverity.info,
  category: category,
  payload: payload,
);

SchedulerTriggerEvent? _guiding(GuidingEvent event) => schedulerTriggerFor(
  _event(EventCategory.guiding, EventPayload.guiding(event)),
);

SchedulerTriggerEvent? _equipment(EquipmentEvent event) => schedulerTriggerFor(
  _event(EventCategory.equipment, EventPayload.equipment(event)),
);

void main() {
  group('guiding events', () {
    final cases = <String, (GuidingEvent, SchedulerTriggerEvent?)>{
      'guiding stopped': (
        const GuidingEvent.guidingStopped(),
        SchedulerTriggerEvent.guidingLost,
      ),
      'lost star': (
        const GuidingEvent.lostStar(),
        SchedulerTriggerEvent.guidingLost,
      ),
      'guiding started': (
        const GuidingEvent.guidingStarted(),
        SchedulerTriggerEvent.guidingRecovered,
      ),
      'settled': (
        const GuidingEvent.settled(rms: 0.4),
        SchedulerTriggerEvent.guidingRecovered,
      ),
      'dither started': (
        const GuidingEvent.ditherStarted(pixels: 5),
        SchedulerTriggerEvent.guidingRecovered,
      ),
      'stop reason run_stopped': (
        const GuidingEvent.stopReason(reason: 'run_stopped'),
        SchedulerTriggerEvent.guidingLost,
      ),
      'stop reason autofocus': (
        const GuidingEvent.stopReason(reason: 'autofocus'),
        null,
      ),
      'stop reason cleared': (const GuidingEvent.stopReason(), null),
      'settle timed out': (
        const GuidingEvent.settleTimedOut(error: 'Settling failed'),
        null,
      ),
      'dither completed': (const GuidingEvent.ditherCompleted(), null),
      'settling': (const GuidingEvent.settling(), null),
      'looping': (const GuidingEvent.looping(), null),
      'paused': (const GuidingEvent.paused(), null),
      'resumed': (const GuidingEvent.resumed(), null),
      'connected': (const GuidingEvent.connected(), null),
      'disconnected': (const GuidingEvent.disconnected(), null),
      'calibrating': (const GuidingEvent.calibrating(), null),
      'calibration complete': (const GuidingEvent.calibrationComplete(), null),
      'star selected': (const GuidingEvent.starSelected(x: 1, y: 2), null),
      'correction': (
        const GuidingEvent.correction(ra: 0, dec: 0, raRaw: 0, decRaw: 0),
        null,
      ),
      'guide stats': (
        const GuidingEvent.guideStats(snr: 20, starMass: 900),
        null,
      ),
    };
    for (final MapEntry(key: name, value: (event, trigger)) in cases.entries) {
      test(name, () => expect(_guiding(event), trigger));
    }
  });

  group('equipment events', () {
    final cases = <String, (EquipmentEvent, SchedulerTriggerEvent?)>{
      'park started': (
        const EquipmentEvent.mountParkStarted(deviceId: 'mount'),
        null,
      ),
      'park completed': (
        const EquipmentEvent.mountParkCompleted(deviceId: 'mount'),
        null,
      ),
      'unparked': (
        const EquipmentEvent.mountUnparked(deviceId: 'mount'),
        SchedulerTriggerEvent.mountParked,
      ),
      'error text naming a park': (
        const EquipmentEvent.error(
          deviceType: 'mount',
          deviceId: 'mount',
          message: 'Mount is parked',
        ),
        SchedulerTriggerEvent.mountParked,
      ),
      'slew completed': (
        const EquipmentEvent.mountSlewCompleted(
          deviceId: 'mount',
          ra: 1,
          dec: 2,
        ),
        null,
      ),
      'tracking stopped': (
        const EquipmentEvent.mountTrackingStopped(deviceId: 'mount'),
        null,
      ),
      'property changed': (
        const EquipmentEvent.propertyChanged(
          deviceType: 'dome',
          deviceId: 'dome',
          property: 'Park',
          value: '',
        ),
        null,
      ),
    };
    for (final MapEntry(key: name, value: (event, trigger)) in cases.entries) {
      test(name, () => expect(_equipment(event), trigger));
    }
  });

  test('a safety event is a weather change', () {
    expect(
      schedulerTriggerFor(
        _event(
          EventCategory.safety,
          const EventPayload.guiding(GuidingEvent.connected()),
        ),
      ),
      SchedulerTriggerEvent.weatherChange,
    );
  });
}
