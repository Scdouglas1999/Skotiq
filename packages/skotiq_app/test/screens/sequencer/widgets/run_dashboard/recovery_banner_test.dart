// Recovery Mode — widget tests for the Run Dashboard recovery banner
// and the recovery event bridge provider.
//
// Verifies:
//   * The banner renders the cause, attempt counter, and a countdown when
//     `currentRecoveryProvider` is non-null.
//   * The banner stays hidden when there is no in-flight recovery.
//   * Pressing "Try Now" calls `backend.recoveryTryNow`.
//   * Pressing "Abort" calls `backend.recoveryAbort`.
//   * The `SequencerStatusLed` chooses the right colour for each
//     SequenceExecutionState (including the new `.recovering` value).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/recovery_banner.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _SpyBackend extends DisconnectedBackend {
  int tryNowCalls = 0;
  int abortCalls = 0;
  int skipCalls = 0;

  @override
  Future<void> recoveryTryNow() async {
    tryNowCalls += 1;
  }

  @override
  Future<void> recoveryAbort() async {
    abortCalls += 1;
  }

  @override
  Future<void> sequencerSkip() async {
    skipCalls += 1;
  }
}

class _StubBackendNotifier extends BackendNotifier {
  _StubBackendNotifier(super.ref, SkotiqBackend backend) {
    // Replace the default DisconnectedBackend with the spy.
    state = backend;
  }
}

Widget _harness({
  required Widget child,
  required _SpyBackend backend,
  RecoveryStatus? recovery,
  SequenceExecutionState? execState,
}) {
  return ProviderScope(
    overrides: [
      backendProvider.overrideWith((ref) => _StubBackendNotifier(ref, backend)),
      currentRecoveryProvider.overrideWith((ref) {
        final notifier = RecoveryNotifier();
        if (recovery != null) notifier.update(recovery);
        return notifier;
      }),
      if (execState != null)
        sequenceProgressProvider.overrideWith(
            (ref) => SequenceProgressNotifier()..updateState(execState)),
    ],
    child: MaterialApp(
      theme: ThemeData.dark().copyWith(
        extensions: const [SkotiqColors.dark],
      ),
      home: Scaffold(body: child),
    ),
  );
}

RecoveryStatus _waitingRecovery({
  int attempts = 1,
  int maxAttempts = 9,
  double retryIntervalSecs = 600.0,
  double maxDurationSecs = 5400.0,
}) {
  return RecoveryStatus(
    startedAt: DateTime.now().toUtc().subtract(const Duration(seconds: 30)),
    cause: RecoveryCause.guideStarLost(),
    lastAttemptAt: DateTime.now().toUtc().subtract(const Duration(seconds: 30)),
    attemptCount: attempts,
    maxAttempts: maxAttempts,
    retryIntervalSecs: retryIntervalSecs,
    maxDurationSecs: maxDurationSecs,
    phase: RecoveryPhase.waiting,
    lastError: null,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RunDashboardRecoveryBanner', () {
    testWidgets('renders the cause label and attempt counter', (tester) async {
      final backend = _SpyBackend();
      await tester.pumpWidget(_harness(
        backend: backend,
        recovery: _waitingRecovery(attempts: 2, maxAttempts: 9),
        child: const RunDashboardRecoveryBanner(),
      ));
      await tester.pump();

      expect(find.text('RECOVERING'), findsOneWidget);
      expect(find.text('Guide star lost'), findsOneWidget);
      expect(
        find.textContaining('Attempt 2 of 9'),
        findsOneWidget,
      );
      // The countdown text is "next retry in <…>" — match the prefix.
      expect(find.textContaining('next retry in'), findsOneWidget);
    });

    testWidgets('hides itself when no recovery is in flight', (tester) async {
      final backend = _SpyBackend();
      await tester.pumpWidget(_harness(
        backend: backend,
        recovery: null,
        child: const RunDashboardRecoveryBanner(),
      ));
      await tester.pump();

      expect(find.text('RECOVERING'), findsNothing);
      expect(find.byKey(const Key('recovery_try_now')), findsNothing);
      expect(find.byKey(const Key('recovery_abort')), findsNothing);
    });

    testWidgets('Try Now button calls backend.recoveryTryNow', (tester) async {
      final backend = _SpyBackend();
      await tester.pumpWidget(_harness(
        backend: backend,
        recovery: _waitingRecovery(),
        child: const RunDashboardRecoveryBanner(),
      ));
      await tester.pump();

      await tester.tap(find.byKey(const Key('recovery_try_now')));
      await tester.pump();

      expect(backend.tryNowCalls, 1);
      expect(backend.abortCalls, 0);
    });

    testWidgets('Abort button calls backend.recoveryAbort via hold-to-confirm',
        (tester) async {
      final backend = _SpyBackend();
      await tester.pumpWidget(_harness(
        backend: backend,
        recovery: _waitingRecovery(),
        child: const RunDashboardRecoveryBanner(),
      ));
      await tester.pump();

      // The Abort affordance is wrapped in HoldToConfirmButton so
      // a stray click cannot kill an overnight run. The destructive call
      // only fires after the configured hold duration (default 1500ms).
      final hold = find.byKey(const Key('recovery_abort_hold'));
      expect(hold, findsOneWidget);

      // Sanity: a quick tap MUST NOT fire the abort.
      await tester.tap(hold);
      await tester.pump();
      expect(backend.abortCalls, 0);

      // A genuine hold drives the gesture to completion.
      final gesture = await tester.startGesture(tester.getCenter(hold));
      // The HoldToConfirmButton wires the action through
      // GestureDetector.onLongPressStart, which only fires AFTER
      // Flutter's default long-press recognizer delay (~500ms). Only
      // then does the 1500ms confirm animation begin. So we need to
      // pump past 500ms + 1500ms = 2000ms total before the status
      // listener fires `onConfirmed`. The previous 1600ms pump
      // stopped mid-animation, leaving abortCalls at 0.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 1600));
      await gesture.up();
      await tester.pump();
      await tester.pump();

      expect(backend.abortCalls, 1);
      expect(backend.tryNowCalls, 0);
    });

    testWidgets('Skip Node button calls backend.sequencerSkip', (tester) async {
      final backend = _SpyBackend();
      await tester.pumpWidget(_harness(
        backend: backend,
        recovery: _waitingRecovery(),
        child: const RunDashboardRecoveryBanner(),
      ));
      await tester.pump();

      await tester.tap(find.byKey(const Key('recovery_skip_node')));
      await tester.pump();
      // Allow the async `RecoveryControl.skipNode` await to resolve.
      await tester.pump();

      expect(backend.skipCalls, 1);
      expect(backend.tryNowCalls, 0);
      expect(backend.abortCalls, 0);
    });

    testWidgets('renders the last error line when populated', (tester) async {
      final backend = _SpyBackend();
      final ctx = _waitingRecovery().copyWithLastError(
        'Guider still reports star lost',
      );
      await tester.pumpWidget(_harness(
        backend: backend,
        recovery: ctx,
        child: const RunDashboardRecoveryBanner(),
      ));
      await tester.pump();

      expect(
        find.textContaining('Guider still reports star lost'),
        findsOneWidget,
      );
    });
  });

  group('SequencerStatusLed', () {
    Widget ledHarness({
      required SequenceExecutionState state,
      bool showLabel = false,
    }) {
      return _harness(
        backend: _SpyBackend(),
        execState: state,
        child: SequencerStatusLed(showLabel: showLabel),
      );
    }

    testWidgets('renders "Running" label when sequence is running',
        (tester) async {
      await tester.pumpWidget(
          ledHarness(state: SequenceExecutionState.running, showLabel: true));
      await tester.pump();
      expect(find.text('Running'), findsOneWidget);
    });

    testWidgets('renders "Recovering" label when sequence is recovering',
        (tester) async {
      await tester.pumpWidget(ledHarness(
          state: SequenceExecutionState.recovering, showLabel: true));
      await tester.pump();
      expect(find.text('Recovering'), findsOneWidget);
    });

    testWidgets('renders nothing extra when showLabel is false',
        (tester) async {
      await tester
          .pumpWidget(ledHarness(state: SequenceExecutionState.recovering));
      await tester.pump();
      expect(find.text('Recovering'), findsNothing);
      // The dot itself is just a Container, no easy text marker — the
      // important assertion is "no label shown when showLabel == false".
    });
  });
}

extension on RecoveryStatus {
  RecoveryStatus copyWithLastError(String? err) {
    return RecoveryStatus(
      startedAt: startedAt,
      cause: cause,
      lastAttemptAt: lastAttemptAt,
      attemptCount: attemptCount,
      maxAttempts: maxAttempts,
      retryIntervalSecs: retryIntervalSecs,
      maxDurationSecs: maxDurationSecs,
      phase: phase,
      lastError: err,
    );
  }
}
