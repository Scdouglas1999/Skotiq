import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/polar_alignment/polar_alignment_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/pump_app_screen.dart';

class _Fixed extends PolarAlignmentStateNotifier {
  _Fixed(super.ref, PolarAlignmentState fixed) {
    // ignore: invalid_use_of_protected_member
    state = fixed;
  }
}

PolarAlignmentError _e(double az, double alt, double total) =>
    PolarAlignmentError(
      azimuthError: az,
      altitudeError: alt,
      totalError: total,
      currentRa: 0,
      currentDec: 89,
      targetRa: 0,
      targetDec: 90,
      timestamp: DateTime(2026, 8, 2, 10, 30),
    );

void main() {
  for (final size in const [
    Size(360, 640),
    Size(390, 844),
    Size(430, 932),
    Size(640, 360),
    Size(932, 430),
    Size(1400, 900),
    Size(800, 500),
  ]) {
    testWidgets('large polar errors fit at $size', (tester) async {
      final router = GoRouter(
        initialLocation: '/polar-alignment',
        routes: [
          GoRoute(
              path: '/polar-alignment',
              builder: (_, __) => const PolarAlignmentScreen()),
        ],
      );
      await pumpAppScreen(
        tester,
        MaterialApp.router(theme: SkotiqTheme.dark, routerConfig: router),
        size: size,
        settle: false,
        extraOverrides: [
          polarAlignmentStateProvider.overrideWith((ref) => _Fixed(
              ref,
              PolarAlignmentState(
                phase: PolarAlignPhase.adjusting,
                config: const PolarAlignmentConfig(autoCompleteThreshold: 30),
                startedAt: DateTime(2026, 8, 2, 10),
                initialError: _e(-40104, 32000, 51300),
                currentError: _e(-40104, 32000, 51300),
              ))),
        ],
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
    });
  }
}
