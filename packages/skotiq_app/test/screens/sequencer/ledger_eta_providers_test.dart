// The minute clock behind the ledger's ETA column, and the lifetime its
// correctness depends on (spec §2). The observed-start record it also reads is
// core's `runNodeTimesProvider`, tested there.
//
// `ledger_columns_test.dart` covers the arithmetic. This covers the parts the
// arithmetic cannot see: whether the minute clock really reaches the map while
// a run is in flight (a run falling behind only shows when the clock moves).

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_app/screens/sequencer/widgets/visual_timeline.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

/// 22:00, the anchor every simulation below is built at.
final DateTime _t0 = DateTime(2026, 9, 13, 22, 0);

/// Root -> [a, b, c], each billed five minutes apart.
({Sequence sequence, List<SequenceNode> steps}) _threeSteps() {
  final steps = <DelayNode>[
    DelayNode(name: 'a', seconds: 60),
    DelayNode(name: 'b', seconds: 60),
    DelayNode(name: 'c', seconds: 60),
  ];
  final root = InstructionSetNode(name: 'Root');
  final placed = <SequenceNode>[
    for (var i = 0; i < steps.length; i++)
      steps[i].copyWith(parentId: root.id, orderIndex: i),
  ];
  return (
    sequence: Sequence.create(
      name: 'T',
      rootNodeId: root.id,
      nodes: {
        for (final step in placed) step.id: step,
        root.id: root.copyWith(childIds: [for (final s in placed) s.id]),
      },
    ),
    steps: placed,
  );
}

PreSessionSimulationResult _simulation(List<SequenceNode> steps) {
  return PreSessionSimulationResult(
    start: _t0,
    end: _t0.add(const Duration(minutes: 15)),
    duration: const Duration(minutes: 15),
    segments: [
      for (var i = 0; i < steps.length; i++)
        PreSessionSimulationSegment(
          nodeId: steps[i].id,
          nodeName: steps[i].name,
          nodeType: 'Delay',
          // Back to back, five minutes each: `b` runs 22:05 -> 22:10.
          start: _t0.add(Duration(minutes: 5 * i)),
          end: _t0.add(Duration(minutes: 5 * (i + 1))),
          duration: const Duration(minutes: 5),
        ),
    ],
    targetWindows: const {},
    issues: const [],
  );
}

/// Let Riverpod's auto-dispose pass, and the stream cancellation it triggers.
/// Neither is synchronous: the dispose is scheduled after the last listener
/// goes, and the subscription's own `cancel()` completes a turn later again.
Future<void> _settleDisposal() async {
  for (var i = 0; i < 3; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

// Deliberately NO `TestWidgetsFlutterBinding.ensureInitialized()`. With the
// widget binding installed, Riverpod schedules auto-disposal against the
// scheduler's frames — and a plain `test` never pumps one, so nothing is ever
// disposed and the two lifetime assertions below would pass vacuously.
void main() {
  group('ledgerClockProvider', () {
    test('feeds the ETA map while a run is in flight', () async {
      final built = _threeSteps();
      final clock = StreamController<DateTime>.broadcast();
      addTearDown(clock.close);
      final sequence = CurrentSequenceNotifier();
      // ignore: invalid_use_of_protected_member
      sequence.state = built.sequence;

      final container = ProviderContainer(overrides: [
        currentSequenceProvider.overrideWith((_) => sequence),
        sequenceTimelineProvider.overrideWithValue(_simulation(built.steps)),
        ledgerClockProvider.overrideWith((ref) => clock.stream),
        clockProvider.overrideWithValue(const SystemClock()),
      ]);
      addTearDown(container.dispose);

      container
          .read(runRecordProvider.notifier)
          .setLifecycle(SequenceExecutionState.running);
      container
          .read(runRecordProvider.notifier)
          .updateProgress(currentNodeId: built.steps[1].id);
      container.listen(ledgerEtaProvider, (_, __) {});

      // 22:05: `b` is executing exactly when the plan said, so `c` keeps its
      // planned 22:10.
      clock.add(_t0.add(const Duration(minutes: 5)));
      await _settleDisposal();
      expect(
        container.read(ledgerEtaProvider)[built.steps[2].id]!.start,
        _t0.add(const Duration(minutes: 10)),
      );

      // 22:45 and `b` is STILL going, thirty-five minutes past the moment the
      // plan had it finished. The column has to say so, and it only can if the
      // clock reaches it. Before this provider ticked during a run, it did not.
      clock.add(_t0.add(const Duration(minutes: 45)));
      await _settleDisposal();
      expect(
        container.read(ledgerEtaProvider)[built.steps[2].id]!.start,
        _t0.add(const Duration(minutes: 45)),
        reason: 'a run well past its own plan must not quote sunset ETAs',
      );
    });

    test('a minute tick during an on-plan run changes no row', () async {
      final built = _threeSteps();
      final clock = StreamController<DateTime>.broadcast();
      addTearDown(clock.close);
      final sequence = CurrentSequenceNotifier();
      // ignore: invalid_use_of_protected_member
      sequence.state = built.sequence;

      final container = ProviderContainer(overrides: [
        currentSequenceProvider.overrideWith((_) => sequence),
        sequenceTimelineProvider.overrideWithValue(_simulation(built.steps)),
        ledgerClockProvider.overrideWith((ref) => clock.stream),
        clockProvider.overrideWithValue(const SystemClock()),
      ]);
      addTearDown(container.dispose);

      container
          .read(runRecordProvider.notifier)
          .setLifecycle(SequenceExecutionState.running);
      container
          .read(runRecordProvider.notifier)
          .updateProgress(currentNodeId: built.steps[1].id);
      container.listen(ledgerEtaProvider, (_, __) {});

      // `b` is billed 22:05 -> 22:10 and began on time.
      clock.add(_t0.add(const Duration(minutes: 5)));
      await _settleDisposal();
      final atFive = container.read(ledgerEtaProvider);

      clock.add(_t0.add(const Duration(minutes: 6)));
      await _settleDisposal();

      expect(
        container.read(ledgerEtaProvider),
        atFive,
        reason: 'a clock that moved a row every minute would rebuild the whole '
            'ledger every minute, all night, for a run that is on plan',
      );
    });

    test('its subscription ends with its last listener', () async {
      // The clock now ticks THROUGH a run, so the thing that stops its timer
      // is auto-disposal and nothing else. A fresh subscription on the way back
      // in is the observable proof that the previous one was let go: the
      // provider body runs exactly once per live subscription.
      var subscriptions = 0;
      final container = ProviderContainer(overrides: [
        ledgerClockProvider.overrideWith((ref) {
          subscriptions += 1;
          return const Stream<DateTime>.empty();
        }),
      ]);
      addTearDown(container.dispose);

      final first = container.listen(ledgerClockProvider, (_, __) {});
      expect(subscriptions, 1);

      first.close();
      await _settleDisposal();
      container.listen(ledgerClockProvider, (_, __) {});
      expect(
        subscriptions,
        2,
        reason: 'a minute timer must not outlive the tree that wanted it',
      );
    });
  });
}
