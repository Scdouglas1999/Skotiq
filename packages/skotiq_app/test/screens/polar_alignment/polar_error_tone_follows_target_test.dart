import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/polar_alignment/polar_alignment_screen.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
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

Future<Readout> _totalReadout(
  WidgetTester tester, {
  required double thresholdArcsec,
  required PolarAlignmentError error,
}) async {
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
    size: const Size(1400, 900),
    settle: false,
    extraOverrides: [
      polarAlignmentStateProvider.overrideWith((ref) => _Fixed(
            ref,
            PolarAlignmentState(
              phase: PolarAlignPhase.adjusting,
              config:
                  PolarAlignmentConfig(autoCompleteThreshold: thresholdArcsec),
              startedAt: DateTime(2026, 8, 2, 10),
              initialError: error,
              currentError: error,
            ),
          )),
    ],
  );
  await tester.pump(const Duration(milliseconds: 300));
  return tester.widget<Readout>(
    find.byKey(const ValueKey('polar-readout-total')),
  );
}

void main() {
  testWidgets('an error under the configured target reads on target',
      (tester) async {
    final readout = await _totalReadout(
      tester,
      thresholdArcsec: 120,
      error: _e(60, 66, 90),
    );
    final colors = SkotiqColors.of(
      tester.element(find.byKey(const ValueKey('polar-readout-total'))),
    );
    expect(readout.valueColor, colors.success);
  });

  testWidgets('an error between one and two targets reads close',
      (tester) async {
    final readout = await _totalReadout(
      tester,
      thresholdArcsec: 30,
      error: _e(30, 33, 45),
    );
    final colors = SkotiqColors.of(
      tester.element(find.byKey(const ValueKey('polar-readout-total'))),
    );
    expect(readout.valueColor, colors.warning);
  });
}
