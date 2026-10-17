import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/sequence_provider.dart';
import 'package:skotiq_core/src/services/pre_session_simulator.dart';
import 'package:skotiq_core/src/services/sequence_time_estimator.dart';
import '../../harness/in_memory_database.dart';

/// Tests for the tree-row "~2h 14m" rollup provider.
///
/// The provider bills each node with [SequenceTimeEstimator.nodeDuration] —
/// the same per-node model the timeline, the node-timing panel and the
/// pre-flight simulation use — and rolls the results up per container. We
/// assert against hand-computed sums so a future change to the underlying math
/// has to come look at this file.
///
/// The per-frame download overhead below is 2 s because that is
/// `SequencerDefaults.frameDownloadOverheadSecs`, the user-configurable value
/// `sequencerOverheadConfigProvider` feeds to every estimate surface. It was
/// 3 s here while the rollup carried its own copy of the overhead table, which
/// is why the Builder's estimate chip and the Pre-Flight panel disagreed.

ProviderContainer _containerWith(Sequence sequence) {
  // Seed the real notifier so we don't have to mock its public surface.
  // It takes a nullable Ref; passing null is fine for these read-only
  // tests (the notifier only consults Ref to guard mutations).
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      // Pin the shared overhead model instead of letting it resolve through
      // the DB-backed sequencer defaults: these tests are about the per-node
      // math, and a real database per container is both slow and flaky here.
      // The value is the one `sequencerOverheadConfigProvider` produces from
      // stock defaults, so the numbers below are the shipped ones.
      sequencerOverheadConfigProvider.overrideWithValue(
        SequenceTimeEstimator.defaultEstimatorOverhead,
      ),
      currentSequenceProvider.overrideWith((ref) {
        final notifier = CurrentSequenceNotifier();
        // ignore: invalid_use_of_protected_member
        notifier.state = sequence;
        return notifier;
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Sequence _seq(SequenceNode root, Map<String, SequenceNode> nodes) {
  return Sequence.create(name: 'test', nodes: nodes, rootNodeId: root.id);
}

void main() {
  group('formatRollupDuration', () {
    test('zero shows <1s', () {
      expect(formatRollupDuration(Duration.zero), '<1s');
      expect(formatRollupDuration(const Duration(milliseconds: 1)), '<1s');
    });

    test('seconds-only', () {
      expect(formatRollupDuration(const Duration(seconds: 45)), '~45s');
    });

    test('minutes + seconds', () {
      expect(
        formatRollupDuration(const Duration(minutes: 14, seconds: 30)),
        '~14m 30s',
      );
    });

    test('hours + minutes', () {
      expect(
        formatRollupDuration(const Duration(hours: 2, minutes: 14)),
        '~2h 14m',
      );
    });
  });

  group('nodeRollupDurationProvider', () {
    test('returns zero when no sequence is loaded', () {
      final container = ProviderContainer(
        overrides: [inMemoryDatabaseOverride()],
      );
      addTearDown(container.dispose);
      final d = container.read(nodeRollupDurationProvider('any-id'));
      expect(d, Duration.zero);
    });

    test('Target -> Loop(count:3) -> Exposure sums correctly', () {
      // 60s exposure × 4 frames = 240s integration + 4×2s download = 248s
      // per loop iteration. Loop count = 3 -> 744s. Target rollup wraps
      // the loop -> 744s. (No leaf overhead because Exposure overhead is
      // already baked into the per-exposure download.)
      final expo = ExposureNode(name: 'Lum', durationSecs: 60, count: 4);
      final loop = LoopNode(
        name: 'Loop',
        repeatCount: 3,
        conditionType: LoopConditionType.count,
      );
      final target = TargetHeaderNode(
        targetName: 'M31',
        raHours: 0,
        decDegrees: 0,
      );
      final root = InstructionSetNode(name: 'Root');

      // Wire up the tree.
      final tree = <String, SequenceNode>{
        expo.id: expo.copyWith(parentId: loop.id),
        loop.id: loop.copyWith(parentId: target.id, childIds: [expo.id]),
        target.id: target.copyWith(parentId: root.id, childIds: [loop.id]),
        root.id: root.copyWith(childIds: [target.id]),
      };
      final container = _containerWith(_seq(root, tree));

      const expoSecs = 60 * 4 + 2.0 * 4; // 248
      expect(
        container.read(nodeRollupDurationProvider(expo.id)).inSeconds,
        expoSecs.round(),
      );
      expect(
        container.read(nodeRollupDurationProvider(loop.id)).inSeconds,
        (expoSecs * 3).round(),
      );
      expect(
        container.read(nodeRollupDurationProvider(target.id)).inSeconds,
        (expoSecs * 3).round(),
      );
    });

    test('Parallel returns max(children), not sum', () {
      // Two exposures, one 30s×1 (32s), one 60s×1 (62s). Parallel should
      // report 62s (the slower child), not 94s.
      final fast = ExposureNode(durationSecs: 30, count: 1, name: 'fast');
      final slow = ExposureNode(durationSecs: 60, count: 1, name: 'slow');
      final parallel = ParallelNode(name: 'p');
      final root = InstructionSetNode(name: 'Root');

      final tree = <String, SequenceNode>{
        fast.id: fast.copyWith(parentId: parallel.id),
        slow.id: slow.copyWith(parentId: parallel.id),
        parallel.id: parallel.copyWith(
          parentId: root.id,
          childIds: [fast.id, slow.id],
        ),
        root.id: root.copyWith(childIds: [parallel.id]),
      };
      final container = _containerWith(_seq(root, tree));

      final parallelSecs = container
          .read(nodeRollupDurationProvider(parallel.id))
          .inSeconds;
      // Expected: max(32, 62) = 62
      expect(parallelSecs, 62);
    });

    test('disabled nodes contribute zero', () {
      final disabled = ExposureNode(
        durationSecs: 60,
        count: 4,
        name: 'off',
        isEnabled: false,
      );
      final enabled = ExposureNode(durationSecs: 30, count: 2, name: 'on');
      final set = InstructionSetNode(name: 'set');
      final root = InstructionSetNode(name: 'Root');

      final tree = <String, SequenceNode>{
        disabled.id: disabled.copyWith(parentId: set.id),
        enabled.id: enabled.copyWith(parentId: set.id),
        set.id: set.copyWith(
          parentId: root.id,
          childIds: [disabled.id, enabled.id],
        ),
        root.id: root.copyWith(childIds: [set.id]),
      };
      final container = _containerWith(_seq(root, tree));

      final setSecs = container
          .read(nodeRollupDurationProvider(set.id))
          .inSeconds;
      // Expected: enabled-only = 30×2 + 2×2 = 64s
      expect(setSecs, 64);
    });

    test('unbounded loop reports single-iteration duration', () {
      final expo = ExposureNode(durationSecs: 10, count: 1, name: 'expo');
      final loop = LoopNode(
        name: 'Forever',
        conditionType: LoopConditionType.forever,
      );
      final root = InstructionSetNode(name: 'Root');

      final tree = <String, SequenceNode>{
        expo.id: expo.copyWith(parentId: loop.id),
        loop.id: loop.copyWith(parentId: root.id, childIds: [expo.id]),
        root.id: root.copyWith(childIds: [loop.id]),
      };
      final container = _containerWith(_seq(root, tree));

      // Single iteration: 10 + 2 = 12s. No multiplier for unbounded.
      expect(container.read(nodeRollupDurationProvider(loop.id)).inSeconds, 12);
    });
  });

  group('one estimate, not three', () {
    // The Builder's estimate chip said "~18m 54s" while the Pre-Flight
    // Simulation panel said "Duration 27m" for the identical sequence, both on
    // screen at once. The tree rollup carried its own table of per-node costs:
    // it billed Cool Camera at a flat "cooling" constant instead of the node's
    // configured duration, and billed Delay / Wait / Park / Script / Rotator at
    // ZERO because they were not in its table at all.
    Sequence mixedSequence() {
      final cool = CoolCameraNode(
        id: 'cool',
        name: 'Cool Camera',
        targetTemp: 15,
        durationMins: 2,
        parentId: 'target',
      );
      final delay = DelayNode(
        id: 'delay',
        name: 'Settle',
        seconds: 45,
        parentId: 'target',
      );
      final expo = ExposureNode(
        id: 'expo',
        name: 'Lights',
        durationSecs: 3,
        count: 4,
        parentId: 'target',
      );
      final target = TargetHeaderNode(
        id: 'target',
        name: 'Target',
        targetName: 'M42',
        raHours: 5.59,
        decDegrees: -5.39,
        childIds: const ['cool', 'delay', 'expo'],
      );
      return Sequence.create(
        name: 'mixed',
        rootNodeId: 'target',
        nodes: {'target': target, 'cool': cool, 'delay': delay, 'expo': expo},
      );
    }

    test('the Builder rollup and the Pre-Flight simulation agree', () {
      final sequence = mixedSequence();
      final container = _containerWith(sequence);

      final rollup = container.read(nodeRollupDurationProvider('target'));
      final simulated = PreSessionSimulator(
        estimator: SequenceTimeEstimator(
          overhead: container.read(sequencerOverheadConfigProvider),
        ),
      ).simulate(sequence, start: DateTime(2024, 1, 1, 22));

      expect(
        rollup.inSeconds,
        simulated.duration.inSeconds,
        reason: 'two surfaces describing one sequence must bill it the same',
      );
    });

    test('a Delay node costs its own duration, not zero', () {
      final container = _containerWith(mixedSequence());
      expect(
        container.read(nodeRollupDurationProvider('delay')).inSeconds,
        45,
        reason: 'the old rollup table had no entry for Delay',
      );
    });

    test('Cool Camera costs the duration the node is configured for', () {
      final container = _containerWith(mixedSequence());
      expect(
        container.read(nodeRollupDurationProvider('cool')).inSeconds,
        2 * 60,
        reason: 'the old rollup billed a flat cooling constant instead',
      );
    });
  });
}
