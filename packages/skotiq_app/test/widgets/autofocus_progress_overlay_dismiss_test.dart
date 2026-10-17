import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/autofocus_progress_overlay.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../harness/pump_app_screen.dart';

/// The finished-run summary must clear itself, seen from the rendered overlay.
///
/// [AutofocusProgressOverlay] is mounted once in the app shell, so nothing tears
/// it down when a run ends: without a self-clear the result pill floats over the
/// bottom-right of every screen the operator then visits. A FAILED run is the
/// opposite case — its status line is the only place the failure reason is
/// written, so it has to stay.
///
/// The countdown itself lives in AutofocusOverlayNotifier (skotiq_core).
/// These tests deliberately assert through the widget instead: what the
/// operator is owed is that the pill leaves the screen, and that contract must
/// hold whichever layer implements the timer.
const _result = AutofocusResult(
  bestPosition: 12500,
  bestHfr: 2.31,
  focusData: [],
  method: 'quadratic',
  timestamp: 0,
  curveFitQuality: 0.98,
  backlashApplied: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a completed run clears its own summary', (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const Stack(children: [AutofocusProgressOverlay()]),
      settle: false,
    );

    final overlay = handle.container.read(autofocusOverlayProvider.notifier)
      ..onAutofocusStarted();
    await tester.pump();

    overlay.onAutofocusCompleted(_result);
    await tester.pump();
    expect(find.textContaining('AF: HFR'), findsOneWidget);

    await tester.pump(
      AutofocusOverlayNotifier.resultAutoDismissDelay +
          const Duration(seconds: 1),
    );
    expect(
      find.textContaining('AF: HFR'),
      findsNothing,
      reason: 'The result summary followed the operator onto every other '
          'screen until it was dismissed by hand.',
    );
    expect(handle.container.read(autofocusOverlayProvider).isVisible, isFalse);
  });

  testWidgets('a cancelled run also clears itself', (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const Stack(children: [AutofocusProgressOverlay()]),
      settle: false,
    );

    final overlay = handle.container.read(autofocusOverlayProvider.notifier)
      ..onAutofocusStarted();
    await tester.pump();

    overlay.onAutofocusCancelled();
    await tester.pump();

    await tester.pump(
      AutofocusOverlayNotifier.resultAutoDismissDelay +
          const Duration(seconds: 1),
    );
    expect(
      handle.container.read(autofocusOverlayProvider).isVisible,
      isFalse,
      reason: 'A cancelled run carries nothing to read, so it must not camp '
          'on the corner of every screen either.',
    );
  });

  testWidgets('a failed run keeps its reason on screen', (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const Stack(children: [AutofocusProgressOverlay()]),
      settle: false,
    );

    final overlay = handle.container.read(autofocusOverlayProvider.notifier)
      ..onAutofocusStarted();
    await tester.pump();

    overlay.onAutofocusFailed('Focuser did not reach position');
    await tester.pump();

    await tester.pump(
      AutofocusOverlayNotifier.resultAutoDismissDelay +
          const Duration(minutes: 1),
    );
    expect(
      handle.container.read(autofocusOverlayProvider).isVisible,
      isTrue,
      reason: 'The failure reason is written nowhere else; auto-clearing it '
          'would lose the only account of why focus did not run.',
    );
  });

  testWidgets('a new run cancels the previous result countdown',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const Stack(children: [AutofocusProgressOverlay()]),
      settle: false,
    );

    final overlay = handle.container.read(autofocusOverlayProvider.notifier)
      ..onAutofocusStarted();
    await tester.pump();
    overlay.onAutofocusCompleted(_result);
    await tester.pump();

    // Operator immediately retries; the pending countdown belongs to the run
    // that just ended and must not close the live one out from under them.
    overlay.onAutofocusStarted();
    await tester.pump();

    await tester.pump(
      AutofocusOverlayNotifier.resultAutoDismissDelay +
          const Duration(seconds: 1),
    );
    expect(handle.container.read(autofocusOverlayProvider).isVisible, isTrue);
    expect(handle.container.read(autofocusOverlayProvider).isRunning, isTrue);
  });
}
