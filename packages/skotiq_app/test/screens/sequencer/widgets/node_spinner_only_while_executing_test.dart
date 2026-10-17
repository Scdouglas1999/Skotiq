// A node icon spins only while the run is actually executing.
//
// Two separate defects met here, and both were measured on the running app:
//
//  1. The native executor announced `NodeStarted` for every node it entered
//     and never announced the terminal status, so every node a run touched —
//     the root container included — stayed `NodeStatus.running` forever. A
//     finished run therefore drew a tree of nodes claiming to be executing.
//     (Fixed in `executor/start/progress_callback.rs`; pinned by the Rust
//     tests in that file.)
//
//  2. Even with an honest status, `running` was read as "spin". A PAUSED run
//     has nothing executing in it, so its nodes kept spinning too: measured at
//     61 fps and 46% of one core with the app otherwise idle, because the
//     Flutter Linux embedder submits a full-window frame for every scheduled
//     frame and a repeating AnimationController schedules one every vsync.
//
// This test pins (2), which is also the belt to (1)'s braces: a stale
// `running` status can no longer animate on a run that is not running.
//
// Only the spin is gated. The node's running stripe, highlight and live
// progress panel still say "this is the node the run is on" while paused,
// which is true.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequencer_density.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// The gate is what actually drives the spin: `_SpinningIcon` creates its
/// controller idle and hands it to an `OnScreenAnimationGate`. Counting gates
/// therefore counts running spinners without reaching into a private widget.
Finder get _spinners => find.byType(OnScreenAnimationGate);

Future<String> _pumpRunningNode(
  WidgetTester tester,
  ProviderContainer container,
) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(900, 900);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  container.read(currentSequenceProvider.notifier).createSequence(name: 'run');
  final node = ExposureNode(durationSecs: 3, count: 10);
  container.read(currentSequenceProvider.notifier).addNode(node);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: SequenceTree(colors: SkotiqColors.dark),
        ),
      ),
    ),
  );
  // liveValidationProvider debounces with a 500ms one-shot Timer on mutation.
  await tester.pump(const Duration(milliseconds: 600));

  container.read(sequenceExecutionStateProvider.notifier).state =
      SequenceExecutionState.running;
  container
      .read(sequenceProgressProvider.notifier)
      .updateNodeStatus(node.id, NodeStatus.running);
  await tester.pump(const Duration(milliseconds: 16));
  return node.id;
}

void _setExecutionState(
  ProviderContainer container,
  SequenceExecutionState state,
) {
  container.read(sequenceExecutionStateProvider.notifier).state = state;
}

void main() {
  testWidgets('a running node spins; a paused one stops', (tester) async {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        // The spinner lives on the comfortable card row; the ledger row
        // marks a running step with its tint + progress bar instead.
        sequencerDensityProvider
            .overrideWith((ref) => SequencerDensity.comfortable),
      ],
    );
    addTearDown(container.dispose);

    await _pumpRunningNode(tester, container);
    expect(
      _spinners,
      findsWidgets,
      reason: 'a node the run is executing must show it is executing',
    );

    _setExecutionState(container, SequenceExecutionState.paused);
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      _spinners,
      findsNothing,
      reason: 'a paused run is executing nothing — nothing may spin',
    );

    _setExecutionState(container, SequenceExecutionState.running);
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      _spinners,
      findsWidgets,
      reason: 'resuming the run puts the spinner back',
    );
  });

  testWidgets('a node left marked running after the run ends does not spin',
      (tester) async {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        // The spinner lives on the comfortable card row; the ledger row
        // marks a running step with its tint + progress bar instead.
        sequencerDensityProvider
            .overrideWith((ref) => SequencerDensity.comfortable),
      ],
    );
    addTearDown(container.dispose);

    await _pumpRunningNode(tester, container);
    expect(_spinners, findsWidgets);

    // The run ends. Whether or not the node's own terminal status has arrived
    // (it now does — see progress_callback.rs — but a remote host, a crash or
    // an older backend may not send it), a run that is over animates nothing.
    _setExecutionState(container, SequenceExecutionState.completed);
    await tester.pump(const Duration(milliseconds: 16));

    expect(
      _spinners,
      findsNothing,
      reason: 'a finished run must not leave icons spinning at 60 fps',
    );
  });

  testWidgets('a paused tree comes to rest', (tester) async {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        // The spinner lives on the comfortable card row; the ledger row
        // marks a running step with its tint + progress bar instead.
        sequencerDensityProvider
            .overrideWith((ref) => SequencerDensity.comfortable),
      ],
    );
    addTearDown(container.dispose);

    await _pumpRunningNode(tester, container);
    _setExecutionState(container, SequenceExecutionState.paused);

    // The consequence the CPU bill is written against: with nothing animating,
    // the tree stops asking for frames. `pumpAndSettle` throws if it does not.
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
