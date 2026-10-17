// The progress bar must not pump vsync while the run is not running.
//
// Measured before this was fixed: a run left PAUSED on the Sequencer screen
// held ~56 fps and ~62% of one core indefinitely, with nothing on screen
// moving. `_pulseController` was correctly stopped on pause, but the
// stall-detector's `Ticker` was started unconditionally in `initState` and
// stopped only in `dispose`. An active `Ticker` schedules a frame on every
// vsync whether or not anything is dirty, and the Flutter Linux embedder
// submits a full-window frame for every scheduled frame — so the bar kept the
// whole app awake to service a detector that is switched off while paused
// (`_stalledFor` returns null the moment `isRunning` is false).
//
// The bar is mounted for running AND paused: `sequencer_screen.dart` folds
// paused into its `isRunning` gate, which is why "paused" is not a state the
// widget can simply be unmounted out of.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_progress_bar.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

SequenceProgressBarState _stateOf(WidgetTester tester) =>
    tester.state<SequenceProgressBarState>(find.byType(SequenceProgressBar));

Widget _harness(SequenceExecutionState execState, {bool offstage = false}) {
  return ProviderScope(
    overrides: [
      sequenceExecutionStateProvider.overrideWith((ref) => execState),
    ],
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Offstage(
            offstage: offstage,
            child: SequenceProgressBar(colors: SkotiqColors.of(ctx)),
          ),
        ),
      ),
    ),
  );
}

void _setState(WidgetTester tester, SequenceExecutionState next) {
  ProviderScope.containerOf(
    tester.element(find.byType(SequenceProgressBar)),
  ).read(sequenceExecutionStateProvider.notifier).state = next;
}

void main() {
  group('SequenceProgressBar frame production', () {
    testWidgets('the stall-detector ticker runs only while running',
        (tester) async {
      await tester.pumpWidget(_harness(SequenceExecutionState.running));
      await tester.pump(const Duration(milliseconds: 16));

      expect(
        _stateOf(tester).debugElapsedTickerActiveForTesting,
        isTrue,
        reason: 'the stall detector needs its clock while the run is running',
      );

      _setState(tester, SequenceExecutionState.paused);
      await tester.pump(const Duration(milliseconds: 16));

      expect(
        _stateOf(tester).debugElapsedTickerActiveForTesting,
        isFalse,
        reason: 'a paused run must not pump vsync for a detector that is off',
      );
    });

    testWidgets('a paused bar schedules no further frames', (tester) async {
      await tester.pumpWidget(_harness(SequenceExecutionState.paused));
      // Settle whatever the first build legitimately scheduled.
      await tester.pumpAndSettle(const Duration(milliseconds: 16));

      expect(
        _stateOf(tester).debugPulseControllerForTesting.isAnimating,
        isFalse,
        reason: 'precondition: the background pulse is stopped while paused',
      );
      expect(
        _stateOf(tester).debugElapsedTickerActiveForTesting,
        isFalse,
        reason: 'precondition: the stall clock is stopped while paused',
      );
      // The observable consequence, and the one the CPU bill is written
      // against: nothing in this subtree has asked for another frame.
      expect(
        tester.binding.hasScheduledFrame,
        isFalse,
        reason: 'a paused progress bar must let the app idle',
      );
    });

    testWidgets('a RUNNING bar that nothing paints stops pulsing',
        (tester) async {
      // The bar is mounted for the whole run. Its 2 s background pulse used
      // to be gated on `isPaused` alone, so anywhere the bar was mounted but
      // not drawn it kept repeating — and a repeating AnimationController
      // schedules a frame on every vsync, which on this embedder is a
      // full-window frame. `OnScreenAnimationGate` ANDs "do we want it"
      // with "is it being painted".
      await tester.pumpWidget(_harness(SequenceExecutionState.running));
      await tester.pump(const Duration(milliseconds: 16));
      // Held across the offstage flip: the default finders skip offstage
      // subtrees, and it is the same State either way (the widget is moved,
      // not remounted).
      final pulse = _stateOf(tester).debugPulseControllerForTesting;
      expect(
        pulse.isAnimating,
        isTrue,
        reason: 'precondition: a visible running bar pulses',
      );

      await tester.pumpWidget(
        _harness(SequenceExecutionState.running, offstage: true),
      );
      // The gate allows two unpainted ticks before concluding it is invisible.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(
        pulse.isAnimating,
        isFalse,
        reason: 'an unpainted pulse is pure vsync cost with nothing to show',
      );
    });

    testWidgets('the clock restarts, from zero, when the run resumes',
        (tester) async {
      await tester.pumpWidget(_harness(SequenceExecutionState.running));
      await tester.pump(const Duration(milliseconds: 500));
      _setState(tester, SequenceExecutionState.paused);
      await tester.pump(const Duration(milliseconds: 16));
      expect(_stateOf(tester).debugElapsedTickerActiveForTesting, isFalse);

      _setState(tester, SequenceExecutionState.running);
      await tester.pump(const Duration(milliseconds: 16));

      expect(
        _stateOf(tester).debugElapsedTickerActiveForTesting,
        isTrue,
        reason: 'resuming the run must put the stall detector back on watch',
      );
      // A resumed ticker starts its elapsed count at zero again, so the
      // stall window has to have been reset with it — otherwise the first
      // post-resume comparison measures a fresh clock against a stale mark.
      // Nothing is reported as stalled here: a stall needs at least
      // `_kStallSlack` (60 s) of measured silence, and the clock just
      // restarted.
      expect(find.textContaining('stalled'), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('stalled'), findsNothing);
    });
  });
}
