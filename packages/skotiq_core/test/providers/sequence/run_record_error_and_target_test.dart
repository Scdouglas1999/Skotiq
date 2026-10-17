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

/// Two more run-record lies from the same live night.
///
/// 1. ONE failing Dither node produced TWO identical entries in
///    `sequence_runs.stats_json.errorMessages`, printed twice in the Session
///    Report's Errors section and stacked as two identical critical banners.
///    The bridge maps `InstructionFailed` to a mid-run `Error` event, and the
///    executor then derives the TERMINAL `SequenceFailed` reason by
///    re-formatting that same `InstructionFailed` — byte-for-byte the same
///    sentence, recorded twice.
///
/// 2. Every frame of a run whose only Target node was called "New Target" was
///    bucketed by `stats_json.targetBreakdown` under the SEQUENCE's name
///    ("New Sequence"). The bucket key came from `progress.currentTarget`,
///    which is only ever written by a native TargetStarted/TargetChanged
///    event that a plain builder sequence never emits, and then fell through
///    to the sequence name.
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

  (ProviderContainer, SequenceExecutor) build({Sequence? sequence}) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(liveSequenceStatsProvider.notifier).state =
        SequenceRunStats();
    if (sequence != null) {
      container
          .read(currentSequenceProvider.notifier)
          .loadSequence(sequence, discardUnsaved: true);
    }
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

  group('one failure, one recorded error', () {
    // The exact pair the bridge and the executor emit for a single failing
    // node: the mid-run reason, then the terminal restatement of it.
    const reason = 'Dither: Dither failed: No active guider configured';

    test('the terminal restatement is not recorded a second time', () {
      final (container, executor) = build();

      executor.handleSequencerEventForTest(
        sequencerEvent('Error', {'message': reason}),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('SequenceFailed', {'error': reason}),
      );

      expect(
        container.read(liveSequenceStatsProvider)!.errorMessages,
        [reason],
        reason: 'one failing node must not fill the report with two copies',
      );
    });

    test('the round trip into stats_json carries one copy', () {
      final (container, executor) = build();

      executor.handleSequencerEventForTest(
        sequencerEvent('Error', {'message': reason}),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('SequenceFailed', {'error': reason}),
      );

      final persisted =
          jsonDecode(container.read(liveSequenceStatsProvider)!.toJson())
              as Map<String, dynamic>;
      expect(persisted['errorMessages'], [reason]);
    });

    test('a terminal reason nothing else reported IS recorded', () {
      final (container, executor) = build();

      executor.handleSequencerEventForTest(
        sequencerEvent('SequenceFailed', {
          'error': 'Sequence failed before any instruction ran',
        }),
      );

      expect(container.read(liveSequenceStatsProvider)!.errorMessages, [
        'Sequence failed before any instruction ran',
      ]);
    });

    test('two genuinely distinct failures are both recorded', () {
      final (container, executor) = build();

      executor.handleSequencerEventForTest(
        sequencerEvent('Error', {'message': reason}),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('Error', {'message': 'Slew: mount refused the slew'}),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('SequenceFailed', {
          'error': 'Slew: mount refused the slew',
        }),
      );

      expect(container.read(liveSequenceStatsProvider)!.errorMessages, [
        reason,
        'Slew: mount refused the slew',
      ]);
    });
  });

  group('run stats are bucketed by the target, not the sequence', () {
    Sequence targetSequence() {
      final exposure = ExposureNode(
        id: 'expo1',
        name: 'Take Exposures',
        durationSecs: 3,
        count: 4,
        parentId: 'target1',
      );
      final target = TargetHeaderNode(
        id: 'target1',
        name: 'Target',
        targetName: 'New Target',
        raHours: 0,
        decDegrees: 0,
        childIds: const ['expo1'],
      );
      return Sequence.create(
        // Deliberately different from the target name: the sequence name is
        // what the broken fallback used as the bucket key.
        name: 'New Sequence',
        rootNodeId: 'target1',
        nodes: {'target1': target, 'expo1': exposure},
      );
    }

    test('a frame under a Target node is filed under that target', () async {
      final (container, executor) = build(sequence: targetSequence());

      executor.handleSequencerEventForTest(
        sequencerEvent('NodeStarted', {
          'node_id': 'expo1',
          'node_name': 'Take Exposures',
        }),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('ExposureCompleted', {
          'frame': 1,
          'total': 4,
          'duration_secs': 3.0,
        }),
      );
      // ExposureCompleted also kicks off the preview fetch; let it settle
      // inside the live container rather than after teardown.
      await pumpEventQueue();

      final breakdown = container
          .read(liveSequenceStatsProvider)!
          .targetBreakdown;
      expect(breakdown.keys, ['New Target']);
      expect(
        breakdown.containsKey('New Sequence'),
        isFalse,
        reason: 'the sequence name is not the name of the object imaged',
      );
    });

    test('a native target event still wins when one arrives', () async {
      final (container, executor) = build(sequence: targetSequence());

      executor.handleSequencerEventForTest(
        sequencerEvent('TargetStarted', {'target_name': 'M31'}),
      );
      executor.handleSequencerEventForTest(
        sequencerEvent('NodeStarted', {
          'node_id': 'expo1',
          'node_name': 'Take Exposures',
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

    test(
      'a sequence with no Target node falls back to the sequence name',
      () async {
        final exposure = ExposureNode(
          id: 'expo1',
          name: 'Flats',
          durationSecs: 1,
          count: 2,
        );
        final sequence = Sequence.create(
          name: 'Flat Run',
          rootNodeId: 'expo1',
          nodes: {'expo1': exposure},
        );
        final (container, executor) = build(sequence: sequence);

        executor.handleSequencerEventForTest(
          sequencerEvent('NodeStarted', {'node_id': 'expo1', 'node_name': 'F'}),
        );
        executor.handleSequencerEventForTest(
          sequencerEvent('ExposureCompleted', {
            'frame': 1,
            'total': 2,
            'duration_secs': 1.0,
          }),
        );
        await pumpEventQueue();

        expect(
          container.read(liveSequenceStatsProvider)!.targetBreakdown.keys,
          ['Flat Run'],
        );
      },
    );
  });
}
