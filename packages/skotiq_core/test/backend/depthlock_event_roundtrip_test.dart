import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/src/backend/bridge_event_mapper.dart';
import 'package:skotiq_core/src/backend/bridge_events.dart'
    show depthGoalCompletedDetail;
import 'package:skotiq_core/src/backend/ffi_backend.dart';
import 'package:skotiq_core/src/models/backend/event_types.dart' as core;

/// The hop a DepthLock event makes on its way to a phone:
///
///   typed bridge payload -> (eventType, data) -> wire JSON -> wire event
///   -> typed bridge payload again
///
/// Every link is a place a field can vanish silently, and the goal store's
/// events are the only thing a remote client has to explain why a plan
/// stopped early. The round trip is asserted whole rather than per-hop for
/// that reason.
core.SkotiqEvent _throughTheWire(
  (String, Map<String, dynamic>) info, {
  core.EventCategory category = core.EventCategory.imaging,
}) {
  final sent = core.SkotiqEvent(
    timestamp: 1757000000000,
    severity: core.EventSeverity.info,
    category: category,
    eventType: info.$1,
    data: info.$2,
  );
  return core.SkotiqEvent.fromWireJson(sent.toJson());
}

void main() {
  final backend = FfiBackend();

  group('DepthLock events survive the remote hop', () {
    test('GoalUpdated keeps every number the verdict rested on', () {
      final info = backend.depthLockEventInfoForTesting(
        bridge.DepthLockEvent.goalUpdated(
          goalId: 'm42-ha',
          revision: BigInt.from(3),
          filterName: 'Ha',
          state: 'confirmationPending',
          score: 13.4,
          conservativeScore: 12.1,
          threshold: 12,
          uncertaintyAdu: 0.9,
          coverage: 0.98,
          evidenceFrames: 18,
          confirmationFrames: 2,
          reason: 'holding above threshold for a second look',
          automaticCompletion: true,
          framesRemaining: 5,
          reachable: true,
        ),
      );
      expect(info.$1, 'DepthLockGoalUpdated');

      final received = _throughTheWire(info);
      expect(received.eventType, 'DepthLockGoalUpdated');
      // The revision crosses as a plain int; a BigInt would not survive JSON.
      expect(received.data['revision'], 3);

      final payload = bridgeEventFromCoreEvent(received).payload;
      expect(payload, isA<bridge.EventPayload_DepthLock>());
      final event =
          (payload as bridge.EventPayload_DepthLock).field0
              as bridge.DepthLockEvent_GoalUpdated;
      expect(event.goalId, 'm42-ha');
      expect(event.revision, BigInt.from(3));
      expect(event.filterName, 'Ha');
      expect(event.state, 'confirmationPending');
      expect(event.score, 13.4);
      expect(event.conservativeScore, 12.1);
      expect(event.threshold, 12);
      expect(event.uncertaintyAdu, 0.9);
      expect(event.coverage, 0.98);
      expect(event.evidenceFrames, 18);
      expect(event.confirmationFrames, 2);
      expect(event.reason, 'holding above threshold for a second look');
      expect(event.automaticCompletion, isTrue);
      expect(event.framesRemaining, 5);
      expect(event.reachable, isTrue);
    });

    test('a goal with no score yet reports it as absent, not as zero', () {
      final info = backend.depthLockEventInfoForTesting(
        bridge.DepthLockEvent.goalUpdated(
          goalId: 'm42-oiii',
          revision: BigInt.one,
          filterName: 'OIII',
          state: 'insufficientEvidence',
          threshold: 12,
          coverage: 0,
          evidenceFrames: 1,
          confirmationFrames: 0,
          reason: 'one exposure is not evidence',
          automaticCompletion: false,
          reachable: false,
        ),
      );

      final event =
          (bridgeEventFromCoreEvent(_throughTheWire(info)).payload
                      as bridge.EventPayload_DepthLock)
                  .field0
              as bridge.DepthLockEvent_GoalUpdated;
      expect(event.score, isNull);
      expect(event.conservativeScore, isNull);
      expect(event.uncertaintyAdu, isNull);
      // No forecast yet means no count to show, which is a different claim
      // from "zero frames to go".
      expect(event.framesRemaining, isNull);
      // A goal the floor caps below its threshold: the count is meaningless
      // and the flag is what says so.
      expect(event.reachable, isFalse);
    });

    test('an event from a host that predates the forecast stays reachable', () {
      // `reachable` is absent on an older host's wire. Defaulting it to false
      // would paint every goal on that rig as impossible.
      final received = core.SkotiqEvent(
        timestamp: 1757000000000,
        severity: core.EventSeverity.info,
        category: core.EventCategory.imaging,
        eventType: 'DepthLockGoalUpdated',
        data: const {
          'goal_id': 'm42-ha',
          'revision': 2,
          'filter_name': 'Ha',
          'state': 'collecting',
          'threshold': 12.0,
          'coverage': 0.97,
          'evidence_frames': 6,
          'confirmation_frames': 0,
          'reason': 'collecting',
          'automatic_completion': true,
        },
      );

      final event =
          (bridgeEventFromCoreEvent(received).payload
                      as bridge.EventPayload_DepthLock)
                  .field0
              as bridge.DepthLockEvent_GoalUpdated;
      expect(event.reachable, isTrue);
      expect(event.framesRemaining, isNull);
    });

    test('EvidenceRejected and AnalysisDropped keep the operator reason', () {
      final rejected = backend.depthLockEventInfoForTesting(
        bridge.DepthLockEvent.evidenceRejected(
          goalId: 'm42-ha',
          revision: BigInt.from(3),
          sourcePath: '/data/m42/light_0042.fits',
          reason: 'CCD-TEMP differs from the reference by 4.2 C',
        ),
      );
      final rejectedEvent =
          (bridgeEventFromCoreEvent(_throughTheWire(rejected)).payload
                      as bridge.EventPayload_DepthLock)
                  .field0
              as bridge.DepthLockEvent_EvidenceRejected;
      expect(rejectedEvent.sourcePath, '/data/m42/light_0042.fits');
      expect(
        rejectedEvent.reason,
        'CCD-TEMP differs from the reference by 4.2 C',
      );

      final dropped = backend.depthLockEventInfoForTesting(
        const bridge.DepthLockEvent.analysisDropped(
          sourcePath: '/data/m42/light_0043.fits',
          reason: 'analysis queue full',
        ),
      );
      final droppedEvent =
          (bridgeEventFromCoreEvent(_throughTheWire(dropped)).payload
                      as bridge.EventPayload_DepthLock)
                  .field0
              as bridge.DepthLockEvent_AnalysisDropped;
      expect(droppedEvent.reason, 'analysis queue full');
    });

    test('GoalChanged names which edit happened', () {
      final info = backend.depthLockEventInfoForTesting(
        bridge.DepthLockEvent.goalChanged(
          goalId: 'm42-ha',
          revision: BigInt.from(4),
          change: 'revised',
        ),
      );

      final event =
          (bridgeEventFromCoreEvent(_throughTheWire(info)).payload
                      as bridge.EventPayload_DepthLock)
                  .field0
              as bridge.DepthLockEvent_GoalChanged;
      expect(event.change, 'revised');
      expect(event.revision, BigInt.from(4));
    });

    test('an ordinary imaging event still maps to an imaging payload', () {
      // The DepthLock filter sits in front of the imaging mapper; if it
      // matched too widely, every exposure event would arrive as a goal.
      const received = core.SkotiqEvent(
        timestamp: 1757000000000,
        severity: core.EventSeverity.info,
        category: core.EventCategory.imaging,
        eventType: 'ExposureFailed',
        data: {'reason': 'shutter stuck'},
      );

      expect(
        bridgeEventFromCoreEvent(received).payload,
        isA<bridge.EventPayload_Imaging>(),
      );
    });
  });

  group('DepthGoalCompleted survives the remote hop', () {
    test('the sequencer variant keeps its evidence counts', () {
      final info = backend.sequencerEventInfoForTesting(
        bridge.SequencerEvent.depthGoalCompleted(
          nodeId: 'smart-1',
          filterName: 'Ha',
          goalId: 'm42-ha',
          revision: BigInt.from(3),
          evidenceFrames: 18,
          confirmationFrames: 3,
          score: 13.4,
          threshold: 12,
        ),
      );
      expect(info.$1, 'DepthGoalCompleted');

      final received = _throughTheWire(
        info,
        category: core.EventCategory.sequencer,
      );
      final event =
          (bridgeEventFromCoreEvent(received).payload
                      as bridge.EventPayload_Sequencer)
                  .field0
              as bridge.SequencerEvent_DepthGoalCompleted;
      expect(event.nodeId, 'smart-1');
      expect(event.filterName, 'Ha');
      expect(event.goalId, 'm42-ha');
      expect(event.revision, BigInt.from(3));
      expect(event.evidenceFrames, 18);
      expect(event.confirmationFrames, 3);
      expect(event.score, 13.4);
      expect(event.threshold, 12);
    });

    test('the one-line explanation names the score and what it cleared', () {
      expect(
        depthGoalCompletedDetail(
          filterName: 'Ha',
          score: 13.4,
          threshold: 12,
          evidenceFrames: 18,
          confirmationFrames: 3,
        ),
        'Ha reached its depth goal (score 13.4 >= 12.0, 18 exposures, '
        '3 confirming)',
      );
    });
  });
}
