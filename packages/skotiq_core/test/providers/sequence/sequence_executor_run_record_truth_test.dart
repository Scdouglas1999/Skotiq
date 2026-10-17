import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart' as backend_events;

import '../../mocks/mock_backend.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _StubFilterWheelNotifier extends FilterWheelStateNotifier {
  _StubFilterWheelNotifier(super.ref, FilterWheelState initial) {
    state = initial;
  }
}

/// Two ways a run record states something the run did not do.
///
/// 1. `SequenceRunStats.recordAutofocus()` with no production call site can
///    only ever report 0, so the Session Report's Mount & focus block reads
///    "Autofocus runs 0" for a run whose Autofocus node swept 9 points, logged
///    "Child 'Autofocus' completed with status: Success" and moved the focuser
///    25000 -> 25070.
/// 2. A stats bucket reading `SequencerEvent.ExposureCompleted.filter` — a
///    field the native event does not carry — files every frame under the
///    filter key "Unknown" while `captured_images.filter` says "R" and the live
///    telemetry strip says "Filter: R".
void main() {
  setUpAll(registerMocktailFallbackValues);

  late MockBackend backend;
  late StreamController<backend_events.SkotiqEvent> eventController;
  late SkotiqDatabase db;

  setUp(() {
    backend = MockBackend();
    eventController = StreamController<backend_events.SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => eventController.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await eventController.close();
    await db.close();
  });

  /// Container with a live run-stats object in place, mirroring what `start()`
  /// does, so the counters the event handler mutates are observable.
  (ProviderContainer, SequenceExecutor) build({FilterWheelState? filterWheel}) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
        filterWheelStateProvider.overrideWith(
          (ref) => _StubFilterWheelNotifier(
            ref,
            filterWheel ?? const FilterWheelState(),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(liveSequenceStatsProvider.notifier).state =
        SequenceRunStats();
    return (container, container.read(sequenceExecutorProvider));
  }

  backend_events.SkotiqEvent sequencerEvent(
    String type,
    Map<String, dynamic> data,
  ) => backend_events.SkotiqEvent(
    timestamp: DateTime.now().microsecondsSinceEpoch,
    severity: backend_events.EventSeverity.info,
    category: backend_events.EventCategory.sequencer,
    eventType: type,
    data: data,
  );

  /// One autofocus sweep step, as `ProgressDetail::Autofocus` reaches Dart.
  backend_events.SkotiqEvent autofocusStep(
    String nodeId, {
    int step = 5,
    int totalSteps = 9,
  }) => sequencerEvent('InstructionProgressStructured', {
    'node_id': nodeId,
    'instruction': 'Autofocus',
    'progress_percent': step / totalSteps * 100.0,
    'detail_kind': 'Autofocus',
    'detail_json': jsonEncode({
      'step': step,
      'total_steps': totalSteps,
      'current_hfr': 3.4,
    }),
  });

  backend_events.SkotiqEvent nodeCompleted(String nodeId, String status) =>
      sequencerEvent('NodeCompleted', {'node_id': nodeId, 'status': status});

  group('autofocus run counter', () {
    test('a completed autofocus sweep is counted', () {
      final (container, executor) = build();

      executor.handleSequencerEventForTest(autofocusStep('af-node'));
      executor.handleSequencerEventForTest(nodeCompleted('af-node', 'success'));

      expect(
        container.read(liveSequenceStatsProvider)!.autofocusRuns,
        1,
        reason:
            'the Session Report read "Autofocus runs 0" for a sweep that ran '
            '9 points and moved the focuser — this is the defect being '
            'regressed',
      );
    });

    test('the counter survives the round-trip into stats_json', () {
      final (container, executor) = build();

      executor.handleSequencerEventForTest(autofocusStep('af-node'));
      executor.handleSequencerEventForTest(nodeCompleted('af-node', 'success'));

      final persisted =
          jsonDecode(container.read(liveSequenceStatsProvider)!.toJson())
              as Map<String, dynamic>;
      expect(persisted['autofocusRuns'], 1);
    });

    test('a trigger-fired refocus counts too', () {
      final (container, executor) = build();

      // The executor publishes trigger-driven autofocus under a synthetic node
      // id; it is the same physical operation and must reach the same counter.
      const triggerNode = 'trigger:hfr-degradation:autofocus';
      executor.handleSequencerEventForTest(autofocusStep(triggerNode));
      executor.handleSequencerEventForTest(
        nodeCompleted(triggerNode, 'success'),
      );

      expect(container.read(liveSequenceStatsProvider)!.autofocusRuns, 1);
    });

    test('an autofocus that FAILED is not counted', () {
      final (container, executor) = build();

      executor.handleSequencerEventForTest(autofocusStep('af-node'));
      executor.handleSequencerEventForTest(nodeCompleted('af-node', 'failed'));

      expect(
        container.read(liveSequenceStatsProvider)!.autofocusRuns,
        0,
        reason: 'a failed sweep did not focus anything',
      );
    });

    test('an ordinary node completing is not mistaken for an autofocus', () {
      final (container, executor) = build();

      executor.handleSequencerEventForTest(
        sequencerEvent('InstructionProgressStructured', {
          'node_id': 'slew-node',
          'instruction': 'Slew to Target',
          'progress_percent': 100.0,
          'detail_kind': 'Slew',
          'detail_json': jsonEncode({
            'target_ra_hours': 0.712,
            'target_dec_degrees': 41.269,
          }),
        }),
      );
      executor.handleSequencerEventForTest(
        nodeCompleted('slew-node', 'success'),
      );

      expect(container.read(liveSequenceStatsProvider)!.autofocusRuns, 0);
    });
  });

  group('run-stats filter attribution', () {
    /// `SequencerEvent.ExposureCompleted` carries frame/total/duration only —
    /// no filter — which is exactly how the live run produced a
    /// `targetBreakdown` keyed "Unknown" beside a `captured_images.filter` of
    /// "R".
    backend_events.SkotiqEvent exposureCompleted() => sequencerEvent(
      'ExposureCompleted',
      {'frame': 1, 'total': 4, 'duration_secs': 3.0},
    );

    test('a frame is filed under the filter the wheel is actually on', () async {
      final (container, executor) = build(
        filterWheel: const FilterWheelState(
          connectionState: DeviceConnectionState.connected,
          currentPosition: 0,
          filterNames: ['R', 'G', 'B'],
        ),
      );

      executor.handleSequencerEventForTest(exposureCompleted());
      // ExposureCompleted also kicks off the preview fetch; let it settle
      // inside the live container rather than after teardown.
      await pumpEventQueue();

      final breakdown = container
          .read(liveSequenceStatsProvider)!
          .targetBreakdown
          .values
          .single;
      expect(
        breakdown.keys,
        ['R'],
        reason:
            'the run record filed frames under "Unknown" while the DB row and '
            'the telemetry strip both said R',
      );
      expect(breakdown['R']!.captured, 1);
    });

    test(
      'the Change Filter instruction still wins over the wheel position',
      () async {
        final (container, executor) = build(
          filterWheel: const FilterWheelState(
            connectionState: DeviceConnectionState.connected,
            currentPosition: 0,
            filterNames: ['R', 'G', 'B'],
          ),
        );

        executor.handleSequencerEventForTest(
          sequencerEvent('InstructionProgressStructured', {
            'node_id': 'filter-node',
            'instruction': 'Change Filter',
            'progress_percent': 100.0,
            'detail_kind': 'Filter',
            'detail_json': jsonEncode({'name': 'Ha'}),
          }),
        );
        executor.handleSequencerEventForTest(exposureCompleted());
        await pumpEventQueue();

        final breakdown = container
            .read(liveSequenceStatsProvider)!
            .targetBreakdown
            .values
            .single;
        expect(breakdown.keys, ['Ha']);
      },
    );

    test('a Take Exposures burst that resolved the wheel itself wins over a '
        'stale Change Filter', () async {
      final (container, executor) = build(
        filterWheel: const FilterWheelState(
          connectionState: DeviceConnectionState.connected,
          currentPosition: 0,
          filterNames: ['L', 'R'],
        ),
      );

      // Sequence: Change Filter -> "L", then a Take Exposures node that
      // addresses the wheel by SLOT. The burst resolves slot 1 to "R" and
      // stamps R into the FITS FILTER card and the filename; without the
      // burst publishing what it resolved, this side of the bridge still
      // held "L" and recorded the same frame under L.
      executor.handleSequencerEventForTest(
        sequencerEvent('InstructionProgressStructured', {
          'node_id': 'filter-node',
          'instruction': 'Change Filter',
          'progress_percent': 100.0,
          'detail_kind': 'Filter',
          'detail_json': jsonEncode({'name': 'L', 'position': 0}),
        }),
      );
      // Exactly the payload `ExposeInstruction` now emits once per burst —
      // note the instruction is "Exposure", not "Change Filter".
      executor.handleSequencerEventForTest(
        sequencerEvent('InstructionProgressStructured', {
          'node_id': 'expose-node',
          'instruction': 'Exposure',
          'progress_percent': 0.0,
          'detail_kind': 'Filter',
          'detail_json': jsonEncode({'name': 'R', 'position': 1}),
        }),
      );
      // The per-frame ExposureStarted that follows carries the NODE's own
      // `filter`, which is null for a slot-addressed burst. It must not wipe
      // the identity the burst just published.
      executor.handleSequencerEventForTest(
        sequencerEvent('ExposureStarted', {
          'frame': 1,
          'total': 4,
          'filter': null,
        }),
      );
      executor.handleSequencerEventForTest(exposureCompleted());
      await pumpEventQueue();

      final breakdown = container
          .read(liveSequenceStatsProvider)!
          .targetBreakdown
          .values
          .single;
      expect(breakdown.keys, ['R']);
    });

    test(
      'with nothing able to name the filter it stays honest about that',
      () async {
        final (container, executor) = build();

        executor.handleSequencerEventForTest(exposureCompleted());
        await pumpEventQueue();

        final breakdown = container
            .read(liveSequenceStatsProvider)!
            .targetBreakdown
            .values
            .single;
        expect(
          breakdown.keys,
          ['Unknown'],
          reason:
              'no wheel and no Change Filter instruction — "Unknown" is the '
              'truthful bucket, not a fabricated filter name',
        );
      },
    );
  });

  group('target attribution', () {
    test('frames are filed under the target the executor announced', () async {
      final (container, executor) = build();

      // `TargetChanged` is what the bridge emits for the native executor's
      // `TargetStarted`. Before the native side produced it at all, this
      // handler never ran and the breakdown fell through to the sequence name.
      executor.handleSequencerEventForTest(
        sequencerEvent('TargetChanged', {
          'target_name': 'M31',
          'ra': 0.712,
          'dec': 41.269,
        }),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('ExposureCompleted', {
          'frame': 1,
          'total': 4,
          'duration_secs': 3.0,
        }),
      );
      await pumpEventQueue();

      expect(container.read(liveSequenceStatsProvider)!.targetBreakdown.keys, [
        'M31',
      ]);
    });
  });
}
