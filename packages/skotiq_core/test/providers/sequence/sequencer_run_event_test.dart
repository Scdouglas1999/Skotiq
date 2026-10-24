// SequencerRunEvent is the one decoder for sequencer events. Each payload here
// is produced the way production produces it: the FFI path runs a typed bridge
// event through the real FfiBackend mapper, and the remote path sends that same
// event through the headless wire envelope (`{'type': 'event', ...toJson()}`,
// JSON-encoded) and back through `SkotiqEvent.fromWireJson`. Both must decode
// to the same typed values.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/skotiq_core.dart';

const _capture = bridge.FrameCaptureMetadata(
  gain: 139,
  offset: 21,
  sensorTempC: -9.5,
  exposureSecs: 120.0,
  binX: 2,
  binY: 2,
  frameType: 'Light',
);

void main() {
  late FfiBackend ffi;

  setUp(() => ffi = FfiBackend());
  tearDown(() => ffi.dispose());

  SkotiqEvent viaFfi(
    bridge.SequencerEvent native, {
    EventSeverity severity = EventSeverity.info,
  }) {
    final (eventType, data) = ffi.sequencerEventInfoForTesting(native);
    return SkotiqEvent(
      timestamp: 1700000000123,
      severity: severity,
      category: EventCategory.sequencer,
      eventType: eventType,
      data: data,
    );
  }

  SkotiqEvent viaRemote(SkotiqEvent local) {
    final wire = jsonEncode({
      'type': 'event',
      ...local.toJson(),
    }, toEncodable: (v) => v is BigInt ? v.toInt() : v);
    return SkotiqEvent.fromWireJson(jsonDecode(wire) as Map<String, dynamic>);
  }

  /// Decode [native] on both transports and return both results.
  List<SequencerRunEvent> both(
    bridge.SequencerEvent native, {
    EventSeverity severity = EventSeverity.info,
  }) {
    final local = viaFfi(native, severity: severity);
    return [
      SequencerRunEvent.fromSkotiqEvent(local)!,
      SequencerRunEvent.fromSkotiqEvent(viaRemote(local))!,
    ];
  }

  test('a non-sequencer event is not decoded', () {
    expect(
      SequencerRunEvent.fromSkotiqEvent(
        const SkotiqEvent(
          timestamp: 0,
          severity: EventSeverity.info,
          category: EventCategory.equipment,
          eventType: 'NodeStarted',
          data: {'node_id': 'n'},
        ),
      ),
      isNull,
    );
  });

  test('lifecycle events on both transports', () {
    for (final e in both(
      const bridge.SequencerEvent.started(sequenceName: 'M31 LRGB'),
    )) {
      expect(
        e,
        isA<RunStarted>().having((e) => e.sequenceName, 'name', 'M31 LRGB'),
      );
      expect(e.timestamp, 1700000000123);
    }
    for (final e in both(const bridge.SequencerEvent.paused())) {
      expect(e, isA<RunPaused>());
    }
    for (final e in both(const bridge.SequencerEvent.resumed())) {
      expect(e, isA<RunResumed>());
    }
    for (final e in both(
      const bridge.SequencerEvent.stopped(sequenceRunId: 42),
    )) {
      expect(e, isA<RunStopped>().having((e) => e.sequenceRunId, 'run', 42));
      expect(e, isA<RunTerminalEvent>());
    }
    for (final e in both(const bridge.SequencerEvent.completed())) {
      expect(e, isA<RunCompleted>());
    }
    for (final e in both(
      const bridge.SequencerEvent.failed(error: 'mount lost'),
    )) {
      expect(e, isA<RunFailed>().having((e) => e.error, 'error', 'mount lost'));
    }
  });

  test('node events on both transports', () {
    for (final e in both(
      const bridge.SequencerEvent.nodeStarted(
        nodeId: 'n1',
        nodeType: 'TakeExposure',
      ),
    )) {
      expect(
        e,
        isA<NodeStarted>()
            .having((e) => e.nodeId, 'id', 'n1')
            .having((e) => e.nodeType, 'type', 'TakeExposure'),
      );
    }
    for (final e in both(
      const bridge.SequencerEvent.nodeCompleted(
        nodeId: 'n1',
        status: 'cancelled',
      ),
    )) {
      expect(
        e,
        isA<NodeCompleted>()
            .having((e) => e.status, 'status', 'cancelled')
            .having((e) => e.nodeStatus, 'nodeStatus', NodeStatus.skipped),
      );
    }
  });

  test('exposure events keep their numbers on both transports', () {
    for (final e in both(
      const bridge.SequencerEvent.exposureCompleted(
        frame: 3,
        total: 10,
        durationSecs: 300.0,
      ),
    )) {
      expect(
        e,
        isA<ExposureCompleted>()
            .having((e) => e.frame, 'frame', 3)
            .having((e) => e.total, 'total', 10)
            .having((e) => e.durationSecs, 'duration', 300.0),
      );
    }
    for (final e in both(
      const bridge.SequencerEvent.exposureStarted(
        frame: 4,
        total: 10,
        filter: 'Ha',
        durationSecs: 180.5,
      ),
    )) {
      expect(
        e,
        isA<ExposureStarted>()
            .having((e) => e.filter, 'filter', 'Ha')
            .having((e) => e.durationSecs, 'duration', 180.5),
      );
    }
    for (final e in both(
      const bridge.SequencerEvent.progress(current: 7, total: 20),
    )) {
      expect(
        e,
        isA<ExposureCountProgress>()
            .having((e) => e.current, 'current', 7)
            .having((e) => e.total, 'total', 20),
      );
    }
  });

  test('target events on both transports', () {
    for (final e in both(
      const bridge.SequencerEvent.targetChanged(
        targetName: 'M42',
        ra: 5.588,
        dec: -5.39,
      ),
    )) {
      expect(
        e,
        isA<TargetChanged>()
            .having((e) => e.targetName, 'name', 'M42')
            .having((e) => e.ra, 'ra', 5.588)
            .having((e) => e.dec, 'dec', -5.39),
      );
    }
  });

  test('an Error keeps its severity, so an advisory is not a fault', () {
    for (final e in both(
      const bridge.SequencerEvent.error(message: 'no plate solver'),
      severity: EventSeverity.warning,
    )) {
      expect(
        e,
        isA<SequencerError>().having((e) => e.isAdvisory, 'advisory', isTrue),
      );
    }
    for (final e in both(
      const bridge.SequencerEvent.error(message: 'camera lost'),
    )) {
      expect(
        e,
        isA<SequencerError>().having((e) => e.isAdvisory, 'advisory', isFalse),
      );
    }
  });

  test(
    'structured progress: detail_json is decoded once, on both transports',
    () {
      for (final e in both(
        bridge.SequencerEvent.instructionProgressStructured(
          nodeId: 'n1',
          instruction: 'ChangeFilter',
          progressPercent: 100.0,
          detailKind: 'Filter',
          detailJson: jsonEncode({'name': 'OIII'}),
        ),
      )) {
        expect(
          e,
          isA<StructuredInstructionProgress>()
              .having((e) => e.detailJson, 'json', {'name': 'OIII'})
              .having((e) => e.changedFilterName, 'filter', 'OIII'),
        );
      }
      for (final e in both(
        bridge.SequencerEvent.instructionProgressStructured(
          nodeId: 'n1',
          instruction: 'Exposure',
          progressPercent: 40.0,
          detailKind: 'Exposure',
          detailJson: jsonEncode({
            'frame': 4,
            'total': 10,
            'duration_secs': 180,
          }),
        ),
      )) {
        expect(
          (e as StructuredInstructionProgress).detail,
          isA<ExposureInstructionProgressDetail>()
              .having((d) => d.frame, 'frame', 4)
              .having((d) => d.total, 'total', 10),
        );
      }
    },
  );

  test('a performed dither decodes as its own event', () {
    for (final e in both(
      const bridge.SequencerEvent.instructionProgressStructured(
        nodeId: 'n1',
        instruction: 'Dither',
        progressPercent: 100.0,
        detailKind: ditherPerformedDetailKind,
        detailJson: '{}',
      ),
    )) {
      expect(e, isA<DitherPerformed>().having((e) => e.nodeId, 'node', 'n1'));
    }
  });

  test('a frame assessment decodes as its own event', () {
    for (final e in both(
      bridge.SequencerEvent.instructionProgressStructured(
        nodeId: 'n1',
        instruction: 'Frame watch',
        progressPercent: 100.0,
        detailKind: frameAssessedDetailKind,
        detailJson: jsonEncode({
          'save_path': r'C:\data\NGC0891\B_0120.fits',
          'filter': 'B',
          'exposure_secs': 120,
          'was_accepted': true,
          'solve_attempted': true,
          'plate_solved': true,
          'solved_ra_deg': 35.64,
          'solved_dec_deg': 42.35,
          'solved_rotation_deg': null,
          'solved_pixel_scale': 1.12,
          'offset_arcmin': 31.6,
          'guide_rms_total': 0.74,
          'guide_rms_samples': 58,
          'background_adu': 801.5,
          'star_count': 640,
          'altitude_deg': 66.1,
          'azimuth_deg': 283.0,
          'pier_side': 'East',
          'off_target': true,
          'obstructed': false,
          'exclusion_reason': 'Off target: 31.6 arcmin from NGC 891',
        }),
      ),
    )) {
      expect(
        e,
        isA<FrameAssessed>()
            .having((e) => e.savePath, 'path', r'C:\data\NGC0891\B_0120.fits')
            .having((e) => e.exposureSecs, 'exposure', 120.0)
            .having((e) => e.solvedRaDeg, 'ra', 35.64)
            .having((e) => e.solvedRotationDeg, 'rotation', isNull)
            .having((e) => e.guideRmsTotal, 'rms', 0.74)
            .having((e) => e.guideRmsSamples, 'samples', 58)
            .having((e) => e.offTarget, 'off target', isTrue)
            .having((e) => e.isExcluded, 'excluded', isTrue),
      );
    }
  });

  test('a horizon obstruction decodes as its own event', () {
    for (final e in both(
      bridge.SequencerEvent.instructionProgressStructured(
        nodeId: 'n1',
        instruction: 'Frame watch',
        progressPercent: 100.0,
        detailKind: horizonObstructionDetailKind,
        detailJson: jsonEncode({
          'altitude_deg': 64.0,
          'azimuth_deg': 286.2,
          'target_name': 'NGC 891',
          'latitude': 43.1,
          'longitude': -77.6,
          'verdict': 'obstruction',
          'action': 'next_target',
          'message': 'Trees ahead.',
        }),
      ),
    )) {
      expect(
        e,
        isA<HorizonObstructionDetected>()
            .having((e) => e.azimuthDeg, 'az', 286.2)
            .having((e) => e.action, 'action', 'next_target')
            .having((e) => e.latitude, 'lat', 43.1),
      );
    }
  });

  test('an obstruction without a position stays plain progress', () {
    for (final e in both(
      const bridge.SequencerEvent.instructionProgressStructured(
        nodeId: 'n1',
        instruction: 'Frame watch',
        progressPercent: 100.0,
        detailKind: horizonObstructionDetailKind,
        detailJson: '{}',
      ),
    )) {
      expect(e, isA<StructuredInstructionProgress>());
    }
  });

  test('graded frames carry capture truth and paths on both transports', () {
    for (final e in both(
      const bridge.SequencerEvent.frameAccepted(
        nodeId: 'n1',
        frame: 2,
        total: 5,
        hfr: 2.4,
        starCount: 812,
        acceptedTotal: 2,
        rejectedTotal: 0,
        savePath: '/data/M31/L_0002.fits',
        capture: _capture,
      ),
    )) {
      expect(
        e,
        isA<FrameAccepted>()
            .having((e) => e.accepted, 'accepted', isTrue)
            .having((e) => e.filePath, 'path', '/data/M31/L_0002.fits')
            .having((e) => e.starCount, 'stars', 812)
            .having((e) => e.capture.gain, 'gain', 139)
            .having((e) => e.capture.exposureSecs, 'exposure', 120.0),
      );
    }
    for (final e in both(
      const bridge.SequencerEvent.frameRejected(
        nodeId: 'n1',
        frame: 3,
        total: 5,
        reason: 'HFR 6.1 over limit',
        rejectPath: '/data/M31/Reject/L_0003.fits',
        consecutiveRejects: 1,
        acceptedTotal: 2,
        rejectedTotal: 1,
        evidence: [],
        capture: _capture,
      ),
    )) {
      expect(
        e,
        isA<FrameRejected>()
            .having((e) => e.accepted, 'accepted', isFalse)
            .having((e) => e.filePath, 'path', '/data/M31/Reject/L_0003.fits')
            .having((e) => e.reason, 'reason', 'HFR 6.1 over limit')
            .having((e) => e.consecutiveRejects, 'streak', 1)
            .having((e) => e.capture.binX, 'binX', 2),
      );
    }
  });

  test('meridian flip, trigger, plugin, depth goal and decision events', () {
    for (final e in both(
      const bridge.SequencerEvent.meridianFlipOutcome(
        outcome: 'success',
        targetName: 'M31',
        newPierSide: 'East',
        durationSecs: 95.5,
        attempts: 2,
        failedSteps: ['recenter: no solve'],
      ),
    )) {
      expect(
        e,
        isA<MeridianFlipOutcome>()
            .having((e) => e.attempts, 'attempts', 2)
            .having((e) => e.failedSteps, 'steps', ['recenter: no solve']),
      );
    }
    for (final e in both(
      const bridge.SequencerEvent.triggerFired(
        triggerId: 'dawn',
        triggerName: 'Dawn Approaching',
        action: 'ParkAndAbort',
      ),
    )) {
      expect(
        e,
        isA<TriggerFired>().having((e) => e.action, 'action', 'ParkAndAbort'),
      );
    }
    for (final e in both(
      const bridge.SequencerEvent.pluginNodeRequested(
        nodeId: 'p1',
        pluginId: 'acme',
        nodeTypeId: 'acme.flats',
        configJson: '{}',
        timeoutSecs: 90,
      ),
    )) {
      expect(
        e,
        isA<PluginNodeRequested>().having((e) => e.timeoutSecs, 'timeout', 90),
      );
    }
    for (final e in both(
      bridge.SequencerEvent.depthGoalCompleted(
        nodeId: 'n1',
        filterName: 'L',
        goalId: 'g-7',
        revision: BigInt.from(3),
        evidenceFrames: 12,
        confirmationFrames: 2,
        score: 0.91,
        threshold: 0.9,
      ),
    )) {
      expect(
        e,
        isA<DepthGoalCompleted>()
            .having((e) => e.goalId, 'goal', 'g-7')
            .having((e) => e.revision, 'revision', 3)
            .having((e) => e.score, 'score', 0.91),
      );
    }
    for (final e in both(
      const bridge.SequencerEvent.decisionLogged(
        timestampIso: '2026-10-21T03:00:00Z',
        category: 'manual_intervention',
        summary: 'Operator stop',
        detailsJson: '{}',
        nodeId: 'n1',
        sequenceRunId: 9,
      ),
    )) {
      expect(
        e,
        isA<DecisionLogged>()
            .having((e) => e.category, 'category', 'manual_intervention')
            .having((e) => e.sequenceRunId, 'run', 9),
      );
    }
  });

  group('older spellings normalize to the current event', () {
    SequencerRunEvent decode(String type, Map<String, dynamic> data) =>
        SequencerRunEvent.fromSkotiqEvent(
          SkotiqEvent(
            timestamp: 1,
            severity: EventSeverity.info,
            category: EventCategory.sequencer,
            eventType: type,
            data: data,
          ),
        )!;

    test('Sequence-prefixed lifecycle names', () {
      expect(decode('SequenceStarted', {}), isA<RunStarted>());
      expect(decode('SequencePaused', {}), isA<RunPaused>());
      expect(decode('SequenceResumed', {}), isA<RunResumed>());
      expect(decode('SequenceStopped', {}), isA<RunStopped>());
      expect(decode('SequenceCompleted', {}), isA<RunCompleted>());
      expect(decode('SequenceCancelled', {}), isA<RunCancelled>());
    });

    test('camelCase node keys and the target name alias', () {
      expect(
        decode('NodeStarted', {'nodeId': 'n9', 'nodeName': 'Dither'}),
        isA<NodeStarted>()
            .having((e) => e.nodeId, 'id', 'n9')
            .having((e) => e.nodeType, 'type', 'Dither'),
      );
      expect(
        decode('TargetStarted', {'name': 'NGC 7000'}),
        isA<TargetChanged>().having((e) => e.targetName, 'name', 'NGC 7000'),
      );
    });

    test('a boolean success on NodeCompleted', () {
      expect(
        decode('NodeCompleted', {'node_id': 'n', 'success': false}),
        isA<NodeCompleted>()
            .having((e) => e.status, 'status', 'failed')
            .having((e) => e.nodeStatus, 'nodeStatus', NodeStatus.failure),
      );
      expect(
        decode('NodeCompleted', {'node_id': 'n'}),
        isA<NodeCompleted>().having((e) => e.nodeStatus, 'nodeStatus', isNull),
      );
    });

    test('a detail_json that is already decoded passes through', () {
      expect(
        decode('InstructionProgressStructured', {
          'node_id': 'n',
          'detail_kind': 'Exposure',
          'detail_json': {'frame': 1, 'total': 2},
        }),
        isA<StructuredInstructionProgress>().having(
          (e) => e.detailJson,
          'json',
          {'frame': 1, 'total': 2},
        ),
      );
    });

    test('a field of the wrong type reads as absent instead of throwing', () {
      expect(
        decode('ExposureCompleted', {'frame': 'three', 'duration_secs': '30'}),
        isA<ExposureCompleted>()
            .having((e) => e.frame, 'frame', isNull)
            .having((e) => e.durationSecs, 'duration', isNull),
      );
      expect(
        decode('PluginNodeRequested', {'node_id': 7}),
        isA<PluginNodeRequested>().having((e) => e.nodeId, 'node', isNull),
      );
    });

    test('a 64-bit id sent as a decimal string', () {
      expect(
        decode('DecisionLogged', {'sequence_run_id': '9007199254740993'}),
        isA<DecisionLogged>().having(
          (e) => e.sequenceRunId,
          'run',
          9007199254740993,
        ),
      );
    });

    test('an event nobody here reads keeps its name and data', () {
      expect(
        decode('SchedulerDecision', {'picked_target_id': 't'}),
        isA<UnrecognizedSequencerEvent>()
            .having((e) => e.eventType, 'type', 'SchedulerDecision')
            .having((e) => e.data['picked_target_id'], 'data', 't'),
      );
    });
  });
}
