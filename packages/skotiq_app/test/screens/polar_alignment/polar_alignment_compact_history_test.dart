// The History toggle on a PHONE-width polar alignment screen.
//
// On the compact layout the configuration column is a tab, so the header's
// History toggle has to select that tab as well as scroll to the panel — the
// panel is not merely below the fold there, it is on a page the operator is not
// looking at. That makes the screen the first thing outside `_CompactTabLayout`
// to move the tab index, and moving it from a Riverpod listener drives
// `TabController.index =` inside build — whose synchronous listener callback
// would otherwise write the same index straight back into the provider
// mid-build.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/polar_alignment/polar_alignment_screen.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

GoRouter? _activeRouter;

GoRouter _router() => GoRouter(
      initialLocation: '/imaging',
      routes: [
        GoRoute(
          path: '/imaging',
          builder: (_, __) => const Scaffold(body: SizedBox()),
        ),
        GoRoute(
          path: '/polar-alignment',
          builder: (_, __) => const PolarAlignmentScreen(),
        ),
      ],
    );

Future<void> _openWizard(WidgetTester tester) async {
  // The push future completes when the route is POPPED, so it is deliberately
  // not awaited here.
  unawaited(_activeRouter!.push('/polar-alignment'));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _settle(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('History reaches its panel on a phone-width wizard',
      (tester) async {
    final router = _router();
    _activeRouter = router;
    addTearDown(() => _activeRouter = null);

    // Below PolarAlignmentBodyLayout.compactBreakpoint (700) => tabbed layout.
    await pumpAppScreen(
      tester,
      MaterialApp.router(theme: SkotiqTheme.dark, routerConfig: router),
      size: const Size(430, 932),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 200));
    await _openWizard(tester);

    // The operator is reading the Errors tab when they reach for History.
    await tester.tap(find.text('Errors'));
    await _settle(tester);
    expect(find.text('Alignment history'), findsNothing);

    // On a phone the header's History control is an icon button — the label
    // does not fit beside the title and the primary — so it is found by the
    // tooltip that names it.
    await tester.tap(find.byTooltip('Show past alignment runs'));
    await _settle(tester);

    // No "Tried to modify a provider while the widget tree was building":
    // selecting the Settings tab from the toggle must not re-enter the
    // provider through the TabController's own listener.
    expect(tester.takeException(), isNull);

    final panel = find.text('Alignment history');
    expect(
      panel,
      findsOneWidget,
      reason: 'the toggle has to switch to the tab the panel lives on, or the '
          'History button does nothing at all on a phone',
    );
    final rect = tester.getRect(panel);
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(
      rect.top >= 0 && rect.bottom <= screen.height,
      isTrue,
      reason: 'History must land inside the viewport (panel at $rect, '
          'viewport height ${screen.height})',
    );
  });
}
