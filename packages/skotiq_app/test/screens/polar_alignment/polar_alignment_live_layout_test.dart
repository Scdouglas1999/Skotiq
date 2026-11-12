// A run in progress is the frame.
//
// Owner, 2026-11-07: "The actual image is a tiny box and the useless or
// relatively useless bullseye is huge." On a 1600x900 window the frame was
// about 370 px wide between the locked settings column and a 440 px bullseye
// column. These pin the frame as the main element, the bullseye as a compact
// readout, and both on screen at small windows.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/polar_alignment/polar_alignment_body_layout.dart';
import 'package:skotiq_app/screens/polar_alignment/polar_alignment_screen.dart';
import 'package:skotiq_app/tours/tour_target.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

class _Fixed extends PolarAlignmentStateNotifier {
  _Fixed(super.ref, PolarAlignmentState fixed) {
    // ignore: invalid_use_of_protected_member
    state = fixed;
  }
}

PolarAlignmentError _e(double az, double alt) => PolarAlignmentError(
      azimuthError: az,
      altitudeError: alt,
      totalError: Offset(az, alt).distance,
      currentRa: 0,
      currentDec: 89,
      targetRa: 0,
      targetDec: 90,
      timestamp: DateTime(2026, 11, 7, 20, 30),
    );

PolarAlignmentState _adjusting() => PolarAlignmentState(
      phase: PolarAlignPhase.adjusting,
      config: const PolarAlignmentConfig(autoCompleteThreshold: 30),
      startedAt: DateTime(2026, 11, 7, 20),
      initialError: _e(1337, 1759),
      currentError: _e(1337, 1759),
    );

PolarAlignmentState _measuring() => PolarAlignmentState(
      phase: PolarAlignPhase.measuring,
      config: const PolarAlignmentConfig(),
      startedAt: DateTime(2026, 11, 7, 20),
      currentPoint: 1,
      statusMessage: 'Plate solving point 1/3...',
    );

Future<void> _pump(
  WidgetTester tester,
  Size size,
  PolarAlignmentState state,
) async {
  final router = GoRouter(
    initialLocation: '/polar-alignment',
    routes: [
      GoRoute(
        path: '/polar-alignment',
        builder: (_, __) => const PolarAlignmentScreen(),
      ),
    ],
  );
  await pumpAppScreen(
    tester,
    MaterialApp.router(theme: SkotiqTheme.dark, routerConfig: router),
    size: size,
    settle: false,
    extraOverrides: [
      polarAlignmentStateProvider.overrideWith((ref) => _Fixed(ref, state)),
    ],
  );
  await tester.pump(const Duration(milliseconds: 300));
}

Rect _bullseye(WidgetTester tester) => tester.getRect(
      find.byWidgetPredicate(
        (w) =>
            w is CustomPaint &&
            w.painter.runtimeType.toString() == '_PolarErrorPainter',
      ),
    );

void main() {
  for (final state in [_measuring(), _adjusting()]) {
    testWidgets(
        'on the owner\'s 1600x900 window the frame is the screen '
        '(${state.phase.name})', (tester) async {
      // The screen's share of a 1600x900 window with the rail open.
      const size = Size(1544, 840);
      await _pump(tester, size, state);
      expect(tester.takeException(), isNull);

      final frame =
          tester.getRect(find.byKey(TourTarget.polarImageView.key));
      expect(frame.width, greaterThan(size.width * 0.7),
          reason: 'the live frame takes most of the width');
      expect(frame.height, greaterThan(size.height * 0.6));
      expect(_bullseye(tester).height, lessThanOrEqualTo(200),
          reason: 'the bullseye is a compact readout, not the main element');
      expect(find.text('Essential'), findsNothing,
          reason: 'the locked settings stay out of the way mid-run');
      expect(find.text('TOTAL'), findsOneWidget);
    });
  }

  for (final size in const [
    Size(360, 640),
    Size(640, 360),
    Size(800, 500),
    Size(1024, 700),
    Size(1308, 774),
  ]) {
    testWidgets('frame and readout both fit at $size', (tester) async {
      await _pump(tester, size, _adjusting());
      expect(tester.takeException(), isNull);
      final frame =
          tester.getRect(find.byKey(TourTarget.polarImageView.key));
      expect(frame.width, greaterThan(size.width * 0.45));
      expect(frame.height, greaterThan(100));
      expect(frame.bottom, lessThanOrEqualTo(size.height));
      expect(find.text('Adjust mount'), findsOneWidget);
    });
  }

  test('the readout column goes under the frame only when that is larger', () {
    expect(PolarAlignmentLiveLayout.besideShowsFrameLarger(1544, 760), isTrue);
    expect(PolarAlignmentLiveLayout.besideShowsFrameLarger(640, 280), isTrue,
        reason: 'a landscape phone keeps the frame full height');
    expect(PolarAlignmentLiveLayout.besideShowsFrameLarger(360, 560), isFalse);
    expect(PolarAlignmentLiveLayout.besideShowsFrameLarger(700, 1000), isFalse,
        reason: 'a portrait tablet shows a landscape frame wider stacked');
  });
}
