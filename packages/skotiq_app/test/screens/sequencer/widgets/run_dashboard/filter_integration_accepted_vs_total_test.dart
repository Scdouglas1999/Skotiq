import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/filter_integration_panel.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _wrap(Widget child, {required List<Override> overrides}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(body: SizedBox(width: 360, child: child)),
    ),
  );
}

void main() {
  testWidgets('shows rejected gap when total acquired exceeds accepted',
      (tester) async {
    const totals = RunDashboardFilterTotals(
      // 1h accepted of a 2h goal for L; 30m accepted for R.
      integrationSecs: {'L': 3600.0, 'R': 1800.0},
      // L acquired 1h30m total (30m rejected); R acquired exactly 30m (none).
      totalAcquiredSecs: {'L': 5400.0, 'R': 1800.0},
      goalSecs: {'L': 7200.0, 'R': 3600.0},
    );

    await tester.pumpWidget(_wrap(
      const RunDashboardFilterIntegration(),
      overrides: [
        runDashboardFilterTotalsProvider.overrideWithValue(totals),
      ],
    ));
    await tester.pump();

    expect(find.text('PER-FILTER INTEGRATION'), findsOneWidget);
    // The 30m rejected gap on L is surfaced; R (no gap) is not.
    expect(find.textContaining('rejected'), findsOneWidget);
  });

  testWidgets('no rejected line when every sub was accepted', (tester) async {
    const totals = RunDashboardFilterTotals(
      integrationSecs: {'L': 3600.0},
      totalAcquiredSecs: {'L': 3600.0},
      goalSecs: {'L': 7200.0},
    );

    await tester.pumpWidget(_wrap(
      const RunDashboardFilterIntegration(),
      overrides: [
        runDashboardFilterTotalsProvider.overrideWithValue(totals),
      ],
    ));
    await tester.pump();

    expect(find.textContaining('rejected'), findsNothing);
  });

  testWidgets('in-flight filter appears even with no acquired frames yet',
      (tester) async {
    const totals = RunDashboardFilterTotals(
      integrationSecs: {},
      totalAcquiredSecs: {},
      goalSecs: {'Ha': 18000.0},
      inFlightFilter: 'Ha',
      inFlightElapsedSecs: 42.0,
    );

    await tester.pumpWidget(_wrap(
      const RunDashboardFilterIntegration(),
      overrides: [
        runDashboardFilterTotalsProvider.overrideWithValue(totals),
      ],
    ));
    await tester.pump();

    // The Ha row renders (swatch label) because it's the in-flight filter,
    // even though nothing has been written to disk yet.
    expect(find.text('Ha'), findsOneWidget);
  });

  test('RunDashboardFilterTotals.rejectedSecsFor clamps at zero', () {
    const totals = RunDashboardFilterTotals(
      integrationSecs: {'L': 3600.0},
      totalAcquiredSecs: {'L': 3000.0}, // total < accepted (shouldn't happen)
      goalSecs: {'L': 7200.0},
    );
    expect(totals.rejectedSecsFor('L'), 0.0);
    expect(totals.rejectedSecsFor('missing'), 0.0);
  });
}
