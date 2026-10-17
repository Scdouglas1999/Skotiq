// What reaches an operator when a family mapper has no case for an event.
//
// Every variant of these five unions is mapped today, so the fallback fires
// only when the bridge gains a variant before the mapper learns it — exactly
// how the sequencer family put Dart source text on the wire (`toString()` of
// the generated union, constructor call and all, rendered on the run-watch
// feed during routine imaging). These pin the shared fallback for the other
// families: the event is NAMED by its variant, and the only prose beside it
// is a sentence written for a person.
//
// The mappers take `dynamic`, so each case hands in a stand-in whose runtime
// type name mimics a generated variant class — the only way to reach the
// fallback while every real variant has an arm.

// ignore_for_file: camel_case_types

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

class SafetyEvent_CloudSensorFault {}

class SystemEvent_ClockSkew {}

class EquipmentEvent_CoverCalibrator {}

class GuidingEvent_MultiStarLock {}

class ImagingEvent_SubframeShift {}

void main() {
  late FfiBackend backend;

  setUp(() => backend = FfiBackend());
  tearDown(() => backend.dispose());

  test('an unmapped event in any family carries its variant, not toString', () {
    final cases = <(String, String, (String, Map<String, dynamic>))>[
      (
        'UnknownSafetyEvent',
        'CloudSensorFault',
        backend.safetyEventInfoForTesting(SafetyEvent_CloudSensorFault()),
      ),
      (
        'UnknownSystemEvent',
        'ClockSkew',
        backend.systemEventInfoForTesting(SystemEvent_ClockSkew()),
      ),
      (
        'UnknownEquipmentEvent',
        'CoverCalibrator',
        backend.equipmentEventInfoForTesting(EquipmentEvent_CoverCalibrator()),
      ),
      (
        'UnknownGuidingEvent',
        'MultiStarLock',
        backend.guidingEventInfoForTesting(GuidingEvent_MultiStarLock()),
      ),
      (
        'UnknownImagingEvent',
        'SubframeShift',
        backend.imagingEventInfoForTesting(ImagingEvent_SubframeShift()),
      ),
    ];

    for (final (expectedType, expectedVariant, (eventType, data)) in cases) {
      expect(eventType, expectedType);
      expect(data['variant'], expectedVariant);
      expect(
        data['message'],
        contains(expectedVariant),
        reason: 'the sentence must name the event it is about',
      );
      for (final value in data.values) {
        expect(
          value.toString(),
          isNot(contains('Instance of')),
          reason:
              'a stringified object reached an operator-facing field of '
              '$expectedType: $value',
        );
      }
    }
  });

  test('a stand-in outside the naming convention still names itself', () {
    final (eventType, data) = backend.guidingEventInfoForTesting(Object());
    expect(eventType, 'UnknownGuidingEvent');
    expect(data['variant'], 'Object');
    expect(data['message'], contains('Object'));
  });
}
