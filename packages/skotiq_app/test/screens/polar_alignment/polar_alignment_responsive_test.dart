// Responsive widget tests for PolarAlignmentScreen.
//
// Verifies the polar-alignment wizard lays out without RenderFlex overflow at
// the three reference phone sizes in BOTH orientations (per the mobile
// responsive standard). At these widths the body collapses into the compact
// tab layout (Settings / Guide / Errors), the header reflows to two rows, and
// the footer stacks its actions under the status.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:skotiq_app/screens/polar_alignment/polar_alignment_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

GoRouter _router() {
  return GoRouter(
    initialLocation: '/polar-alignment',
    routes: [
      GoRoute(
        path: '/polar-alignment',
        builder: (_, __) => const PolarAlignmentScreen(),
      ),
      GoRoute(
        path: '/imaging',
        builder: (_, __) => const Scaffold(body: Text('imaging stub')),
      ),
    ],
  );
}

const _phonePortraitSizes = <Size>[
  Size(360, 640),
  Size(390, 844),
  Size(430, 932),
];

Future<void> _pumpAndCheck(WidgetTester tester, Size size) async {
  await pumpAppScreen(
    tester,
    MaterialApp.router(
      theme: SkotiqTheme.dark,
      routerConfig: _router(),
    ),
    size: size,
    settle: false,
    extraOverrides: [
      plateSolverDetectionProvider.overrideWith(
        (ref) async => const PlateSolverDetection(
          astapPath: r'C:\Program Files\astap\astap.exe',
          catalogPath: r'C:\Program Files\astap',
        ),
      ),
    ],
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }

  expect(
    tester.takeException(),
    isNull,
    reason: 'PolarAlignmentScreen must not overflow at '
        '${size.width}x${size.height}',
  );
  // The Guide tab's setup instructions carry the screen identity in the
  // compact layout.
  expect(find.text('Three-point polar alignment'), findsOneWidget,
      reason: 'Setup instructions must be present at '
          '${size.width}x${size.height}');
}

void main() {
  for (final size in _phonePortraitSizes) {
    testWidgets(
      'PolarAlignmentScreen lays out without overflow at '
      '${size.width.toInt()}x${size.height.toInt()} (portrait)',
      (tester) async {
        await _pumpAndCheck(tester, size);
      },
    );

    final landscape = Size(size.height, size.width);
    testWidgets(
      'PolarAlignmentScreen lays out without overflow at '
      '${landscape.width.toInt()}x${landscape.height.toInt()} (landscape)',
      (tester) async {
        await _pumpAndCheck(tester, landscape);
      },
    );
  }
}
