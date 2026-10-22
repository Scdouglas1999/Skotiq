// The Conditions block names what decides the weather verdict, reports what
// the run's own frames say, and offers "the sky is clear" when a forecast or a
// weather device holds or warns.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/session/conditions_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/night_control/panel/overview/overview_sections.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'panel_test_support.dart';

const _utc = FixedOffsetClock(utcOffset: Duration.zero, label: 'UTC');

void main() {
  group('nightSafetyNotes', () {
    test('a forecast that holds says so and offers the override', () {
      final result = nightSafetyNotes(
        const NightSafetyReading(
          monitoring: true,
          safe: false,
          decidedBy: WeatherDecisionSource.forecast,
          forecastHoldsRun: true,
        ),
        _utc,
      );
      expect(result.notes.first.key, 'nightWeatherForecastHolds');
      expect(result.skyOverride, NightSkyOverride.offer);
    });

    test('a safety monitor is not set aside from Tonight', () {
      final result = nightSafetyNotes(
        const NightSafetyReading(
          monitoring: true,
          safe: false,
          decidedBy: WeatherDecisionSource.safetyMonitor,
        ),
        _utc,
      );
      expect(result.notes.single.key, 'nightWeatherDecidedByMonitor');
      expect(result.skyOverride, NightSkyOverride.none);
    });

    test('star evidence and an active override are reported', () {
      final result = nightSafetyNotes(
        NightSafetyReading(
          monitoring: true,
          overrideUntil: DateTime.utc(2026, 10, 21, 23, 30),
          starEvidence: SkyStarEvidence(
            latestStars: 412,
            typicalStars: 450,
            latestAt: DateTime.utc(2026, 10, 21, 23),
            clear: true,
          ),
        ),
        _utc,
      );
      expect(result.notes.map((n) => n.key), [
        'nightWeatherStarsClear',
        'nightWeatherOverrideActive',
      ]);
      expect(result.notes.first.params, {'stars': '412', 'usual': '450'});
      expect(result.notes.last.params, {'time': '23:30'});
      expect(result.skyOverride, NightSkyOverride.active);
    });
  });

  testWidgets('the override button sets the verdict aside', (tester) async {
    var pressed = 0;
    await pumpPanel(
      tester,
      overrides: const [],
      child: NightConditionsSection(
        conditions: const NightConditionsVm(
          source: ConditionsSource.forecast,
          safe: false,
          notes: <NightText>[NightText('nightWeatherForecastHolds')],
          skyOverride: NightSkyOverride.offer,
        ),
        onSkyClear: () => pressed++,
        onEndOverride: () {},
      ),
    );

    expect(find.textContaining('Decided by the internet forecast'),
        findsOneWidget);
    await tester.tap(find.text('Sky is clear, resume'));
    await tester.pump();
    expect(pressed, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an active override can be ended', (tester) async {
    var ended = 0;
    await pumpPanel(
      tester,
      overrides: const [],
      child: NightConditionsSection(
        conditions: const NightConditionsVm(
          source: ConditionsSource.forecast,
          skyOverride: NightSkyOverride.active,
        ),
        onSkyClear: () {},
        onEndOverride: () => ended++,
      ),
    );

    expect(find.text('Sky is clear, resume'), findsNothing);
    await tester.tap(find.text('Use the weather verdict again'));
    await tester.pump();
    expect(ended, 1);
  });
}
