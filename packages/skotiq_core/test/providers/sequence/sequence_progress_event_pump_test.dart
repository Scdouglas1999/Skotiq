// Pins `applySequencerEventToSequenceProviders` against the event names and
// payload shapes the backend ACTUALLY emits.
//
// The FFI mapper emits the bare `Started` / `Paused` / `Resumed` / `Stopped` /
// `Completed`, plus the terminal `SequenceFailed`; a pump that matches
// `Sequence`-prefixed lifecycle names matches nothing any producer sends. The
// same goes for reading a `success` bool from `NodeCompleted`, where the wire
// carries a `status` string. Tests that feed the fictional names stay green
// over both.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

SkotiqEvent _event(String type, [Map<String, dynamic> data = const {}]) =>
    SkotiqEvent(
      timestamp: DateTime.now().millisecondsSinceEpoch,
      severity: EventSeverity.info,
      category: EventCategory.sequencer,
      eventType: type,
      data: data,
    );

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
  });

  tearDown(() => container.dispose());

  void apply(SkotiqEvent event) =>
      applySequencerEventToSequenceProviders(container.read, event);

  group('NodeCompleted carries a status STRING, not a success bool', () {
    test('status=success records success (was recorded as failure)', () {
      apply(_event('NodeStarted', {'node_id': 'n1', 'node_type': 'Exposure'}));
      apply(_event('NodeCompleted', {'node_id': 'n1', 'status': 'success'}));

      expect(
        container.read(sequenceProgressProvider).nodeStatuses['n1'],
        NodeStatus.success,
      );
    });

    test('status=skipped records skipped, status=cancelled too', () {
      apply(_event('NodeCompleted', {'node_id': 'n1', 'status': 'skipped'}));
      apply(_event('NodeCompleted', {'node_id': 'n2', 'status': 'cancelled'}));

      final statuses = container.read(sequenceProgressProvider).nodeStatuses;
      expect(statuses['n1'], NodeStatus.skipped);
      expect(statuses['n2'], NodeStatus.skipped);
    });

    test('status=failed records failure', () {
      apply(_event('NodeCompleted', {'node_id': 'n1', 'status': 'failed'}));

      expect(
        container.read(sequenceProgressProvider).nodeStatuses['n1'],
        NodeStatus.failure,
      );
    });

    test('a legacy success bool is still honoured', () {
      apply(_event('NodeCompleted', {'node_id': 'n1', 'success': true}));

      expect(
        container.read(sequenceProgressProvider).nodeStatuses['n1'],
        NodeStatus.success,
      );
    });

    test(
      'no status at all leaves the node alone rather than claiming failure',
      () {
        apply(
          _event('NodeStarted', {'node_id': 'n1', 'node_type': 'Exposure'}),
        );
        apply(_event('NodeCompleted', {'node_id': 'n1'}));

        expect(
          container.read(sequenceProgressProvider).nodeStatuses['n1'],
          NodeStatus.running,
        );
      },
    );
  });

  group('lifecycle events drive state when no local run is owned', () {
    test('bare Started/Completed move the state (was stuck at idle)', () {
      apply(_event('Started', {'sequence_name': 'M31 LRGB'}));
      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.running,
      );
      expect(
        container.read(sequenceProgressProvider).state,
        SequenceExecutionState.running,
      );

      apply(_event('Completed'));
      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.completed,
      );
      expect(
        container.read(sequenceProgressProvider).state,
        SequenceExecutionState.completed,
      );
    });

    test('bare Paused/Resumed/Stopped move the state', () {
      apply(_event('Started', {'sequence_name': 'x'}));
      apply(_event('Paused'));
      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.paused,
      );

      apply(_event('Resumed'));
      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.running,
      );

      apply(_event('Stopped'));
      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.idle,
      );
    });

    test('SequenceFailed settles to failed and carries the reason', () {
      apply(_event('Started', {'sequence_name': 'x'}));
      apply(_event('SequenceFailed', {'error': 'mount refused slew'}));

      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.failed,
      );
      expect(
        container.read(sequenceProgressProvider).message,
        contains('mount refused slew'),
      );
    });

    test('a new run clears the previous run accounting', () {
      apply(_event('Started', {'sequence_name': 'run one'}));
      apply(_event('Progress', {'current': 0, 'total': 3}));
      apply(_event('NodeCompleted', {'node_id': 'n1', 'status': 'success'}));
      apply(
        _event('ExposureCompleted', {
          'frame': 3,
          'total': 3,
          'duration_secs': 10.0,
        }),
      );
      apply(_event('Completed'));

      var progress = container.read(sequenceProgressProvider);
      expect(progress.completedExposures, 3);
      expect(progress.completedIntegrationSecs, 10.0);

      // Second run of the night on the same host. Integration seconds
      // accumulate (read-modify-write) while the frame count is assigned from
      // the event's absolute index, so without a reset the two contradict each
      // other and the stale node badges linger.
      apply(_event('Started', {'sequence_name': 'run two'}));
      progress = container.read(sequenceProgressProvider);
      expect(progress.completedExposures, 0);
      expect(progress.completedIntegrationSecs, 0.0);
      expect(progress.nodeStatuses, isEmpty);
      expect(progress.state, SequenceExecutionState.running);

      apply(
        _event('ExposureCompleted', {
          'frame': 1,
          'total': 3,
          'duration_secs': 10.0,
        }),
      );
      progress = container.read(sequenceProgressProvider);
      expect(progress.completedExposures, 1);
      expect(progress.completedIntegrationSecs, 10.0);
    });

    test('the prefixed spellings still work for hosts that emit them', () {
      apply(_event('SequenceStarted', {'sequence_name': 'x'}));
      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.running,
      );

      apply(_event('SequenceCompleted'));
      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.completed,
      );
    });
  });

  group('a local executor-owned run keeps lifecycle authority', () {
    // The executor publishes `finalizing` on a terminal event and only settles
    // once durable cleanup succeeds. This pump runs first on the shared
    // broadcast stream, so it must not pre-empt that transaction with a settled
    // state.
    test('terminal events do not settle the state while a run id is set', () {
      container.read(currentRunIdProvider.notifier).state = 42;
      container.read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.running;

      apply(_event('Completed'));
      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.running,
      );

      apply(_event('SequenceFailed', {'error': 'boom'}));
      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.running,
      );
      // The reason is still surfaced — only the state transition is deferred to
      // the executor.
      expect(
        container.read(sequenceProgressProvider).message,
        contains('boom'),
      );
    });

    test('node status is still mirrored for an owned run', () {
      container.read(currentRunIdProvider.notifier).state = 42;

      apply(_event('NodeCompleted', {'node_id': 'n1', 'status': 'success'}));
      expect(
        container.read(sequenceProgressProvider).nodeStatuses['n1'],
        NodeStatus.success,
      );
    });
  });

  group('camera card is released when the run leaves the exposing path', () {
    test('a stop mid-exposure clears Exposing (no sticky Exposing)', () {
      apply(
        _event('ExposureStarted', {
          'frame': 1,
          'total': 10,
          'duration_secs': 120.0,
        }),
      );
      expect(container.read(cameraStateProvider).isExposing, isTrue);

      apply(_event('Stopped'));
      expect(container.read(cameraStateProvider).isExposing, isFalse);
    });

    test('a completion mid-exposure clears Exposing', () {
      apply(
        _event('ExposureStarted', {
          'frame': 1,
          'total': 1,
          'duration_secs': 5.0,
        }),
      );
      apply(_event('Completed'));
      expect(container.read(cameraStateProvider).isExposing, isFalse);
    });

    test('a terminal failure mid-exposure clears Exposing', () {
      apply(
        _event('ExposureStarted', {
          'frame': 1,
          'total': 1,
          'duration_secs': 5.0,
        }),
      );
      apply(_event('SequenceFailed', {'error': 'guider lost star'}));
      expect(container.read(cameraStateProvider).isExposing, isFalse);
    });
  });
}
