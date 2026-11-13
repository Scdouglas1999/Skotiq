import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/events.dart';

import 'event_wire_samples.g.dart';

EventCategory _family(EventPayload payload) => switch (payload) {
  EventPayload_Equipment() => EventCategory.equipment,
  EventPayload_Imaging() || EventPayload_DepthLock() => EventCategory.imaging,
  EventPayload_Guiding() => EventCategory.guiding,
  EventPayload_Sequencer() => EventCategory.sequencer,
  EventPayload_Safety() => EventCategory.safety,
  EventPayload_System() => EventCategory.system,
  EventPayload_PolarAlignment() ||
  EventPayload_PolarAlignmentStatus() ||
  EventPayload_PolarAlignmentImage() => EventCategory.polarAlignment,
};

/// What a client receives: the data after the JSON envelope.
Map<String, Object?> _overTheWire(Map<String, Object?> data) =>
    (jsonDecode(
              jsonEncode(
                data,
                toEncodable: (value) =>
                    value is Uint8List ? base64Encode(value) : value,
              ),
            )
            as Map)
        .cast<String, Object?>();

EventPayload? _decode(
  EventCategory family,
  String type,
  Map<String, Object?> data, {
  EventSeverity severity = EventSeverity.info,
}) => decodeEventPayload(family, type, data, severity: severity);

void _expectWire(EventPayload payload, String type, Map<String, Object?> data) {
  final sent = encodeEventPayload(payload);
  expect(sent.$1, type);
  expect(sent.$2, data);
}

void main() {
  test('the generated codec is the one the event unions generate', () {
    final result = Process.runSync('dart', [
      'run',
      'tool/generate_event_wire.dart',
      '--check',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  });

  test('every event variant a host sends is the same variant on a client', () {
    for (final sample in eventWireSamples) {
      final (type, data) = encodeEventPayload(sample);
      final received = _decode(_family(sample), type, _overTheWire(data));
      // A pass report's details are JSON text; the sample's are not.
      if (sample case EventPayload_Imaging(
        field0: ImagingEvent_IntegrationTelemetry(),
      )) {
        expect(received, isA<EventPayload_Imaging>());
        continue;
      }
      expect('$received', '$sample', reason: type);
      expect(eventWireTypes[_family(sample)], contains(type));
    }
  });

  test('the names other readers know are the names sent', () {
    _expectWire(
      const EventPayload.guiding(
        GuidingEvent.correction(ra: 1, dec: 2, raRaw: 3, decRaw: 4),
      ),
      'GuideStep',
      {
        'RADistance': 1.0,
        'DECDistance': 2.0,
        'RADistanceRaw': 3.0,
        'DECDistanceRaw': 4.0,
      },
    );
    _expectWire(
      const EventPayload.guiding(GuidingEvent.lostStar()),
      'StarLost',
      <String, Object?>{},
    );
    _expectWire(
      const EventPayload.guiding(GuidingEvent.settled(rms: 0.5)),
      'SettleDone',
      {'rms': 0.5},
    );
    _expectWire(
      const EventPayload.sequencer(SequencerEvent.failed(error: 'x')),
      'SequenceFailed',
      {'error': 'x'},
    );
    _expectWire(
      const EventPayload.imaging(
        ImagingEvent.exposureStartedWithFrame(
          durationSecs: 30,
          frameType: FrameType.darkFlat,
          frameNumber: 2,
          totalFrames: 5,
        ),
      ),
      'ExposureStarted',
      {'duration_secs': 30.0, 'frame_type': 'darkFlat', 'frame': 2, 'total': 5},
    );
    expect(
      encodeEventPayload(
        const EventPayload.sequencer(
          SequencerEvent.meridianFlipOutcome(
            outcome: FlipOutcome.pierChanged,
            targetName: 'M42',
            newPierSide: 'East',
            durationSecs: 0,
            attempts: 1,
            failedSteps: [],
          ),
        ),
      ).$2['outcome'],
      'pier_changed',
    );
    _expectWire(
      const EventPayload.equipment(
        EquipmentEvent.propertyChanged(
          deviceType: 'Focuser',
          deviceId: 'f',
          property: 'AutofocusProgress',
          value: '{}',
        ),
      ),
      'AutofocusProgress',
      {'device_type': 'Focuser', 'device_id': 'f', 'detail': '{}'},
    );
    expect(
      eventWireTypes[EventCategory.imaging],
      containsAll(['DepthLockGoalUpdated', 'ExposureFailed']),
    );
    final goal = encodeEventPayload(
      eventWireSamples.firstWhere(
        (sample) =>
            sample is EventPayload_DepthLock &&
            sample.field0 is DepthLockEvent_GoalUpdated,
      ),
    );
    expect(goal.$1, 'DepthLockGoalUpdated');
    expect(goal.$2['revision'], isA<int>());
    expect(goal.$2, contains('framesRemaining'));
    expect(goal.$2, isNot(contains('frames_remaining')));

    // The frame's capture record is written beside the frame's own fields;
    // the images table and the run record read these keys.
    final frame = encodeEventPayload(
      eventWireSamples.firstWhere(
        (sample) =>
            sample is EventPayload_Sequencer &&
            sample.field0 is SequencerEvent_FrameAccepted,
      ),
    );
    expect(
      frame.$2.keys,
      containsAll([
        'gain',
        'gain_is_iso',
        'offset',
        'sensor_temp_c',
        'cooler_power_percent',
        'mount_ra_hours',
        'mount_dec_degrees',
        'mount_altitude_deg',
        'mount_azimuth_deg',
        'pier_side',
        'focuser_position',
        'focuser_temperature_c',
        'rotator_angle_deg',
        'exposure_secs',
        'bin_x',
        'bin_y',
        'frame_type',
        'target_id',
        'save_path',
      ]),
    );
  });

  test('an event type this build does not know is no event', () {
    expect(_decode(EventCategory.sequencer, 'NewerHostEvent', {}), isNull);
    expect(_decode(EventCategory.system, 'HostStateChanged', {}), isNull);
  });

  test('an event without a count it needs is refused', () {
    expect(
      () => _decode(EventCategory.sequencer, 'ExposureStarted', {
        'duration_secs': 30.0,
      }),
      throwsFormatException,
    );
  });

  test('every stop a row records reaches a client as that stop', () {
    for (final stop in const [
      SequencerStop.cancelled(),
      SequencerStop.operator_(),
      SequencerStop.autopilot(),
      SequencerStop.system(origin: 'disk-watchdog'),
      SequencerStop.trigger(triggerId: 'weather', triggerName: 'Weather'),
    ]) {
      final row = EventPayload.sequencer(
        SequencerEvent.decisionLogged(
          timestampIso: '2026-11-13T03:00:00Z',
          category: 'system_event',
          // Words that name no stop: the stop travels as itself.
          summary: 'Reworded',
          detailsJson: '{}',
          stop: stop,
        ),
      );
      final (type, data) = encodeEventPayload(row);
      expect(_decode(EventCategory.sequencer, type, _overTheWire(data)), row);
    }
  });

  group('a host from before a field existed', () {
    SequencerEvent sequencer(
      String type,
      Map<String, Object?> data, {
      EventSeverity severity = EventSeverity.info,
    }) =>
        (_decode(EventCategory.sequencer, type, data, severity: severity)!
                as EventPayload_Sequencer)
            .field0;

    test('sends an error without a kind: a warning is a note', () {
      expect(
        sequencer('Error', {
          'message': 'Dew heater draws 0 W',
        }, severity: EventSeverity.warning),
        const SequencerEvent.error(
          message: 'Dew heater draws 0 W',
          kind: SequencerErrorKind.advisory,
        ),
      );
      expect(
        sequencer('Error', {
          'error': 'Slew failed',
        }, severity: EventSeverity.error),
        const SequencerEvent.error(
          message: 'Slew failed',
          kind: SequencerErrorKind.stepFailed,
        ),
      );
    });

    test('marks a continued happening only by its words', () {
      final row =
          sequencer('DecisionLogged', {
                'timestamp_iso': '2026-11-12T03:00:00Z',
                'category': 'system_event',
                'summary': 'Frames rejected in a row — the run continues',
                'details_json':
                    '{"consecutive_rejects":4,"reason":"star count 3 below '
                    'minimum 20"}',
              })
              as SequencerEvent_DecisionLogged;
      expect(
        row.notice,
        const SequencerNotice.rejectStreak(
          consecutiveRejects: 4,
          reason: 'star count 3 below minimum 20',
        ),
      );

      final warning =
          sequencer('Error', {
                'message':
                    'Autofocus did not converge. The focuser was returned to '
                    'position 2500 and imaging continues on the last-good '
                    'focus.',
              }, severity: EventSeverity.warning)
              as SequencerEvent_Error;
      expect(warning.notice, const SequencerNotice.autofocusContinued());
    });

    test('sends a cancellation as a failing step with a fixed notice', () {
      for (final data in [
        {'message': 'Sequence cancelled'},
        {'message': 'Sequence cancelled', 'kind': 'step_failed'},
      ]) {
        expect(
          (sequencer('Error', data, severity: EventSeverity.error)
                  as SequencerEvent_Error)
              .kind,
          SequencerErrorKind.cancelled,
        );
      }
      // A fault that only contains the word stays a fault.
      expect(
        (sequencer('Error', {
                  'message': 'Sequence cancelled by the dome roof interlock',
                }, severity: EventSeverity.error)
                as SequencerEvent_Error)
            .kind,
        SequencerErrorKind.stepFailed,
      );
    });

    test('says who stopped a run only in its stop rows\' words', () {
      SequencerStop? stopOf(Map<String, Object?> row) =>
          (sequencer('DecisionLogged', {'details_json': '{}', ...row})
                  as SequencerEvent_DecisionLogged)
              .stop;

      expect(
        stopOf({
          'category': 'manual_intervention',
          'summary': 'Operator: stop requested',
        }),
        const SequencerStop.operator_(),
      );
      expect(
        stopOf({'category': 'system_event', 'summary': 'Autopilot: stop'}),
        const SequencerStop.autopilot(),
      );
      expect(
        stopOf({
          'category': 'system_event',
          'summary': 'System: stop',
          'details_json': '{"origin":"rollback","action":"stop"}',
        }),
        const SequencerStop.system(origin: 'rollback'),
      );
      expect(
        stopOf({
          'category': 'trigger_fired',
          'summary': 'Dawn Approaching fired: park and end the run',
          'details_json':
              '{"trigger_id":"dawn_approaching","trigger_name":"Dawn '
              'Approaching","action":"ParkAndAbort"}',
        }),
        const SequencerStop.trigger(
          triggerId: 'dawn_approaching',
          triggerName: 'Dawn Approaching',
        ),
      );
      expect(
        stopOf({
          'category': 'system_event',
          'summary': 'Sequence cancelled',
          'details_json': '{"phase":"cancelled"}',
        }),
        const SequencerStop.cancelled(),
      );
      // A pause, a dither trigger, an end without parking: no stop.
      expect(
        stopOf({
          'category': 'manual_intervention',
          'summary': 'Operator: pause',
        }),
        isNull,
      );
      expect(
        stopOf({
          'category': 'trigger_fired',
          'summary': 'Dither fired: dither',
          'details_json':
              '{"trigger_id":"d","trigger_name":"D","action":"Dither"}',
        }),
        isNull,
      );
      expect(
        stopOf({
          'category': 'trigger_fired',
          'summary': 'Dawn fired: end the run',
          'details_json':
              '{"trigger_id":"d","trigger_name":"D","action":"Abort"}',
        }),
        isNull,
      );
    });

    test('names a notice without its fields: the row holds them', () {
      final row =
          sequencer('DecisionLogged', {
                'category': 'system_event',
                'summary': 'Reworded',
                'details_json': '{"source":"Center","problem":"no solve"}',
                'notice': 'problem_noticed',
              })
              as SequencerEvent_DecisionLogged;
      expect(
        row.notice,
        const SequencerNotice.problemNoticed(
          source: 'Center',
          problem: 'no solve',
        ),
      );
    });

    test('sends a frame without its capture record', () {
      final frame =
          sequencer('FrameAccepted', {
                'node_id': 'n',
                'frame': 1,
                'total': 2,
                'accepted_total': 1,
                'rejected_total': 0,
              })
              as SequencerEvent_FrameAccepted;
      expect(frame.capture.binX, 1);
      expect(frame.capture.frameType, 'light');
      expect(frame.capture.gain, isNull);
    });

    test('names the run states with their older names', () {
      expect(sequencer('SequencePaused', {}), const SequencerEvent.paused());
      expect(
        sequencer('SequenceCompleted', {}),
        const SequencerEvent.completed(),
      );
    });
  });
}
