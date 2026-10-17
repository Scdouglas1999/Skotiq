// The Tonight tab must not headline a transit altitude.
//
// Transit altitude is a number every object at declination == latitude shares,
// and its transit TIME can fall in broad daylight — 09:24 at 40N/105W on a panel
// showing Sunset 22:16. So "Best Targets Tonight" leads with the hours the
// target is actually usable inside darkness and the moment it peaks INSIDE that
// window.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planetarium/widgets/tonight_tab.dart';
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  _StubAppSettingsNotifier(this.initial);

  final AppSettingsState initial;

  @override
  Future<AppSettingsState> build() async => initial;
}

const _site = LocationSettings(
  latitude: 40.0,
  longitude: -105.0,
  elevation: 1600,
);

final _twilight = TwilightTimes(
  sunset: DateTime.utc(2026, 8, 3, 2, 16),
  astronomicalDusk: DateTime.utc(2026, 8, 3, 4, 0),
  astronomicalDawn: DateTime.utc(2026, 8, 3, 10, 12),
  sunrise: DateTime.utc(2026, 8, 3, 11, 56),
);

const _moon = MoonTimes(
  illumination: 84,
  phaseName: 'Waning Gibbous',
);

/// A dec-40 galaxy at 40N: transit altitude ~90°, but it culminates at 09:24
/// local — high but unobservable, the shape an altitude-only sort ranks first.
final _zenithGalaxy = TonightTarget(
  object: const DeepSkyObject(
    id: 'NGC6685',
    name: 'NGC6685',
    coordinates: CelestialCoordinate(ra: 18.666, dec: 39.97),
    type: DsoType.galaxy,
    magnitude: 14.6,
  ),
  visibility: ObjectVisibility(
    transitTime: DateTime.utc(2026, 8, 3, 15, 24),
    transitAltitude: 90,
  ),
  hoursInDarkness: 3.5,
  peakAltitudeDeg: 62,
  peakTime: DateTime.utc(2026, 8, 3, 10, 0),
  score: 41,
);

Widget _wrap() {
  return ProviderScope(
    overrides: [
      appSettingsProvider.overrideWith(
        () => _StubAppSettingsNotifier(
          AppSettingsState(
            latitude: _site.latitude,
            longitude: _site.longitude,
            timezone: 'UTC',
            useSystemTime: false,
          ),
        ),
      ),
      appObserverLocationProvider.overrideWithValue(_site),
      twilightTimesProvider.overrideWithValue(_twilight),
      moonInfoProvider.overrideWithValue(_moon),
      bestTargetsProvider.overrideWith((ref) async => [_zenithGalaxy]),
    ],
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: Builder(
          builder: (context) => TonightTab(colors: SkotiqColors.of(context)),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a target card leads with usable dark hours, not a transit',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 2400);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(_wrap());
    await tester.pump();

    expect(find.text('3.5h'), findsOneWidget, reason: 'hours in darkness');
    // The moment it peaks INSIDE darkness, not the 15:24Z transit.
    expect(find.text('10:00'), findsOneWidget);
    expect(find.text('15:24'), findsNothing);
    // The transit altitude every dec-40 object shares is gone from the card.
    expect(find.text('90°'), findsNothing);

    // And the panel says what the number means.
    expect(
      find.text('Usable hours above 30° in darkness, and when each peaks'),
      findsOneWidget,
    );
  });

  // The header tooltip comes from the RANKER itself, so the words cannot drift
  // away from the weights — hand-written prose describing the blend goes stale
  // the moment the weights change.
  testWidgets('the header tooltip is the ranker\'s own disclosed rule',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 2400);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(_wrap());
    await tester.pump();

    final tooltips = tester
        .widgetList<Tooltip>(find.byType(Tooltip))
        .map((t) => t.message)
        .toList();
    expect(tooltips, contains(kTonightRankingTooltip));
    expect(
      tooltips.where((m) => (m ?? '').contains('same score the planner')),
      isEmpty,
    );
  });
}
