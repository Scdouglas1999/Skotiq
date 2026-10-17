// Responsive widget tests for DiagnosticsScreen.
//
// Verifies the optical-train diagnostics surface lays out without RenderFlex
// overflow at the three reference phone sizes in BOTH orientations (per the
// mobile responsive standard). The prior diagnostics test had to *swallow*
// known header-row overflows at narrow widths; after the header reflow (title
// flexes, session selector drops to its own line / constrained + isExpanded
// dropdown) those overflows are gone, so these tests assert no overflow at all.
//
// The empty (no-session) state is the verifiable surface under the harness:
// it exercises the header (title + session selector) and the gating
// EmptyState — the parts that were overflowing — without pulling the heavy
// per-session optical-train provider chain.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_app/screens/diagnostics/diagnostics_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

List<Override> _overrides() => [
      allSessionsProvider.overrideWith(
        (ref) => Stream<List<ImagingSession>>.value(const []),
      ),
    ];

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

const _phonePortraitSizes = <Size>[
  Size(360, 640),
  Size(390, 844),
  Size(430, 932),
];

Future<void> _pumpAndCheck(WidgetTester tester, Size size) async {
  await pumpAppScreen(
    tester,
    const DiagnosticsScreen(),
    size: size,
    settle: false,
    extraOverrides: _overrides(),
  );
  await _drain(tester);

  expect(
    tester.takeException(),
    isNull,
    reason: 'DiagnosticsScreen must not overflow at '
        '${size.width}x${size.height}',
  );
  expect(find.text('Optical train diagnostics'), findsOneWidget,
      reason: 'Diagnostics header title must render at '
          '${size.width}x${size.height}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final size in _phonePortraitSizes) {
    testWidgets(
      'DiagnosticsScreen lays out without overflow at '
      '${size.width.toInt()}x${size.height.toInt()} (portrait)',
      (tester) async {
        await _pumpAndCheck(tester, size);
      },
    );

    final landscape = Size(size.height, size.width);
    testWidgets(
      'DiagnosticsScreen lays out without overflow at '
      '${landscape.width.toInt()}x${landscape.height.toInt()} (landscape)',
      (tester) async {
        await _pumpAndCheck(tester, landscape);
      },
    );
  }
}
