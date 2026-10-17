// Regression test: a planet must not be presented — or RECORDED — as a star.
//
// Live repro: clicking Jupiter opened a popup headed "Jupiter" with an
// identifier chip reading "PLANET_Jupiter" (the internal join key) and a Type
// row that said "Star". Logging the observation from that popup wrote
// (object_name 'Jupiter', object_type 'star', catalog_id 'PLANET_Jupiter') to
// observation_logs — a permanent record, kept for years, classifying a planet
// as a star under an identifier no catalogue uses.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planetarium/widgets/object_info_popup.dart';
import 'package:skotiq_app/screens/planetarium/widgets/observation_log_dialog.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../golden/surface_golden_harness.dart';
import '../../harness/pump_app_screen.dart';

const _jupiter = SolarSystemBody(
  id: 'PLANET_Jupiter',
  name: 'Jupiter',
  coordinates: CelestialCoordinate(ra: 8.65857, dec: 18.898),
  kind: SolarSystemBodyKind.planet,
  magnitude: -1.8,
);

const _realStar = Star(
  id: 'HIP24608',
  name: 'Capella',
  coordinates: CelestialCoordinate(ra: 5.2782, dec: 45.998),
  magnitude: 0.08,
  spectralType: 'G8III',
);

Future<HarnessHandle> _pumpPopup(
  WidgetTester tester,
  CelestialObject object,
) {
  return pumpAppScreen(
    tester,
    Builder(
      builder: (context) => Stack(
        children: [
          ObjectInfoPopup(
            colors: SkotiqColors.of(context),
            object: object,
            coordinates: object.coordinates,
            position: const Offset(400, 300),
            onDismiss: () {},
            onSendToFraming: () {},
            onAddToSequencer: () {},
            onAddToQueue: () {},
            onSlewToTarget: () {},
            onSlewAndCenter: () {},
            onSlewCenterRotate: () {},
            hasRotator: false,
          ),
        ],
      ),
    ),
    settle: false,
    extraOverrides: _plainSkyOverrides,
  );
}

/// Pins the planetarium clock and site so the popup does not spin up the
/// per-second observation-time notifier (its periodic Timer outlives the pump
/// and trips the widget tester's pending-timer invariant).
final _plainSkyOverrides = [
  observerLocationProvider.overrideWith(
    (ref) => PlanetariumObserverNotifier()
      ..setLocation(latitude: 40.0, longitude: -105.0),
  ),
  observationMinuteProvider.overrideWithValue(DateTime.utc(2026, 8, 2, 16, 5)),
  sunAltitudeProvider.overrideWithValue(-20.0),
];

void main() {
  // Real bundled fonts: the test typeface renders every glyph as a square of
  // the font size, which overflows the 340 px popup and buries the assertions.
  setUpAll(SurfaceGoldenHarness.ensureFonts);

  testWidgets('the popup calls a planet a planet, and hides the internal id',
      (tester) async {
    await _pumpPopup(tester, _jupiter);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Jupiter'), findsWidgets);
    expect(find.text('Planet'), findsWidgets,
        reason: 'the Type row must say what the object is');
    expect(find.text('Star'), findsNothing);
    expect(find.text('PLANET_Jupiter'), findsNothing,
        reason: 'the identifier chip must not show the internal join key');
  });

  testWidgets('a real star is still typed as a star', (tester) async {
    await _pumpPopup(tester, _realStar);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Star (G8III)'), findsWidgets);
    expect(find.text('Planet'), findsNothing);
  });

  testWidgets('the observation log records a planet as a planet',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const Scaffold(
        body: ObservationLogDialog(
          object: _jupiter,
          coordinates: CelestialCoordinate(ra: 8.65857, dec: 18.898),
          altAz: (38.68, 97.48),
        ),
      ),
      settle: false,
      extraOverrides: _plainSkyOverrides,
    );
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Log observation').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final logs = await handle.database.observationLogsDao.getAllLogs();
    expect(logs, hasLength(1));
    expect(logs.single.objectName, 'Jupiter');
    expect(logs.single.objectType, 'planet',
        reason: 'an observing log that says "star" for Jupiter is wrong '
            'forever — it is exported and filtered on');
    expect(logs.single.catalogId, isNull,
        reason: 'PLANET_Jupiter is an internal key, not a catalogue id');
  });
}
