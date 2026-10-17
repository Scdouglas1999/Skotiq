import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/adaptive_conditions_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _wrap(Widget child, {required List<Override> overrides}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets('adaptive conditions panel renders executor snapshot fields',
      (tester) async {
    final now = DateTime.now().toUtc();
    final snapshot = AdaptiveSwapSnapshot(
      score: ConditionsScore(
        score: 64,
        transparencyScore: 72,
        seeingScore: 55,
        cloudScore: 90,
        windScore: null,
        generatedAt: now.subtract(const Duration(seconds: 45)),
      ),
      state: AdaptiveSwapRuntimeState(
        currentTargetId: 'm42',
        currentTier: 'medium',
        lastDecisionKind: 'hold_current',
        lastDecisionReason:
            'Current target remains above the medium floor with hysteresis active.',
        lastSwapAt: now.subtract(const Duration(seconds: 60)),
        lastSwapFromTargetId: 'm31',
        lastSwapToTargetId: 'm42',
        configuredThreshold: 50,
        configuredHysteresisSecs: 180,
      ),
    );

    await tester.pumpWidget(_wrap(
      const RunDashboardAdaptiveConditionsPanel(),
      overrides: [
        adaptiveSwapSnapshotProvider.overrideWith((ref) async => snapshot),
      ],
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('ADAPTIVE CONDITIONS'), findsOneWidget);
    expect(find.text('64'), findsOneWidget);
    expect(find.text('Degraded'), findsOneWidget);
    expect(find.text('Medium >= 50'), findsOneWidget);
    expect(find.text('Hold Current'), findsOneWidget);
    expect(
      find.text(
        'Current target remains above the medium floor with hysteresis active.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('m31 -> m42'), findsOneWidget);
    expect(find.textContaining('remaining'), findsOneWidget);
    expect(find.textContaining('s old'), findsOneWidget);
  });
}
