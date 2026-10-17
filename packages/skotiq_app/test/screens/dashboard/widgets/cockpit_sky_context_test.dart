import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/cockpit_sky_context.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart'
    as planetarium;
import 'package:skotiq_ui/skotiq_ui.dart';

TargetHeaderNode _target() => TargetHeaderNode(
      targetName: 'M31',
      raHours: 0.71,
      decDegrees: 41.27,
    );

final _now = DateTime(2026, 6, 10, 23, 0);

/// A twilight window with dusk before [_now] and dawn ~4h after, so the
/// "astro dark left" readout is non-empty.
final _twilight = planetarium.TwilightTimes(
  astronomicalDusk: DateTime(2026, 6, 10, 22, 30),
  astronomicalDawn: DateTime(2026, 6, 11, 3, 0),
);

const _moon =
    planetarium.MoonTimes(illumination: 42, phaseName: 'Waxing Gibbous');

Widget _wrap(List<Override> overrides) {
  return ProviderScope(
    overrides: [
      // These cases are all "a site IS configured". The no-site behaviour lives
      // in test/screens/observing_site_gating_test.dart.
      appObserverLocationProvider.overrideWithValue(
        const LocationSettings(latitude: 40.71, longitude: -74.01),
      ),
      planetarium.twilightTimesProvider.overrideWithValue(_twilight),
      planetarium.moonInfoProvider.overrideWithValue(_moon),
      planetarium.observationTimeProvider.overrideWith(
        (ref) => planetarium.ObservationTimeNotifier()..setTime(_now),
      ),
      ...overrides,
    ],
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: const Scaffold(body: CockpitSkyContext()),
    ),
  );
}

void main() {
  testWidgets('idle (no target) renders the slim darkness + moon summary',
      (tester) async {
    await tester.pumpWidget(_wrap([
      runDashboardActiveTargetProvider.overrideWithValue(null),
    ]));
    await tester.pump();

    // Idle row mentions the moon illumination and astro-dark window.
    expect(find.textContaining('No target'), findsOneWidget);
    expect(find.textContaining('Moon 42%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('active target renders altitude, airmass, moon, and dark-left',
      (tester) async {
    const sky = RunDashboardSkyStats(
      altitudeDeg: 60.0,
      azimuthDeg: 180.0,
      timeToSet: Duration(hours: 3),
      timeToTransit: Duration(minutes: 20),
      horizonDeg: 20.0,
    );

    await tester.pumpWidget(_wrap([
      runDashboardActiveTargetProvider.overrideWithValue(_target()),
      runDashboardSkyStatsProvider.overrideWithValue(sky),
    ]));
    await tester.pump();

    expect(find.text('SKY CONTEXT'), findsOneWidget);
    // Altitude readout (color-graded), success for 60° above a 20° horizon.
    final alt = tester.widget<Text>(find.text('60.0°'));
    expect(alt.style!.color, SkotiqColors.dark.success);
    // Azimuth.
    expect(find.text('180°'), findsOneWidget);
    // Airmass ≈ 1/cos(30°) = 1.15.
    expect(find.text('1.15'), findsOneWidget);
    // Moon illumination + phase label present.
    expect(find.text('42%'), findsOneWidget);
    expect(find.text('Waxing Gibbous'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
