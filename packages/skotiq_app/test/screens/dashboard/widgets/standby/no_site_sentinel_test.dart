// The dashboard must not present Null Island as the user's sky.
//
// lat/lon both 0.0 is the "no site on record" sentinel. The sun and moon really
// do rise and set at 0°N 0°E, so the astronomy providers return a complete,
// plausible set of times for a spot in the Gulf of Guinea. Every widget that
// states a location-derived time therefore has to check the sentinel ITSELF —
// a null-field check only catches polar day/night, so a first-run user with no
// location would read a stranger's sunset, astro-dark countdown and moonrise as
// their own.
//
// Phase and illumination are global, so those stay visible without a site.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/standby/moon_card.dart';
import 'package:skotiq_app/screens/dashboard/widgets/standby/night_timeline.dart';
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  final base = DateTime(2026, 7, 25);

  // A fully populated night — exactly what the calculator hands back for 0/0.
  final populatedNight = TwilightTimes(
    sunset: base.add(const Duration(hours: 18, minutes: 10)),
    civilDusk: base.add(const Duration(hours: 18, minutes: 33)),
    nauticalDusk: base.add(const Duration(hours: 19, minutes: 0)),
    astronomicalDusk: base.add(const Duration(hours: 19, minutes: 26)),
    astronomicalDawn: base.add(const Duration(hours: 29, minutes: 4)),
    nauticalDawn: base.add(const Duration(hours: 29, minutes: 30)),
    civilDawn: base.add(const Duration(hours: 29, minutes: 57)),
    sunrise: base.add(const Duration(hours: 30, minutes: 20)),
  );

  final populatedMoon = MoonTimes(
    moonrise: base.add(const Duration(hours: 10, minutes: 53)),
    moonset: base.add(const Duration(hours: 23, minutes: 24)),
    illumination: 87.0,
    phaseName: 'Waxing Gibbous',
  );

  // `site` is what the app has on record — null means "never configured", which
  // is a separate question from the coordinates the planetarium is currently
  // pointed at. NightTimeline gates on the former (see
  // test/screens/observing_site_gating_test.dart); MoonCard still reads the
  // planetarium observer, so both are set per scenario.
  Future<void> pump(
    WidgetTester tester, {
    required Widget child,
    required double latitude,
    required double longitude,
    required LocationSettings? site,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(900, 700);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          twilightTimesProvider.overrideWithValue(populatedNight),
          moonInfoProvider.overrideWithValue(populatedMoon),
          appObserverLocationProvider.overrideWithValue(site),
        ],
        child: Consumer(builder: (ctx, ref, _) {
          container = ProviderScope.containerOf(ctx);
          return MaterialApp(
            theme: SkotiqTheme.dark,
            home: Scaffold(body: child),
          );
        }),
      ),
    );
    container
        .read(observerLocationProvider.notifier)
        .setLocation(latitude: latitude, longitude: longitude);
    await tester.pumpAndSettle();
  }

  Widget timeline(BuildContext context) =>
      NightTimeline(colors: SkotiqColors.of(context));

  group('NightTimeline', () {
    testWidgets(
        'with no site set, prompts for a location instead of Null Island '
        'twilight times', (tester) async {
      await pump(
        tester,
        latitude: 0.0,
        longitude: 0.0,
        site: null,
        child: Builder(builder: timeline),
      );

      expect(find.text('Set an observing location for twilight times.'),
          findsOneWidget);
      expect(find.textContaining('ASTRO DARK IN'), findsNothing);
      expect(find.text('IMAGING WINDOW'), findsNothing);
      // 18:10 is the Null Island sunset; it must not be on screen anywhere.
      expect(find.textContaining('18:10'), findsNothing);
    });

    testWidgets('with a real site, renders the countdown and the band',
        (tester) async {
      await pump(
        tester,
        latitude: 40.71,
        longitude: -74.01,
        site: const LocationSettings(latitude: 40.71, longitude: -74.01),
        child: Builder(builder: timeline),
      );

      expect(find.text('Set an observing location for twilight times.'),
          findsNothing);
      expect(find.text('IMAGING WINDOW'), findsOneWidget);
    });
  });

  group('MoonCard', () {
    testWidgets(
        'with no site set, blanks rise/set but keeps phase and '
        'illumination', (tester) async {
      await pump(
        tester,
        latitude: 0.0,
        longitude: 0.0,
        site: null,
        child: Builder(
          builder: (context) => MoonCard(colors: SkotiqColors.of(context)),
        ),
      );

      // Global facts survive.
      expect(find.text('Waxing Gibbous'), findsOneWidget);
      expect(find.text('87% illuminated'), findsOneWidget);
      // Location-derived facts do not.
      expect(find.text('10:53'), findsNothing);
      expect(find.text('23:24'), findsNothing);
      // 06 copy rules: an unknown value is an em dash. `--:--` was the old
      // placeholder and is now forbidden everywhere in the app.
      expect(find.text('--:--'), findsNothing);
      expect(find.text(kReadoutUnknown), findsNWidgets(2));
    });

    testWidgets('with a real site, shows moonrise and moonset', (tester) async {
      await pump(
        tester,
        latitude: 40.71,
        longitude: -74.01,
        site: const LocationSettings(latitude: 40.71, longitude: -74.01),
        child: Builder(
          builder: (context) => MoonCard(colors: SkotiqColors.of(context)),
        ),
      );

      expect(find.text('10:53'), findsOneWidget);
      expect(find.text('23:24'), findsOneWidget);
    });
  });
}
