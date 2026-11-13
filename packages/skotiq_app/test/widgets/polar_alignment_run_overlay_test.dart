// A polar alignment run shows on every screen, however it was started.
//
// 2026-11-07 on the rig: runs started through the API showed on the host as
// lines in the log and nothing else, because the frame, the step and the
// error lived on the polar alignment screen alone.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/widgets/polar_alignment_run_overlay.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../harness/pump_app_screen.dart';
import 'package:skotiq_app/router/app_routes.dart';

class _Fixed extends PolarAlignmentStateNotifier {
  _Fixed(super.ref, PolarAlignmentState fixed) {
    // ignore: invalid_use_of_protected_member
    state = fixed;
  }
}

Future<void> _pump(WidgetTester tester, PolarAlignmentState state) async {
  final router = GoRouter(
    initialLocation: '/tonight',
    routes: [
      GoRoute(
        path: '/tonight',
        builder: (_, __) => const Scaffold(
          body: Stack(children: [PolarAlignmentRunOverlay()]),
        ),
      ),
      GoRoute(
        path: AppRoute.polarAlignment.path,
        builder: (_, __) => const Scaffold(body: Text('alignment screen')),
      ),
    ],
  );
  await pumpAppScreen(
    tester,
    MaterialApp.router(theme: SkotiqTheme.dark, routerConfig: router),
    size: const Size(1200, 800),
    settle: false,
    extraOverrides: [
      polarAlignmentStateProvider.overrideWith((ref) => _Fixed(ref, state)),
    ],
  );
  await tester.pump(const Duration(milliseconds: 200));
}

PolarAlignmentError _e(double az, double alt) => PolarAlignmentError(
      azimuthError: az,
      altitudeError: alt,
      totalError: Offset(az, alt).distance,
      currentRa: 0,
      currentDec: 60,
      targetRa: 0,
      targetDec: 90,
      timestamp: DateTime(2026, 11, 7, 20, 30),
    );

void main() {
  testWidgets('a measuring run shows its step and opens the alignment',
      (tester) async {
    await _pump(
      tester,
      const PolarAlignmentState(
        phase: PolarAlignPhase.measuring,
        currentPoint: 1,
        statusMessage: 'Plate solving point 1/3...',
      ),
    );
    expect(find.text('Polar alignment'), findsOneWidget);
    expect(find.text('Plate solving point 1 of 3'), findsOneWidget);
    expect(find.text('Waiting for the first frame'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);

    await tester.tap(find.text('Open alignment'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('alignment screen'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an adjusting run says which way to turn the bolts',
      (tester) async {
    await _pump(
      tester,
      PolarAlignmentState(
        phase: PolarAlignPhase.adjusting,
        currentError: _e(1337, 1759),
      ),
    );
    expect(find.text("Adjusting · 36' 49\" off"), findsOneWidget);
    expect(
      find.text("Azimuth Left 22' 17\" · Altitude Down 29' 19\""),
      findsOneWidget,
    );
  });

  testWidgets('nothing shows without a live run', (tester) async {
    for (final phase in [
      PolarAlignPhase.idle,
      PolarAlignPhase.complete,
      PolarAlignPhase.error,
    ]) {
      await _pump(tester, PolarAlignmentState(phase: phase));
      expect(find.text('Polar alignment'), findsNothing, reason: '$phase');
    }
  });
}
