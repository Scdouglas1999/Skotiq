// The planetarium Tonight tab is a page of SITE facts — twilight,
// moonrise/moonset, transit, satellite passes — so every one of its HH:MM faces
// must follow Settings → Location → Timezone, like the status bar, the dashboard
// header clock, the night-timeline axis, the moon card and the command-bar night
// chip.
//
// Formatting with `.toLocal()` uses the controlling laptop's zone instead, so a
// rig at a site on UTC+09:00 reads "Sunset 20:14" here and "Sunset 05:14" one
// screen across, with nothing saying which zone either is in.
//
// Pumped through the real provider graph (app_settings → clockProvider →
// TonightTab) so the assertion covers the WIRING, not just the format helper.

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
  latitude: 35.68,
  longitude: 139.69,
  elevation: 40,
);

/// Pinned in UTC so the expected faces are a pure function of the chosen
/// offset — the test says nothing about the machine it runs on.
final _twilight = TwilightTimes(
  sunset: DateTime.utc(2026, 6, 10, 20, 14),
  astronomicalDusk: DateTime.utc(2026, 6, 10, 21, 30),
  astronomicalDawn: DateTime.utc(2026, 6, 11, 2, 45),
  sunrise: DateTime.utc(2026, 6, 11, 4, 5),
);

final _moon = MoonTimes(
  moonrise: DateTime.utc(2026, 6, 10, 22, 40),
  moonset: DateTime.utc(2026, 6, 11, 6, 15),
  illumination: 42,
  phaseName: 'Waxing Gibbous',
);

Widget _wrap(String timezone) {
  return ProviderScope(
    overrides: [
      appSettingsProvider.overrideWith(
        () => _StubAppSettingsNotifier(
          AppSettingsState(
            latitude: _site.latitude,
            longitude: _site.longitude,
            timezone: timezone,
            useSystemTime: false,
          ),
        ),
      ),
      appObserverLocationProvider.overrideWithValue(_site),
      twilightTimesProvider.overrideWithValue(_twilight),
      moonInfoProvider.overrideWithValue(_moon),
      // Ranking 12k DSOs is not what this test is about.
      bestTargetsProvider.overrideWith((ref) async => []),
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
  testWidgets('twilight and moon faces follow the chosen site timezone',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 2400);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(_wrap('UTC+09:00'));
    await tester.pump();

    // 20:14Z + 9h = 05:14 the next morning, JST.
    expect(find.text('05:14'), findsOneWidget, reason: 'sunset in site time');
    expect(find.text('06:30'), findsOneWidget, reason: 'astro dusk');
    expect(find.text('11:45'), findsOneWidget, reason: 'astro dawn');
    expect(find.text('13:05'), findsOneWidget, reason: 'sunrise');
    expect(find.text('07:40'), findsOneWidget, reason: 'moonrise');
    expect(find.text('15:15'), findsOneWidget, reason: 'moonset');
    // The raw UTC faces must be gone, not merely joined by the site ones.
    expect(find.text('20:14'), findsNothing);
    expect(find.text('22:40'), findsNothing);
  });

  testWidgets('a site on UTC reads the UTC faces', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 2400);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(_wrap('UTC'));
    await tester.pump();

    expect(find.text('20:14'), findsOneWidget, reason: 'sunset');
    expect(find.text('21:30'), findsOneWidget, reason: 'astro dusk');
    expect(find.text('02:45'), findsOneWidget, reason: 'astro dawn');
    expect(find.text('04:05'), findsOneWidget, reason: 'sunrise');
    expect(find.text('22:40'), findsOneWidget, reason: 'moonrise');
    expect(find.text('06:15'), findsOneWidget, reason: 'moonset');
    // Picking a different zone has to MOVE the faces, not just relabel them.
    expect(find.text('05:14'), findsNothing);
  });
}
