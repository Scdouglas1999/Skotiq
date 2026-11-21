import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/src/backend/bridge_events.dart'
    show SequencerEvent_FrameAccepted;
import 'package:skotiq_core/src/providers/sequence/sequence_executor/live_stacking_feed.dart';
import 'package:skotiq_core/utils.dart';

import '../../harness/sequencer_wire.dart';

class _GatedStacker implements LiveStackingService {
  _GatedStacker({this.gate});

  final Completer<void>? gate;
  final Completer<void> entered = Completer<void>();
  int stops = 0;

  @override
  Future<LiveStackingStats> startFromFile({
    required String referenceImagePath,
    LiveStackingConfig config = const LiveStackingConfig(),
  }) async {
    if (!entered.isCompleted) entered.complete();
    final pending = gate;
    if (pending != null) await pending.future;
    return const LiveStackingStats(
      stackedFrameCount: 1,
      totalFramesAttempted: 1,
    );
  }

  @override
  Future<LiveStackingStats> startFromFileForFilter({
    required String filterKey,
    required String referenceImagePath,
    LiveStackingConfig config = const LiveStackingConfig(),
  }) async {
    return const LiveStackingStats(
      stackedFrameCount: 1,
      totalFramesAttempted: 1,
    );
  }

  @override
  Future<LiveStackingResult> getCurrentResult() async =>
      const LiveStackingResult(
        width: 2,
        height: 2,
        data: [1, 2, 3, 4],
        stats: LiveStackingStats(stackedFrameCount: 1),
      );

  @override
  Future<LiveStackingResult> getCurrentResultForFilter(String filterKey) async {
    return LiveStackingResult(
      width: 2,
      height: 2,
      data: const [1, 2, 3, 4],
      filterKey: filterKey,
      stats: const LiveStackingStats(stackedFrameCount: 1),
    );
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Sequence _sequenceWithLiveStack() {
  final exposure = ExposureNode(
    id: 'exp-1',
    parentId: 'root',
    durationSecs: 30,
  );
  final stack = LiveStackingNode(
    id: 'ls-1',
    parentId: 'root',
    broadcastEnabled: false,
    stackMethod: LiveStackingMethod.sigma,
  );
  final root = InstructionSetNode(
    id: 'root',
    name: 'Root',
  ).copyWith(childIds: ['ls-1', 'exp-1']);
  return Sequence.create(
    name: 'Feed teardown',
    rootNodeId: 'root',
    nodes: {'root': root, 'ls-1': stack, 'exp-1': exposure},
  );
}

SequencerEvent_FrameAccepted _accepted(String path) {
  final event = bridge.SequencerEvent.frameAccepted(
    nodeId: 'exp-1',
    frame: 1,
    total: 1,
    acceptedTotal: 1,
    rejectedTotal: 0,
    savePath: path,
    capture: testCapture(),
  );
  if (event is! SequencerEvent_FrameAccepted) {
    throw StateError('frameAccepted did not build an accepted frame');
  }
  return event;
}

void main() {
  test('teardown stops a stack the in-flight first frame armed', () async {
    final gate = Completer<void>();
    final stacker = _GatedStacker(gate: gate);
    final container = ProviderContainer(
      overrides: [
        loggingServiceProvider.overrideWithValue(LoggingService()),
        liveStackingServiceProvider.overrideWithValue(stacker),
      ],
    );
    addTearDown(container.dispose);

    final feed = LiveStackingFeed(
      sequence: _sequenceWithLiveStack,
      progress: () => const SequenceProgress(),
      broadcast: () => container.read(liveStackingBroadcastServiceProvider),
      stacker: () => container.read(liveStackingProvider.notifier),
      stackState: () => container.read(liveStackingProvider),
      logger: () => container.read(loggingServiceProvider),
    );

    feed.feed(_accepted('/captures/m42/L_0001.fits'));
    await stacker.entered.future;

    final tornDown = feed.teardown();
    await Future<void>.delayed(Duration.zero);
    expect(
      stacker.stops,
      0,
      reason: 'start has not finished, so stop is early',
    );

    gate.complete();
    await tornDown;

    expect(stacker.stops, 1);
    expect(
      container.read(liveStackingProvider).status,
      LiveStackingStatus.idle,
    );
  });

  test(
    'teardown does not stop a stack the operator armed themselves',
    () async {
      final stacker = _GatedStacker();
      final container = ProviderContainer(
        overrides: [
          loggingServiceProvider.overrideWithValue(LoggingService()),
          liveStackingServiceProvider.overrideWithValue(stacker),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(liveStackingProvider.notifier);
      await notifier.arm();

      final feed = LiveStackingFeed(
        sequence: () => null,
        progress: () => const SequenceProgress(),
        broadcast: () => container.read(liveStackingBroadcastServiceProvider),
        stacker: () => notifier,
        stackState: () => container.read(liveStackingProvider),
        logger: () => container.read(loggingServiceProvider),
      );

      feed.feed(_accepted('/captures/m42/L_0001.fits'));
      await feed.pending;
      await feed.teardown();

      expect(stacker.stops, 0);
      final state = container.read(liveStackingProvider);
      expect(state.status, LiveStackingStatus.running);
      expect(state.filterStacks, isNotEmpty);
    },
  );
}
