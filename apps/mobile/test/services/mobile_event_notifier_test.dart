import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/backend.dart' show wireEventFromTyped;
import 'package:skotiq_core/bridge_events.dart' as sk;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_mobile/services/mobile_event_notifier.dart';
import 'package:skotiq_mobile/services/mobile_preferences.dart';
import 'package:skotiq_mobile/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A test double that records every notify call instead of touching the
/// flutter_local_notifications plugin (which has no host-side
/// implementation in unit tests).
class _RecordingNotificationService implements MobileNotificationSink {
  final List<NotifyCall> calls = <NotifyCall>[];

  @override
  Future<void> notifySequenceComplete(String targetName, int imageCount) async {
    calls.add(
      NotifyCall('sequenceComplete', {
        'target': targetName,
        'count': imageCount,
      }),
    );
  }

  @override
  Future<void> notifySequenceFailed({
    required String title,
    required String body,
  }) async {
    calls.add(NotifyCall('sequenceFailed', {'title': title, 'body': body}));
  }

  @override
  Future<void> notifySafety({
    required String title,
    required String body,
  }) async {
    calls.add(NotifyCall('safety', {'title': title, 'body': body}));
  }

  @override
  Future<void> notifyMountFault({
    required String title,
    required String body,
  }) async {
    calls.add(NotifyCall('mountFault', {'title': title, 'body': body}));
  }

  @override
  Future<void> notifyGuidingLost(String reason) async {
    calls.add(NotifyCall('guidingLost', {'reason': reason}));
  }

  @override
  Future<void> notifyExposureFailed(String errorMessage) async {
    calls.add(NotifyCall('exposureFailed', {'error': errorMessage}));
  }

  @override
  Future<void> notifyAutofocusFailed() async {
    calls.add(const NotifyCall('autofocusFailed', <String, Object?>{}));
  }

  @override
  Future<void> notifyEquipmentDisconnected(
    String deviceType,
    String deviceId,
  ) async {
    calls.add(
      NotifyCall('equipmentDisconnected', {
        'deviceType': deviceType,
        'deviceId': deviceId,
      }),
    );
  }

  @override
  Future<void> notifyTargetCompleted(String targetName) async {
    calls.add(NotifyCall('targetCompleted', {'targetName': targetName}));
  }

  @override
  Future<void> notifyLowDiskSpace(String message) async {
    calls.add(NotifyCall('lowDiskSpace', {'message': message}));
  }

  @override
  Future<void> notifyLowBattery(int percentage) async {
    calls.add(NotifyCall('lowBattery', {'pct': percentage}));
  }

  @override
  Future<void> notifyMeridianFlip(String targetName, DateTime flipTime) async {
    calls.add(NotifyCall('meridianFlip', {'target': targetName}));
  }

  @override
  Future<void> notifyPush(Map<String, dynamic> data) async {
    calls.add(NotifyCall('push', Map<String, Object?>.from(data)));
  }

  @override
  Future<void> notifyPlateSolveFailed(String errorMessage) async {
    calls.add(NotifyCall('plateSolveFailed', {'error': errorMessage}));
  }

  @override
  Future<void> notifyCenteringFailed(String errorMessage) async {
    calls.add(NotifyCall('centeringFailed', {'error': errorMessage}));
  }

  @override
  Future<void> notifyPolarAlignmentFailed(String errorMessage) async {
    calls.add(NotifyCall('polarAlignmentFailed', {'error': errorMessage}));
  }

  @override
  Future<void> notifyOwnershipTakenOver({
    String? displacingClientName,
    String? reason,
  }) async {
    calls.add(
      NotifyCall('ownershipTakenOver', {
        if (displacingClientName != null)
          'displacingClientName': displacingClientName,
        if (reason != null) 'reason': reason,
      }),
    );
  }

  @override
  Future<void> notifyOwnershipAutoReleased(String reason) async {
    calls.add(NotifyCall('ownershipAutoReleased', {'reason': reason}));
  }
}

class NotifyCall {
  final String kind;
  final Map<String, Object?> data;
  const NotifyCall(this.kind, this.data);

  @override
  String toString() => 'NotifyCall($kind, $data)';
}

SkotiqEvent _ev(
  EventCategory category,
  String type, {
  Map<String, dynamic>? data,
  EventSeverity severity = EventSeverity.warning,
}) {
  return SkotiqEvent(
    timestamp: DateTime.now().millisecondsSinceEpoch,
    severity: severity,
    category: category,
    eventType: type,
    data: data ?? const <String, dynamic>{},
  );
}

/// [payload] as a host sends it: encoded to the wire, through JSON, and read
/// back the way a linked phone's backend reads it.
SkotiqEvent _fromHost(
  sk.EventCategory category,
  sk.EventPayload payload, {
  sk.EventSeverity severity = sk.EventSeverity.warning,
}) {
  final wire = wireEventFromTyped(
    sk.SkotiqEvent(
      eventId: BigInt.zero,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      severity: severity,
      category: category,
      payload: payload,
    ),
  );
  return SkotiqEvent.fromWireJson(
    jsonDecode(jsonEncode(wire.toJson())) as Map<String, dynamic>,
  );
}

void main() {
  late StreamController<SkotiqEvent> eventStream;
  late _RecordingNotificationService notifications;
  late MobileEventNotifier notifier;
  late MobilePreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final raw = await SharedPreferences.getInstance();
    prefs = MobilePreferences(raw);
    eventStream = StreamController<SkotiqEvent>.broadcast();
    notifications = _RecordingNotificationService();
    notifier = MobileEventNotifier(
      eventStream: eventStream.stream,
      preferences: prefs,
      notificationService: notifications,
    );
    notifier.start();
  });

  tearDown(() async {
    await notifier.stop();
    await eventStream.close();
  });

  Future<void> emit(SkotiqEvent event) async {
    eventStream.add(event);
    // The subscriber handles asynchronously; let the broadcast deliver and
    // the async _handle complete before assertions.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> emitTyped(
    sk.EventCategory category,
    sk.EventPayload payload, {
    sk.EventSeverity severity = sk.EventSeverity.warning,
  }) => emit(_fromHost(category, payload, severity: severity));

  Future<void> emitEquipment(
    sk.EquipmentEvent event, {
    sk.EventSeverity severity = sk.EventSeverity.error,
  }) => emitTyped(
    sk.EventCategory.equipment,
    sk.EventPayload.equipment(event),
    severity: severity,
  );

  group('Safety', () {
    test('weather unsafe raises the safety alarm', () async {
      await emitTyped(
        sk.EventCategory.safety,
        const sk.EventPayload.safety(
          sk.SafetyEvent.weatherUnsafe(reason: 'High wind 45 km/h'),
        ),
        severity: sk.EventSeverity.critical,
      );
      expect(notifications.calls.single.kind, 'safety');
      expect(notifications.calls.single.data['title'], 'Weather unsafe');
    });

    test('an emergency stop and a park raise the safety alarm too', () async {
      await emitTyped(
        sk.EventCategory.safety,
        const sk.EventPayload.safety(
          sk.SafetyEvent.emergencyStop(reason: 'Operator panic stop'),
        ),
      );
      expect(notifications.calls.single.kind, 'safety');
    });

    test('weather safe again is silent', () async {
      await emitTyped(
        sk.EventCategory.safety,
        const sk.EventPayload.safety(sk.SafetyEvent.weatherSafe()),
      );
      expect(notifications.calls, isEmpty);
    });

    test('respects the safety mute', () async {
      await prefs.setNotifySafety(false);
      await emitTyped(
        sk.EventCategory.safety,
        const sk.EventPayload.safety(
          sk.SafetyEvent.weatherUnsafe(reason: 'rain'),
        ),
      );
      expect(notifications.calls, isEmpty);
    });

    test('a repeat inside the window buzzes once', () async {
      for (var i = 0; i < 2; i++) {
        await emitTyped(
          sk.EventCategory.safety,
          const sk.EventPayload.safety(
            sk.SafetyEvent.weatherUnsafe(reason: 'rain'),
          ),
        );
      }
      expect(notifications.calls, hasLength(1));
    });
  });

  group('Guiding', () {
    test('a lost star raises guiding lost', () async {
      await emitTyped(
        sk.EventCategory.guiding,
        const sk.EventPayload.guiding(sk.GuidingEvent.lostStar()),
      );
      expect(notifications.calls.single.kind, 'guidingLost');
    });

    test('the guider disconnecting raises guiding lost', () async {
      await emitTyped(
        sk.EventCategory.guiding,
        const sk.EventPayload.guiding(sk.GuidingEvent.disconnected()),
      );
      expect(notifications.calls.single.kind, 'guidingLost');
    });

    test('the operator disconnecting the guider is silent', () async {
      // The host publishes a disconnect it was asked for at info.
      await emitTyped(
        sk.EventCategory.guiding,
        const sk.EventPayload.guiding(sk.GuidingEvent.disconnected()),
        severity: sk.EventSeverity.info,
      );
      expect(notifications.calls, isEmpty);
    });

    test('respects the guiding mute', () async {
      await prefs.setNotifyGuiding(false);
      await emitTyped(
        sk.EventCategory.guiding,
        const sk.EventPayload.guiding(sk.GuidingEvent.lostStar()),
      );
      expect(notifications.calls, isEmpty);
    });
  });

  group('Imaging', () {
    test('a failed exposure says why', () async {
      await emitTyped(
        sk.EventCategory.imaging,
        const sk.EventPayload.imaging(
          sk.ImagingEvent.exposureFailed(error: 'Readout timed out'),
        ),
      );
      expect(notifications.calls.single.kind, 'exposureFailed');
      expect(notifications.calls.single.data['error'], contains('Readout'));
    });

    test('respects the exposure-failed mute', () async {
      await prefs.setNotifyExposureFailed(false);
      await emitTyped(
        sk.EventCategory.imaging,
        const sk.EventPayload.imaging(
          sk.ImagingEvent.exposureFailed(error: 'x'),
        ),
      );
      expect(notifications.calls, isEmpty);
    });
  });

  group('Equipment', () {
    test(
      'a device the heartbeat gave up on is reported disconnected',
      () async {
        // What the host's heartbeat sends when a device stops answering.
        await emitEquipment(
          const sk.EquipmentEvent.heartbeatStatusChanged(
            deviceType: 'focuser',
            deviceId: 'sim_focuser_1',
            status: sk.HeartbeatStatus.disconnected,
            consecutiveFailures: 3,
          ),
        );
        await emitEquipment(
          const sk.EquipmentEvent.error(
            deviceType: 'focuser',
            deviceId: 'sim_focuser_1',
            message:
                'Device unresponsive after 3 heartbeat failures: timed out',
          ),
        );
        expect(notifications.calls, hasLength(1));
        expect(notifications.calls.single.kind, 'equipmentDisconnected');
        expect(notifications.calls.single.data['deviceType'], 'focuser');
      },
    );

    test('a disconnect names the device', () async {
      await emitEquipment(
        const sk.EquipmentEvent.disconnected(
          deviceType: 'camera',
          deviceId: 'sim_camera_1',
        ),
      );
      expect(notifications.calls.single.kind, 'equipmentDisconnected');
      expect(notifications.calls.single.data['deviceId'], isNotEmpty);
    });

    test('a connect that does not succeed is not a disconnect', () async {
      await emitEquipment(
        const sk.EquipmentEvent.connecting(
          deviceType: 'focuser',
          deviceId: 'sim_focuser_1',
          deviceName: 'Focuser Simulator',
        ),
        severity: sk.EventSeverity.info,
      );
      await emitEquipment(
        const sk.EquipmentEvent.error(
          deviceType: 'focuser',
          deviceId: 'sim_focuser_1',
          message: 'No power',
        ),
      );
      expect(notifications.calls, isEmpty);
    });

    test('a notice about a connected camera is not a disconnect', () async {
      // What the host sends right after a camera that reports no pixel size
      // connects.
      await emitEquipment(
        const sk.EquipmentEvent.connected(
          deviceType: 'camera',
          deviceId: 'gphoto2:canon_eos_rp',
          deviceName: 'Canon EOS RP',
        ),
        severity: sk.EventSeverity.info,
      );
      await emitEquipment(
        const sk.EquipmentEvent.error(
          deviceType: 'camera',
          deviceId: 'gphoto2:canon_eos_rp',
          message:
              'Canon EOS RP does not report its pixel size. Enter it in the '
              'optical train so plate solving has a scale.',
        ),
        severity: sk.EventSeverity.warning,
      );
      expect(notifications.calls, isEmpty);
    });

    test('the operator disconnecting a device is silent', () async {
      await emitEquipment(
        const sk.EquipmentEvent.disconnected(
          deviceType: 'camera',
          deviceId: 'sim_camera_1',
        ),
        severity: sk.EventSeverity.info,
      );
      expect(notifications.calls, isEmpty);
    });

    test('respects the equipment mute', () async {
      await prefs.setNotifyEquipmentDisconnected(false);
      await emitEquipment(
        const sk.EquipmentEvent.disconnected(
          deviceType: 'camera',
          deviceId: 'sim_camera_1',
        ),
      );
      expect(notifications.calls, isEmpty);
    });
  });

  group('Sequencer', () {
    sk.EventPayload decision({sk.SequencerNotice? notice}) =>
        sk.EventPayload.sequencer(
          sk.SequencerEvent.decisionLogged(
            timestampIso: '2026-11-13T02:00:00Z',
            category: 'autofocus',
            summary: 'Autofocus did not converge; continuing on the last focus',
            detailsJson: '{}',
            notice: notice,
          ),
        );

    test(
      'an autofocus the run carried on through raises autofocus failed',
      () async {
        await emitTyped(
          sk.EventCategory.sequencer,
          decision(notice: const sk.SequencerNotice.autofocusContinued()),
          severity: sk.EventSeverity.info,
        );
        expect(notifications.calls.single.kind, 'autofocusFailed');
      },
    );

    test('a decision row with no notice is silent', () async {
      await emitTyped(
        sk.EventCategory.sequencer,
        decision(),
        severity: sk.EventSeverity.info,
      );
      expect(notifications.calls, isEmpty);
    });

    test('respects the autofocus mute', () async {
      await prefs.setNotifyAutofocusFailed(false);
      await emitTyped(
        sk.EventCategory.sequencer,
        decision(notice: const sk.SequencerNotice.autofocusContinued()),
      );
      expect(notifications.calls, isEmpty);
    });

    test('a finished target is named', () async {
      await emitTyped(
        sk.EventCategory.sequencer,
        const sk.EventPayload.sequencer(
          sk.SequencerEvent.targetCompleted(targetName: 'M31'),
        ),
      );
      expect(notifications.calls.single.kind, 'targetCompleted');
      expect(notifications.calls.single.data['targetName'], 'M31');
    });

    sk.EventPayload flip(sk.FlipOutcome outcome, {int attempts = 1}) =>
        sk.EventPayload.sequencer(
          sk.SequencerEvent.meridianFlipOutcome(
            outcome: outcome,
            targetName: 'M31',
            newPierSide: 'West',
            durationSecs: 240,
            attempts: attempts,
            failedSteps: const [],
            actionTaken: 'continued',
          ),
        );

    test('a meridian flip alerts once, from its verdict', () async {
      // Progress of the flip step, a retry notice among it, and the mount
      // reaching its new side all come before the verdict.
      for (final detail in [
        'Flipping',
        'Meridian flip attempt 2/4 failed, retrying',
      ]) {
        await emitTyped(
          sk.EventCategory.sequencer,
          sk.EventPayload.sequencer(
            sk.SequencerEvent.instructionProgress(
              nodeId: 'flip',
              instruction: 'Meridian flip',
              progressPercent: 50,
              detail: detail,
            ),
          ),
          severity: sk.EventSeverity.info,
        );
      }
      await emitTyped(
        sk.EventCategory.sequencer,
        flip(sk.FlipOutcome.pierChanged),
        severity: sk.EventSeverity.info,
      );
      expect(notifications.calls, isEmpty);

      await emitTyped(
        sk.EventCategory.sequencer,
        flip(sk.FlipOutcome.success, attempts: 2),
        severity: sk.EventSeverity.warning,
      );
      expect(notifications.calls.single.kind, 'meridianFlip');
      expect(notifications.calls.single.data['target'], 'M31');
    });

    test('a flip that failed is not told as performed', () async {
      await emitTyped(
        sk.EventCategory.sequencer,
        flip(sk.FlipOutcome.failed, attempts: 4),
        severity: sk.EventSeverity.critical,
      );
      expect(notifications.calls, isEmpty);
    });

    test('a failed run pages the phone with its reason', () async {
      await emitTyped(
        sk.EventCategory.sequencer,
        const sk.EventPayload.sequencer(
          sk.SequencerEvent.failed(error: 'Mount did not answer'),
        ),
        severity: sk.EventSeverity.error,
      );
      final call = notifications.calls.single;
      expect(call.kind, 'sequenceFailed');
      expect(call.data['title'], 'Sequence failed');
      expect(call.data['body'], contains('Mount did not answer'));
    });

    test('recovery giving up pages the phone', () async {
      await emitTyped(
        sk.EventCategory.sequencer,
        const sk.EventPayload.sequencer(
          sk.SequencerEvent.recoveryGaveUp(
            startedAtIso: '2026-11-15T03:00:00Z',
            causeKind: 'GuideStarLost',
            attemptCount: 3,
            maxAttempts: 3,
            retryIntervalSecs: 60,
            maxDurationSecs: 900,
            phase: 'GaveUp',
            abortedByUser: false,
          ),
        ),
        severity: sk.EventSeverity.critical,
      );
      expect(notifications.calls.single.kind, 'sequenceFailed');
      expect(notifications.calls.single.data['title'], 'Recovery gave up');
    });

    test('respects the sequence mute', () async {
      await prefs.setNotifySequence(false);
      await emitTyped(
        sk.EventCategory.sequencer,
        const sk.EventPayload.sequencer(sk.SequencerEvent.failed(error: 'x')),
        severity: sk.EventSeverity.error,
      );
      expect(notifications.calls, isEmpty);
    });
  });

  group('Mount', () {
    test('a mount fault raises the mount alarm', () async {
      await emitTyped(
        sk.EventCategory.safety,
        const sk.EventPayload.safety(
          sk.SafetyEvent.mountMotionFault(
            deviceId: 'sim_mount_1',
            kind: 'runaway',
            message: 'Dec axis moving at 4 deg/s with no command',
          ),
        ),
        severity: sk.EventSeverity.critical,
      );
      final call = notifications.calls.single;
      expect(call.kind, 'mountFault');
      expect(call.data['body'], contains('Dec axis'));
    });

    test('the host push for the same fault is not doubled', () async {
      notifier.recordPushReceived(NotificationCategory.mountFault.storageKey);
      await emitTyped(
        sk.EventCategory.safety,
        const sk.EventPayload.safety(
          sk.SafetyEvent.mountMotionFault(
            deviceId: 'sim_mount_1',
            kind: 'runaway',
            message: 'x',
          ),
        ),
        severity: sk.EventSeverity.critical,
      );
      expect(notifications.calls, isEmpty);
    });
  });

  group('System', () {
    test('low disk space raises the disk alert', () async {
      await emitTyped(
        sk.EventCategory.system,
        const sk.EventPayload.system(
          sk.SystemEvent.diskSpaceLow(availableGb: 1.5),
        ),
      );
      expect(notifications.calls.single.kind, 'lowDiskSpace');
    });

    test('respects the disk mute', () async {
      await prefs.setNotifyDiskLow(false);
      await emitTyped(
        sk.EventCategory.system,
        const sk.EventPayload.system(
          sk.SystemEvent.diskSpaceLow(availableGb: 1.5),
        ),
      );
      expect(notifications.calls, isEmpty);
    });
  });

  group('Host push dedupe', () {
    // The host's push carries the notification category's storage key as
    // its `eventType`.
    test('a direct alert right after the host pushed it is skipped', () async {
      notifier.recordPushReceived(
        NotificationCategory.weatherUnsafe.storageKey,
      );
      await emitTyped(
        sk.EventCategory.safety,
        const sk.EventPayload.safety(
          sk.SafetyEvent.weatherUnsafe(reason: 'rain'),
        ),
      );
      expect(notifications.calls, isEmpty);
    });

    test('a push about something else does not skip it', () async {
      notifier.recordPushReceived(
        NotificationCategory.sequenceCompleted.storageKey,
      );
      await emitTyped(
        sk.EventCategory.safety,
        const sk.EventPayload.safety(
          sk.SafetyEvent.weatherUnsafe(reason: 'rain'),
        ),
      );
      expect(notifications.calls, hasLength(1));
    });
  });

  group('Polar alignment category', () {
    test('PolarAlignment events are not surfaced as notifications', () async {
      await emit(_ev(EventCategory.polarAlignment, 'StatusUpdate'));
      expect(notifications.calls, isEmpty);
    });
  });

  group('Job category', () {
    test('JobStarted is silenced (no notification)', () async {
      await emit(
        _ev(
          EventCategory.job,
          'JobStarted',
          data: {'jobId': 'j1', 'operation': 'plate-solve', 'state': 'queued'},
          severity: EventSeverity.info,
        ),
      );
      expect(notifications.calls, isEmpty);
    });

    test('JobProgress is silenced (no notification)', () async {
      await emit(
        _ev(
          EventCategory.job,
          'JobProgress',
          data: {
            'jobId': 'j1',
            'operation': 'plate-solve',
            'state': 'running',
            'progress': 0.5,
          },
          severity: EventSeverity.info,
        ),
      );
      expect(notifications.calls, isEmpty);
    });

    test('JobCompleted is silenced (no notification)', () async {
      await emit(
        _ev(
          EventCategory.job,
          'JobCompleted',
          data: {
            'jobId': 'j1',
            'operation': 'plate-solve',
            'state': 'succeeded',
          },
          severity: EventSeverity.info,
        ),
      );
      expect(notifications.calls, isEmpty);
    });

    test('JobCancelled is silenced (user-triggered)', () async {
      await emit(
        _ev(
          EventCategory.job,
          'JobCancelled',
          data: {
            'jobId': 'j1',
            'operation': 'plate-solve',
            'state': 'cancelled',
          },
          severity: EventSeverity.warning,
        ),
      );
      expect(notifications.calls, isEmpty);
    });

    test(
      'JobFailed for plate-solve -> plateSolveFailed notification',
      () async {
        await emit(
          _ev(
            EventCategory.job,
            'JobFailed',
            data: {
              'jobId': 'j1',
              'operation': 'plate-solve',
              'state': 'failed',
              'error': {
                'code': 'no_stars',
                'message': 'No stars detected in frame',
              },
            },
            severity: EventSeverity.error,
          ),
        );
        expect(notifications.calls, hasLength(1));
        expect(notifications.calls.single.kind, 'plateSolveFailed');
        expect(
          notifications.calls.single.data['error'],
          'No stars detected in frame',
        );
      },
    );

    test('JobFailed for framing.center-on-target -> centeringFailed', () async {
      await emit(
        _ev(
          EventCategory.job,
          'JobFailed',
          data: {
            'jobId': 'j2',
            'operation': 'framing.center-on-target',
            'state': 'failed',
            'error': {
              'code': 'max_iterations',
              'message': 'Centering did not converge in 5 attempts',
            },
          },
          severity: EventSeverity.error,
        ),
      );
      expect(notifications.calls.single.kind, 'centeringFailed');
      expect(
        notifications.calls.single.data['error'],
        'Centering did not converge in 5 attempts',
      );
    });

    test(
      'JobFailed for polar-alignment.start -> polarAlignmentFailed',
      () async {
        await emit(
          _ev(
            EventCategory.job,
            'JobFailed',
            data: {
              'jobId': 'j3',
              'operation': 'polar-alignment.start',
              'state': 'failed',
              'error': {
                'code': 'mount_not_responding',
                'message': 'Mount stopped reporting position',
              },
            },
            severity: EventSeverity.error,
          ),
        );
        expect(notifications.calls.single.kind, 'polarAlignmentFailed');
      },
    );

    test(
      'JobFailed for polar-alignment.all-sky.start -> polarAlignmentFailed',
      () async {
        await emit(
          _ev(
            EventCategory.job,
            'JobFailed',
            data: {
              'jobId': 'j4',
              'operation': 'polar-alignment.all-sky.start',
              'state': 'failed',
              'error': {'message': 'Could not solve any of 4 frames'},
            },
            severity: EventSeverity.error,
          ),
        );
        expect(notifications.calls.single.kind, 'polarAlignmentFailed');
      },
    );

    test('JobFailed for focuser.autofocus -> autofocusFailed', () async {
      await emit(
        _ev(
          EventCategory.job,
          'JobFailed',
          data: {
            'jobId': 'j5',
            'operation': 'focuser.autofocus',
            'state': 'failed',
            'error': {'message': 'V-curve fit failed'},
          },
          severity: EventSeverity.error,
        ),
      );
      expect(notifications.calls.single.kind, 'autofocusFailed');
    });

    test('JobFailed for unknown operation -> no notification (but logs '
        'loudly)', () async {
      await emit(
        _ev(
          EventCategory.job,
          'JobFailed',
          data: {
            'jobId': 'j6',
            'operation': 'mystery.future.op',
            'state': 'failed',
            'error': {'message': 'something'},
          },
          severity: EventSeverity.error,
        ),
      );
      expect(notifications.calls, isEmpty);
    });

    test(
      'JobFailed for plate-solve respects notifyExposureFailed mute',
      () async {
        await prefs.setNotifyExposureFailed(false);
        await emit(
          _ev(
            EventCategory.job,
            'JobFailed',
            data: {
              'jobId': 'j7',
              'operation': 'plate-solve',
              'state': 'failed',
              'error': {'message': 'No stars'},
            },
            severity: EventSeverity.error,
          ),
        );
        expect(notifications.calls, isEmpty);
      },
    );

    test('JobFailed debounces repeats of same operation', () async {
      await emit(
        _ev(
          EventCategory.job,
          'JobFailed',
          data: {
            'jobId': 'j8',
            'operation': 'plate-solve',
            'state': 'failed',
            'error': {'message': 'No stars'},
          },
          severity: EventSeverity.error,
        ),
      );
      await emit(
        _ev(
          EventCategory.job,
          'JobFailed',
          data: {
            'jobId': 'j9',
            'operation': 'plate-solve',
            'state': 'failed',
            'error': {'message': 'No stars again'},
          },
          severity: EventSeverity.error,
        ),
      );
      expect(notifications.calls, hasLength(1));
    });
  });

  group('Session category', () {
    test('OwnershipTakenOver -> notification with displacing client', () async {
      await emit(
        _ev(
          EventCategory.session,
          'OwnershipTakenOver',
          data: {
            'clientId': 'tablet-uuid',
            'clientName': 'Observatory Tablet',
            'reason': 'forced',
            'claimedAt': '2026-05-24T03:00:00Z',
            'lastSeenAt': '2026-05-24T03:00:00Z',
          },
          severity: EventSeverity.warning,
        ),
      );
      expect(notifications.calls, hasLength(1));
      expect(notifications.calls.single.kind, 'ownershipTakenOver');
      expect(
        notifications.calls.single.data['displacingClientName'],
        'Observatory Tablet',
      );
      expect(notifications.calls.single.data['reason'], 'forced');
    });

    test('OwnershipAutoReleased -> info-level notification', () async {
      await emit(
        _ev(
          EventCategory.session,
          'OwnershipAutoReleased',
          data: {
            'clientId': 'phone-uuid',
            'reason': 'heartbeat_timeout',
            'timeoutSeconds': 60,
            'claimedAt': '2026-05-24T03:00:00Z',
            'lastSeenAt': '2026-05-24T03:01:00Z',
          },
          severity: EventSeverity.warning,
        ),
      );
      expect(notifications.calls.single.kind, 'ownershipAutoReleased');
      expect(notifications.calls.single.data['reason'], 'heartbeat_timeout');
    });

    test(
      'OwnershipClaimed -> ignored (the user themselves did this)',
      () async {
        await emit(
          _ev(
            EventCategory.session,
            'OwnershipClaimed',
            data: {
              'clientId': 'phone-uuid',
              'clientName': 'Phone',
              'claimedAt': '2026-05-24T03:00:00Z',
              'lastSeenAt': '2026-05-24T03:00:00Z',
            },
            severity: EventSeverity.info,
          ),
        );
        expect(notifications.calls, isEmpty);
      },
    );

    test('OwnershipReleased -> ignored (voluntary release)', () async {
      await emit(
        _ev(
          EventCategory.session,
          'OwnershipReleased',
          data: {
            'clientId': 'phone-uuid',
            'clientName': 'Phone',
            'claimedAt': '2026-05-24T03:00:00Z',
            'lastSeenAt': '2026-05-24T03:05:00Z',
          },
          severity: EventSeverity.info,
        ),
      );
      expect(notifications.calls, isEmpty);
    });
  });
}
