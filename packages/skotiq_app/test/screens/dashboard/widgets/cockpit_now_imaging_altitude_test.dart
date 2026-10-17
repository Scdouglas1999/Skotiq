import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/cockpit_now_imaging.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

TargetHeaderNode _target() => TargetHeaderNode(
      targetName: 'M31',
      raHours: 0.71,
      decDegrees: 41.27,
    );

Widget _wrap(List<Override> overrides) {
  return ProviderScope(
    overrides: [...overrides],
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: const Scaffold(body: CockpitNowImaging()),
    ),
  );
}

Color _altColorFor(WidgetTester tester, String text) {
  final widget = tester.widget<Text>(find.text(text));
  return widget.style!.color!;
}

void main() {
  const colors = SkotiqColors.dark;

  testWidgets('altitude below the effective horizon grades error',
      (tester) async {
    const sky = RunDashboardSkyStats(
      altitudeDeg: 18.0,
      azimuthDeg: 90.0,
      timeToSet: Duration(hours: 1),
      timeToTransit: Duration(hours: 2),
      horizonDeg: 20.0,
    );
    await tester.pumpWidget(_wrap([
      runDashboardActiveTargetProvider.overrideWithValue(_target()),
      runDashboardSkyStatsProvider.overrideWithValue(sky),
    ]));
    await tester.pump();

    expect(_altColorFor(tester, '18.0°'), colors.error);
  });

  testWidgets('altitude just above a raised horizon grades warning',
      (tester) async {
    // Horizon 20°, margin = min((90-20)*0.25, 15) = 15 → 20..35 is warning.
    const sky = RunDashboardSkyStats(
      altitudeDeg: 28.0,
      azimuthDeg: 90.0,
      timeToSet: Duration(hours: 1),
      timeToTransit: Duration(hours: 2),
      horizonDeg: 20.0,
    );
    await tester.pumpWidget(_wrap([
      runDashboardActiveTargetProvider.overrideWithValue(_target()),
      runDashboardSkyStatsProvider.overrideWithValue(sky),
    ]));
    await tester.pump();

    expect(_altColorFor(tester, '28.0°'), colors.warning);
  });

  testWidgets('altitude comfortably above horizon grades success',
      (tester) async {
    const sky = RunDashboardSkyStats(
      altitudeDeg: 62.0,
      azimuthDeg: 180.0,
      timeToSet: Duration(hours: 3),
      timeToTransit: Duration(minutes: 10),
      horizonDeg: 20.0,
    );
    await tester.pumpWidget(_wrap([
      runDashboardActiveTargetProvider.overrideWithValue(_target()),
      runDashboardSkyStatsProvider.overrideWithValue(sky),
    ]));
    await tester.pump();

    expect(_altColorFor(tester, '62.0°'), colors.success);
  });

  testWidgets(
      'with a 0° horizon a 25° target is still warning (low), not error',
      (tester) async {
    // With horizon 0 the margin is min(90*0.25,15)=15 → 0..15 warning, 15+
    // success. 25° grading success proves the grade follows the horizon rather
    // than a fixed 30° threshold.
    const sky = RunDashboardSkyStats(
      altitudeDeg: 25.0,
      azimuthDeg: 100.0,
      timeToSet: Duration(hours: 5),
      timeToTransit: Duration(hours: 1),
      horizonDeg: 0.0,
    );
    await tester.pumpWidget(_wrap([
      runDashboardActiveTargetProvider.overrideWithValue(_target()),
      runDashboardSkyStatsProvider.overrideWithValue(sky),
    ]));
    await tester.pump();

    expect(_altColorFor(tester, '25.0°'), colors.success);
  });
}
