// Regression tests for the "Skip while paused" capability drift.
//
// The canonical run-control contract (SequenceExecutionStateCapabilities)
// declares `canSkip == running || paused`: the backend skip advances the node
// pointer in both states, and the desktop toolbar and mobile playback bar both
// route through it. The app-shell mini bar had drifted to an open-coded
// `isRunning`, so a PAUSED run could not be skipped from it. These tests pin
// that the mini bar and the mobile playback bar dispatch a skip while paused.
// Tonight's header takes `canSkip` from the same capability through
// `nightHeaderProvider`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/running_sequence_mini_bar.dart';
import 'package:skotiq_app/screens/sequencer/widgets/mobile_playback_bar.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../harness/harness.dart';

/// Records the skip calls the run-control surfaces route through the executor.
class _SkipRecordingExecutor extends SequenceExecutor {
  _SkipRecordingExecutor(super.ref);

  int skipCount = 0;

  @override
  Future<void> skip() async {
    skipCount++;
  }
}

void _swallowKnownOverflows() {
  final defaultOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exceptionAsString().contains('overflowed')) return;
    defaultOnError?.call(details);
  };
  addTearDown(() => FlutterError.onError = defaultOnError);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app-shell mini bar dispatches a skip while PAUSED',
      (tester) async {
    _swallowKnownOverflows();
    late _SkipRecordingExecutor executor;
    final handle = await pumpAppScreen(
      tester,
      // A location without its own run controls, so the mini bar renders (it
      // hides on the sequencer route and on Tonight, whose pages carry the
      // run controls themselves).
      const RunningSequenceMiniBar(currentLocation: '/weather'),
      size: const Size(1000, 400),
      settle: false,
      extraOverrides: [
        sequenceExecutionStateProvider
            .overrideWith((ref) => SequenceExecutionState.paused),
        sequenceExecutorProvider.overrideWith((ref) {
          executor = _SkipRecordingExecutor(ref);
          return executor;
        }),
      ],
    );
    await tester.pump();
    handle.container.read(sequenceExecutorProvider);

    final skip = find.byTooltip('Skip');
    expect(skip, findsOneWidget,
        reason: 'The mini bar renders a Skip control while paused.');

    await tester.tap(skip);
    await tester.pump();
    await tester.pump();

    expect(executor.skipCount, 1,
        reason: 'A paused run must be skippable from the mini bar (canSkip).');
  });

  // Retargeted from the deleted `SequenceControls`, which had no call site in
  // any screen — the surface that actually ships on mobile is
  // [MobilePlaybackBar], mounted by the sequencer's mobile layout.
  testWidgets('the mobile playback bar dispatches a skip while PAUSED',
      (tester) async {
    late _SkipRecordingExecutor executor;
    final handle = await pumpAppScreen(
      tester,
      Builder(
        builder: (context) =>
            MobilePlaybackBar(colors: SkotiqColors.of(context)),
      ),
      size: const Size(430, 400),
      settle: false,
      extraOverrides: [
        sequenceExecutionStateProvider
            .overrideWith((ref) => SequenceExecutionState.paused),
        sequenceExecutorProvider.overrideWith((ref) {
          executor = _SkipRecordingExecutor(ref);
          return executor;
        }),
      ],
    );
    await tester.pump();
    handle.container.read(sequenceExecutorProvider);

    // Icon-only control: the label lives in its tooltip.
    await tester.tap(find.byTooltip('Skip'));
    await tester.pump();
    await tester.pump();

    expect(executor.skipCount, 1);
  });
}
