// No surface may state a site-derived fact when no observing site is on record.
//
// The planetarium astronomy providers cannot answer "I don't know" — they take
// a latitude and a longitude, and with none configured they are handed 0°N 0°E
// and return a complete, plausible night for the Gulf of Guinea. Consumed
// ungated, the cockpit sky panel, the command-bar night chip, the standby night
// timeline and the planetarium Tonight tab all report that night as the user's.
//
// All four route through `siteTwilightTimesProvider` / `siteMoonTimesProvider`,
// which are `null` when there is no site. These tests pump the real production
// widgets so removing a gate from a widget's build fails here — a test that only
// exercised the providers would survive it.
//
// The twilight fixture is deliberately fully populated: that is exactly what
// the calculator hands back for 0/0, so "no fields are null" must not be enough
// to make a surface talk.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/cockpit_sky_context.dart';
import 'package:skotiq_app/screens/dashboard/widgets/standby/night_timeline.dart';
import 'package:skotiq_app/screens/planetarium/widgets/tonight_tab.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import 'package:skotiq_app/services/observing_site.dart';
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// 22:00 on the fixture night — inside the dark window below.
final _now = DateTime(2026, 7, 25, 22, 0);

/// A fully populated night, of the shape `calculateTwilightTimes` returns for
/// 0°N 0°E: dusk 19:26, dawn 04:54 the next morning, a 9h 28m window.
final _nullIslandNight = TwilightTimes(
  sunset: DateTime(2026, 7, 25, 18, 10),
  civilDusk: DateTime(2026, 7, 25, 18, 33),
  nauticalDusk: DateTime(2026, 7, 25, 19, 0),
  astronomicalDusk: DateTime(2026, 7, 25, 19, 26),
  astronomicalDawn: DateTime(2026, 7, 26, 4, 54),
  nauticalDawn: DateTime(2026, 7, 26, 5, 20),
  civilDawn: DateTime(2026, 7, 26, 5, 47),
  sunrise: DateTime(2026, 7, 26, 6, 10),
);

const _moon = MoonTimes(
  illumination: 42,
  phaseName: 'Waxing Gibbous',
);

final _moonWithTimes = MoonTimes(
  moonrise: DateTime(2026, 7, 25, 10, 53),
  moonset: DateTime(2026, 7, 25, 23, 24),
  illumination: 42,
  phaseName: 'Waxing Gibbous',
);

const _realSite = LocationSettings(
  latitude: 40.71,
  longitude: -74.01,
  elevation: 10,
);

List<Override> _overrides({
  required LocationSettings? site,
  MoonTimes moon = _moon,
}) =>
    [
      appObserverLocationProvider.overrideWithValue(site),
      twilightTimesProvider.overrideWithValue(_nullIslandNight),
      moonInfoProvider.overrideWithValue(moon),
      observationTimeProvider.overrideWith(
        (ref) => ObservationTimeNotifier()..setTime(_now),
      ),
    ];

Future<void> _pump(
  WidgetTester tester, {
  required Widget child,
  required LocationSettings? site,
  MoonTimes moon = _moon,
  List<Override> extra = const [],
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1200, 900);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        inMemoryDatabaseOverride(),
        ..._overrides(site: site, moon: moon),
        ...extra
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('siteTwilightTimesProvider', () {
    test('is absent with no site and passes the night through with one', () {
      final without = ProviderContainer(overrides: _overrides(site: null));
      addTearDown(without.dispose);
      expect(without.read(siteTwilightTimesProvider), isNull);
      expect(without.read(siteMoonTimesProvider), isNull);

      final with_ = ProviderContainer(
        overrides: _overrides(site: _realSite, moon: _moonWithTimes),
      );
      addTearDown(with_.dispose);
      expect(with_.read(siteTwilightTimesProvider), same(_nullIslandNight));
      expect(with_.read(siteMoonTimesProvider), same(_moonWithTimes));
    });
  });

  group('NightTimeline', () {
    testWidgets('says nothing about the night when no site is on record',
        (tester) async {
      await _pump(
        tester,
        site: null,
        child: Builder(
          builder: (context) =>
              NightTimeline(colors: SkotiqColors.of(context)),
        ),
      );

      expect(find.text('Set an observing location for twilight times.'),
          findsOneWidget);
      expect(find.text('IMAGING WINDOW'), findsNothing);
      // "9h 28m" is the Null Island imaging window the audit caught on screen.
      expect(find.textContaining('9h 28m'), findsNothing);
    });

    testWidgets('renders the countdown and window for a real site',
        (tester) async {
      await _pump(
        tester,
        site: _realSite,
        child: Builder(
          builder: (context) =>
              NightTimeline(colors: SkotiqColors.of(context)),
        ),
      );

      expect(find.text('Set an observing location for twilight times.'),
          findsNothing);
      expect(find.text('IMAGING WINDOW'), findsOneWidget);
      expect(find.text('9h 28m'), findsOneWidget);
    });
  });

  group('CockpitSkyContext', () {
    testWidgets('idle asks for a location instead of naming a dark window',
        (tester) async {
      await _pump(
        tester,
        site: null,
        child: const CockpitSkyContext(),
        extra: [runDashboardActiveTargetProvider.overrideWithValue(null)],
      );

      expect(find.textContaining('set an observing location'), findsOneWidget);
      expect(find.textContaining('19:26'), findsNothing);
      // The moon phase is the same everywhere on Earth, so it survives.
      expect(find.textContaining('Moon 42%'), findsOneWidget);
    });

    testWidgets('idle names the dark window for a real site', (tester) async {
      await _pump(
        tester,
        site: _realSite,
        child: const CockpitSkyContext(),
        extra: [runDashboardActiveTargetProvider.overrideWithValue(null)],
      );

      expect(find.textContaining('astro dark 19:26'), findsOneWidget);
    });

    testWidgets('with a target, "astro dark left" is blank without a site',
        (tester) async {
      await _pump(
        tester,
        site: null,
        child: const CockpitSkyContext(),
        extra: [
          runDashboardActiveTargetProvider.overrideWithValue(
            TargetHeaderNode(
                targetName: 'M31', raHours: 0.71, decDegrees: 41.2),
          ),
        ],
      );

      expect(find.text('Astro dark left'), findsOneWidget);
      expect(find.text('—'), findsWidgets);
      // 6h 54m is dawn-minus-now for the fabricated observer.
      expect(find.text('6h 54m'), findsNothing);
    });

    testWidgets('with a target and a site, "astro dark left" counts down',
        (tester) async {
      await _pump(
        tester,
        site: _realSite,
        child: const CockpitSkyContext(),
        extra: [
          runDashboardActiveTargetProvider.overrideWithValue(
            TargetHeaderNode(
                targetName: 'M31', raHours: 0.71, decDegrees: 41.2),
          ),
        ],
      );

      expect(find.text('6h 54m'), findsOneWidget);
    });
  });

  group('TonightTab', () {
    testWidgets('prompts for a location instead of a Null Island night',
        (tester) async {
      await _pump(
        tester,
        site: null,
        moon: _moonWithTimes,
        child: Builder(
          builder: (context) =>
              TonightTab(colors: SkotiqColors.of(context)),
        ),
        extra: [bestTargetsProvider.overrideWith((ref) async => [])],
      );

      expect(find.text('No observing location set'), findsOneWidget);
      expect(find.textContaining('Set an observing location to see'),
          findsOneWidget);
      // Twilight, darkness window and moon rise/set are all site-derived.
      expect(find.text('Evening twilight'), findsNothing);
      expect(find.text('Morning twilight'), findsNothing);
      expect(find.text('19:26'), findsNothing);
      expect(find.text('23:24'), findsNothing);
      // The coordinates of the fabricated site must not be printed either.
      expect(find.textContaining('0.00°N'), findsNothing);
      // Phase and illumination are global facts and stay.
      expect(find.text('Waxing Gibbous'), findsOneWidget);
      expect(find.text('42%'), findsOneWidget);
    });

    testWidgets('shows the full night for a real site', (tester) async {
      await _pump(
        tester,
        site: _realSite,
        moon: _moonWithTimes,
        child: Builder(
          builder: (context) =>
              TonightTab(colors: SkotiqColors.of(context)),
        ),
        extra: [bestTargetsProvider.overrideWith((ref) async => [])],
      );

      expect(find.text('Evening twilight'), findsOneWidget);
      expect(find.text('Morning twilight'), findsOneWidget);
      expect(find.text('19:26'), findsOneWidget);
      expect(find.text('23:24'), findsOneWidget);
      expect(find.text('40.71°N, 74.01°W'), findsOneWidget);
    });
  });
}
