// Plan > Best tonight reads the site clock, as the top bar and the Targets tab
// do: the Dark chip, the window header, each transit time and the altitude
// chart's clock scale.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/screens/night_control/center/chart_axes.dart';
import 'package:skotiq_app/screens/planner/planner_screen.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'scheduler_test_doubles.dart';

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(latitude: 40.0, longitude: -75.0);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Best tonight reads the site clock', (tester) async {
    // Seven hours off the device's own zone, so the two clocks cannot agree.
    final now = DateTime.now();
    final site = FixedOffsetClock(
      utcOffset: now.timeZoneOffset + const Duration(hours: 7),
      label: 'Site',
    );
    final night = AstronomyCalculations.nightAt(
      now: now,
      latitudeDeg: 40,
      longitudeDeg: -75,
    );
    final dusk = night.astronomicalDusk!;
    final dawn = night.astronomicalDawn!;
    final transit = dusk.add(const Duration(hours: 3, minutes: 17));
    final target = TargetSuggestion(
      targetId: 7,
      targetName: 'NGC 6015',
      raHours: 15.86,
      decDegrees: 62.3,
      totalScore: 76,
      visibility: TargetVisibilityInfo(
        currentAltitude: 55,
        currentAzimuth: 30,
        airmass: 1.2,
        moonDistance: 102,
        peakAltitude: 62,
        transitAltitude: 62,
        transitTime: transit,
        hoursAboveMinAlt: 5,
        aboveFloorFrom: dusk,
        aboveFloorUntil: dawn,
      ),
      objectType: 'Galaxy',
      magnitude: 11.2,
    );

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          clockProvider.overrideWithValue(site),
          tonightSuggestionsProvider.overrideWith((ref) async => [target]),
          smartNightExposureContextProvider.overrideWith((ref) async => null),
          appSettingsProvider.overrideWith(_StubAppSettingsNotifier.new),
          schedulerEngineProvider.overrideWithValue(buildTestSchedulerEngine()),
          schedulerStatusProvider.overrideWith(
            (ref) => FakeSchedulerStatusNotifier(
              const SchedulerStatus(state: SchedulerState.idle),
            ),
          ),
          currentSchedulerDecisionProvider.overrideWith(
            (ref) => FakeCurrentSchedulerDecisionNotifier(null),
          ),
          allIntegrationGoalsProvider
              .overrideWith((ref) async => <IntegrationGoal>[]),
          integrationGoalProgressProvider
              .overrideWith((ref, _) async => <IntegrationGoalProgress>[]),
          projectListProvider
              .overrideWith((ref) => Stream.value(const <Project>[])),
          activeProjectProgressProvider.overrideWith((ref) async => null),
          weekForecastProvider.overrideWith(
            (ref) async =>
                const WeekForecast.unavailable('Forecast off in tests.'),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
          supportedLocales: SkotiqLocalizations.supportedLocales,
          home: const Scaffold(body: PlannerScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.text('Dark ${site.hm(dusk)} – ${site.hm(dawn)}'),
      findsOneWidget,
      reason: 'the header chip',
    );
    expect(find.text(site.hm(dusk)), findsWidgets, reason: 'window header');
    expect(find.text(site.hm(dawn)), findsWidgets, reason: 'window header');
    expect(find.text('${site.hm(transit)} · 62°'), findsWidgets,
        reason: 'transit');

    // Every clock label under the altitude chart is a time the chart spans,
    // read on the site clock.
    final shown = <String>{};
    final from = dusk.subtract(const Duration(hours: 1));
    final to = dawn.add(const Duration(hours: 1));
    for (var t = from; !t.isAfter(to); t = t.add(const Duration(minutes: 1))) {
      shown.add(site.hm(t));
    }
    final labels = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(NightChartAxes),
            matching: find.byWidgetPredicate(
              (w) => w is Text && RegExp(r'^\d\d:\d\d$').hasMatch(w.data ?? ''),
            ),
          ),
        )
        .map((t) => t.data!)
        .toList();
    expect(labels, isNotEmpty);
    expect(labels.where((l) => !shown.contains(l)), isEmpty,
        reason: 'chart clock labels $labels');
  });
}
