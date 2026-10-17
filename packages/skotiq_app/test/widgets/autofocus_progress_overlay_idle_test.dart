import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/autofocus_progress_overlay.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../harness/pump_app_screen.dart';

/// The overlay animates when, and ONLY when, there is a live autofocus run to
/// animate.
///
/// [AutofocusProgressOverlay] is mounted once in the app shell, so it is alive
/// on every screen for the entire session and its State is never disposed. An
/// unconditional `_pulseController.repeat(reverse: true)` in `initState`
/// therefore re-schedules a frame on every vsync from launch to quit — around
/// 45 fps while completely idle, with nothing to draw. The pulse it animates is
/// only ever built while a run is in progress.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'the shell-mounted overlay lets the app idle when no autofocus '
      'is running', (tester) async {
    await pumpAppScreen(
      tester,
      const Stack(children: [AutofocusProgressOverlay()]),
      settle: false,
    );

    await _expectIdlesAtRest(tester, 'an idle AutofocusProgressOverlay');
  });

  testWidgets('the overlay still idles after an autofocus run finishes',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const Stack(children: [AutofocusProgressOverlay()]),
      settle: false,
    );

    final overlay = handle.container.read(autofocusOverlayProvider.notifier)
      ..onAutofocusStarted()
      ..toggleMinimized();
    await tester.pump();
    expect(
      tester.binding.transientCallbackCount,
      greaterThan(0),
      reason: 'The overlay must still pulse during a live autofocus run — '
          'gating the animation on real state must not remove the animation.',
    );

    overlay.dismiss();
    await _expectIdlesAtRest(
      tester,
      'an AutofocusProgressOverlay after the run ended',
    );
  });
}

/// Fails unless the tree has genuinely come to rest — nothing is animating and
/// nothing has asked for another frame.
Future<void> _expectIdlesAtRest(WidgetTester tester, String what) async {
  const explanation =
      'This means a widget is animating at rest. A running Ticker schedules a '
      'frame on every vsync, so the app never idles and EVERY screen renders '
      'at a degraded framerate — find the running Ticker and gate it on real '
      'state (see OnScreenAnimationGate in skotiq_ui).';

  try {
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 20),
    );
  } on FlutterError {
    fail('$what never stopped scheduling frames. $explanation');
  }

  expect(
    tester.binding.transientCallbackCount,
    0,
    reason: '$what left a frame callback registered after settling. '
        '$explanation',
  );
  expect(
    tester.binding.hasScheduledFrame,
    isFalse,
    reason: '$what still has a frame scheduled after settling. $explanation',
  );
}
