import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/src/backend/bridge_event_mapper.dart';
import 'package:skotiq_core/src/backend/ffi_backend.dart';
import 'package:skotiq_core/src/models/backend/event_types.dart' as core;

/// A linked client rebuilds the typed event the host emitted from the
/// `(eventType, data)` envelope it receives on `/events`. Every variant the
/// host maps must come back as itself: a variant that falls to a placeholder
/// reads on the client as something the host never said (every sequencer
/// decision as a "Sequencer error", every exposure tick as "Exposure
/// complete").
core.SkotiqEvent _throughTheWire(
  (String, Map<String, dynamic>) info,
  core.EventCategory category,
) {
  final sent = core.SkotiqEvent(
    timestamp: 1757000000000,
    severity: core.EventSeverity.info,
    category: category,
    eventType: info.$1,
    data: info.$2,
  );
  return core.SkotiqEvent.fromWireJson(sent.toJson());
}

const _capture = bridge.FrameCaptureMetadata(
  gain: 100,
  offset: 50,
  sensorTempC: -10,
  coolerPowerPercent: 42,
  mountRaHours: 22.6,
  mountDecDegrees: 40,
  pierSide: 'east',
  focuserPosition: 6620,
  exposureSecs: 120,
  binX: 1,
  binY: 1,
  frameType: 'light',
  targetId: 't-1',
);

void main() {
  final backend = FfiBackend();

  void expectRoundTrip(
    Object original,
    (String, Map<String, dynamic>) info,
    core.EventCategory category,
    Object Function(bridge.EventPayload payload) unwrap,
  ) {
    final received = tryBridgeEventFromCoreEvent(
      _throughTheWire(info, category),
    );
    expect(received, isNotNull, reason: '${info.$1} was not read');
    expect(unwrap(received!.payload), original, reason: info.$1);
  }

  test('every sequencer variant survives the hop', () {
    final variants = <bridge.SequencerEvent>[
      const bridge.SequencerEvent.started(sequenceName: 'Night'),
      const bridge.SequencerEvent.paused(),
      const bridge.SequencerEvent.resumed(),
      const bridge.SequencerEvent.stopped(sequenceRunId: 12),
      const bridge.SequencerEvent.completed(),
      const bridge.SequencerEvent.failed(error: 'mount lost'),
      const bridge.SequencerEvent.nodeStarted(nodeId: 'n1', nodeType: 'Slew'),
      const bridge.SequencerEvent.nodeCompleted(
        nodeId: 'n1',
        status: 'success',
      ),
      const bridge.SequencerEvent.progress(current: 3, total: 9),
      const bridge.SequencerEvent.targetChanged(
        targetName: 'M31',
        ra: 0.71,
        dec: 41.2,
      ),
      const bridge.SequencerEvent.targetCompleted(targetName: 'M31'),
      const bridge.SequencerEvent.exposureStarted(
        frame: 2,
        total: 10,
        filter: 'Ha',
        durationSecs: 300,
      ),
      const bridge.SequencerEvent.exposureCompleted(
        frame: 2,
        total: 10,
        durationSecs: 300,
      ),
      const bridge.SequencerEvent.error(message: 'focuser timeout'),
      const bridge.SequencerEvent.meridianFlipOutcome(
        outcome: 'succeeded',
        targetName: 'M31',
        newPierSide: 'west',
        durationSecs: 95,
        attempts: 1,
        failedSteps: ['recenter'],
        actionTaken: 'continued',
      ),
      const bridge.SequencerEvent.triggerFired(
        triggerId: 't1',
        triggerName: 'Meridian Flip',
        action: 'flip',
      ),
      const bridge.SequencerEvent.instructionProgress(
        nodeId: 'n2',
        instruction: 'Slew',
        progressPercent: 40,
        detail: 'slewing',
      ),
      const bridge.SequencerEvent.instructionProgressStructured(
        nodeId: 'n2',
        instruction: 'Exposure',
        progressPercent: 50,
        detailKind: 'exposure',
        detailJson: '{"frame":2}',
      ),
      const bridge.SequencerEvent.frameAccepted(
        nodeId: 'n3',
        frame: 2,
        total: 10,
        hfr: 2.4,
        eccentricity: 0.3,
        starCount: 410,
        acceptedTotal: 2,
        rejectedTotal: 0,
        savePath: r'C:\data\M31_002.fits',
        capture: _capture,
      ),
      const bridge.SequencerEvent.frameRejected(
        nodeId: 'n3',
        frame: 3,
        total: 10,
        reason: 'hfr',
        hfr: 5.1,
        starCount: 40,
        rejectPath: r'C:\data\rejected\M31_003.fits',
        consecutiveRejects: 1,
        acceptedTotal: 2,
        rejectedTotal: 1,
        likelyCauseLabel: 'clouds',
        evidence: ['star count fell 90%'],
        cloudCoverAtCapture: 80,
        capture: _capture,
      ),
      const bridge.SequencerEvent.schedulerDecision(
        nodeId: 'n4',
        decisionCounter: 2,
        pickedTargetId: 't-1',
        pickedTargetName: 'M31',
        pickedScore: 0.8,
        scores: [
          bridge.SchedulerScoreEntry(
            targetId: 't-1',
            targetName: 'M31',
            totalScore: 0.8,
            runnable: true,
          ),
        ],
      ),
      const bridge.SequencerEvent.integrationBudget(
        targetId: 't-1',
        filter: 'Ha',
        completedSecs: 3600,
        budgetSecs: 7200,
        fraction: 0.5,
        budgetMet: false,
      ),
      const bridge.SequencerEvent.exposureAdjusted(
        nodeId: 'n3',
        adaptedSecs: 240,
        nominalSecs: 300,
        skyBrightnessMag: 19.8,
        filter: 'L',
        reason: 'sky brighter',
      ),
      const bridge.SequencerEvent.pluginNodeProgress(
        nodeId: 'n5',
        pluginId: 'p',
        nodeTypeId: 'x',
        detailJson: '{}',
      ),
      const bridge.SequencerEvent.decisionLogged(
        timestampIso: '2026-10-21T22:03:00Z',
        category: 'trigger',
        summary: 'trigger_fired',
        detailsJson: '{}',
        nodeId: 'n1',
        sequenceRunId: 12,
      ),
    ];
    for (final event in variants) {
      expectRoundTrip(
        event,
        backend.sequencerEventInfoForTesting(event),
        core.EventCategory.sequencer,
        (p) => (p as bridge.EventPayload_Sequencer).field0,
      );
    }
  });

  test('every imaging exposure variant survives the hop', () {
    final variants = <bridge.ImagingEvent>[
      const bridge.ImagingEvent.exposureStarted(
        durationSecs: 2,
        frameType: bridge.FrameType.light,
      ),
      const bridge.ImagingEvent.exposureStartedWithFrame(
        durationSecs: 2,
        frameType: bridge.FrameType.dark,
        frameNumber: 3,
        totalFrames: 9,
      ),
      const bridge.ImagingEvent.exposureProgress(
        progress: 0.5,
        remainingSecs: 1,
      ),
      const bridge.ImagingEvent.exposureCancelled(),
      const bridge.ImagingEvent.imageReady(width: 1920, height: 1080),
      const bridge.ImagingEvent.imageSaved(filePath: '/data/a.fits'),
      const bridge.ImagingEvent.exposureComplete(success: true),
    ];
    for (final event in variants) {
      expectRoundTrip(
        event,
        backend.imagingEventInfoForTesting(event),
        core.EventCategory.imaging,
        (p) => (p as bridge.EventPayload_Imaging).field0,
      );
    }
  });

  test('every guiding variant survives the hop', () {
    final variants = <bridge.GuidingEvent>[
      const bridge.GuidingEvent.correction(
        ra: 0.2,
        dec: -0.1,
        raRaw: 0.3,
        decRaw: -0.2,
      ),
      const bridge.GuidingEvent.guidingStarted(),
      const bridge.GuidingEvent.lostStar(),
      const bridge.GuidingEvent.settled(rms: 0.6),
      const bridge.GuidingEvent.ditherStarted(pixels: 3),
      const bridge.GuidingEvent.looping(),
      const bridge.GuidingEvent.settling(),
      const bridge.GuidingEvent.calibrating(),
      const bridge.GuidingEvent.calibrationComplete(),
      const bridge.GuidingEvent.starSelected(x: 120, y: 88),
      const bridge.GuidingEvent.appState(state: 'Guiding'),
      const bridge.GuidingEvent.guideStats(snr: 40, starMass: 12000),
    ];
    for (final event in variants) {
      expectRoundTrip(
        event,
        backend.guidingEventInfoForTesting(event),
        core.EventCategory.guiding,
        (p) => (p as bridge.EventPayload_Guiding).field0,
      );
    }
  });

  test('every equipment variant survives the hop', () {
    final variants = <bridge.EquipmentEvent>[
      const bridge.EquipmentEvent.connecting(
        deviceType: 'camera',
        deviceId: 'c',
      ),
      const bridge.EquipmentEvent.error(
        deviceType: 'mount',
        deviceId: 'm',
        message: 'timeout',
      ),
      const bridge.EquipmentEvent.mountSlewStarted(ra: 1, dec: 2),
      const bridge.EquipmentEvent.mountSlewCompleted(ra: 1, dec: 2),
      const bridge.EquipmentEvent.focuserMoveStarted(targetPosition: 100),
      const bridge.EquipmentEvent.focuserMoveCompleted(position: 100),
      const bridge.EquipmentEvent.focuserTemperatureChanged(temperature: 4.5),
      const bridge.EquipmentEvent.filterChanging(
        fromPosition: 0,
        toPosition: 2,
        filterName: 'Ha',
      ),
      const bridge.EquipmentEvent.filterChanged(position: 2, filterName: 'Ha'),
      const bridge.EquipmentEvent.rotatorMoveStarted(targetAngle: 90),
      const bridge.EquipmentEvent.rotatorMoveCompleted(angle: 90),
      const bridge.EquipmentEvent.cameraCoolingStarted(targetTemp: -10),
      const bridge.EquipmentEvent.cameraCoolingReached(temperature: -10),
      const bridge.EquipmentEvent.cameraWarmingStarted(),
      const bridge.EquipmentEvent.propertyChanged(
        deviceType: 'focuser',
        deviceId: 'f',
        property: 'AutofocusProgress',
        value: '{"phase":"Sweep"}',
      ),
      bridge.EquipmentEvent.heartbeatStarted(
        deviceType: 'mount',
        deviceId: 'm',
        intervalSecs: BigInt.from(5),
      ),
      bridge.EquipmentEvent.heartbeatStatusChanged(
        deviceType: 'mount',
        deviceId: 'm',
        status: bridge.HeartbeatStatus.degraded,
        consecutiveFailures: 2,
        lastRttMs: BigInt.from(40),
      ),
      const bridge.EquipmentEvent.heartbeatReconnecting(
        deviceType: 'mount',
        deviceId: 'm',
        attempt: 1,
        maxAttempts: 3,
      ),
    ];
    for (final event in variants) {
      expectRoundTrip(
        event,
        backend.equipmentEventInfoForTesting(event),
        core.EventCategory.equipment,
        (p) => (p as bridge.EventPayload_Equipment).field0,
      );
    }
  });

  test('every safety and system variant survives the hop', () {
    for (final event in <bridge.SafetyEvent>[
      const bridge.SafetyEvent.weatherUnsafe(reason: 'rain'),
      const bridge.SafetyEvent.parkInitiated(reason: 'rain'),
      const bridge.SafetyEvent.parkCompleted(),
    ]) {
      expectRoundTrip(
        event,
        backend.safetyEventInfoForTesting(event),
        core.EventCategory.safety,
        (p) => (p as bridge.EventPayload_Safety).field0,
      );
    }
    for (final event in <bridge.SystemEvent>[
      const bridge.SystemEvent.shuttingDown(),
      const bridge.SystemEvent.notification(
        title: 'Dew',
        message: 'Heater on',
        level: 'warning',
      ),
      bridge.SystemEvent.eventsDropped(
        droppedCount: BigInt.from(3),
        totalDropped: BigInt.from(9),
      ),
    ]) {
      expectRoundTrip(
        event,
        backend.systemEventInfoForTesting(event),
        core.EventCategory.system,
        (p) => (p as bridge.EventPayload_System).field0,
      );
    }
  });

  test('an event type this build cannot read is dropped, not reported as an '
      'error', () {
    for (final event in [
      const core.SkotiqEvent(
        timestamp: 1,
        severity: core.EventSeverity.info,
        category: core.EventCategory.sequencer,
        eventType: 'SomethingNew',
        data: {},
      ),
      const core.SkotiqEvent(
        timestamp: 1,
        severity: core.EventSeverity.info,
        category: core.EventCategory.equipment,
        eventType: 'MountPositionChanged',
        data: {'ra': 1.0},
      ),
      const core.SkotiqEvent(
        timestamp: 1,
        severity: core.EventSeverity.info,
        category: core.EventCategory.safety,
        eventType: 'SafetyMonitorReading',
        data: {},
      ),
    ]) {
      expect(
        tryBridgeEventFromCoreEvent(event),
        isNull,
        reason: event.eventType,
      );
    }
  });
}
