// The object popup must not half-follow the selection.
//
// Click Deneb on the chart, leave the popup open, then pick M57 from the search
// panel: the popup keeps Deneb's name, HIP id, magnitude, spectral type and
// RA/Dec while its "Current Position" row switches to M57's altitude and azimuth
// to 0.1 deg and flags a red "Below Horizon" with Deneb 11.5 deg up. TONIGHT
// gives the mirror image: a green "Excellent" badge, under Deneb's name, for a
// star 2.8 deg BELOW the horizon.
//
// Two assertions, matching the two halves of the remedy:
//   * the horizon block is computed from the object the popup is HEADED BY;
//   * a selection that moves off that object closes the popup outright, rather
//     than leaving a true-looking sentence about the wrong star on screen.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planetarium/widgets/object_info_popup.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../golden/surface_golden_harness.dart';
import '../../harness/pump_app_screen.dart';

// 2026-08-02 16:05 UTC at 40 N / 105 W — the instant from the live repro,
// where the two objects sit on opposite sides of the horizon.
final _instant = DateTime.utc(2026, 8, 2, 16, 5);
const _latitude = 40.0;
const _longitude = -105.0;

/// High in the north-east at [_instant].
const _highStar = Star(
  id: 'HIP24951',
  name: 'HIP24951',
  coordinates: CelestialCoordinate(ra: 5.34422, dec: 46.96361),
  magnitude: 6.5,
  spectralType: 'A2V',
);

/// Below the horizon at [_instant].
const _lowDso = DeepSkyObject(
  id: 'NGC6720',
  name: 'Ring Nebula',
  coordinates: CelestialCoordinate(ra: 18.89306, dec: 33.02889),
  type: DsoType.planetaryNebula,
  magnitude: 8.8,
  catalogIds: ['M57', 'NGC6720'],
);

(double, double) _altAzOf(CelestialObject object) =>
    AstronomyCalculations.objectAltAz(
      raDeg: object.coordinates.raDegrees,
      decDeg: object.coordinates.dec,
      dt: _instant,
      latitudeDeg: _latitude,
      longitudeDeg: _longitude,
    );

String _altLabel(CelestialObject object) =>
    '${_altAzOf(object).$1.toStringAsFixed(1)}°';

Future<HarnessHandle> _pumpPopup(
  WidgetTester tester, {
  required CelestialObject popupObject,
  required VoidCallback onDismiss,
}) {
  return pumpAppScreen(
    tester,
    Builder(
      builder: (context) => Stack(
        children: [
          ObjectInfoPopup(
            colors: SkotiqColors.of(context),
            object: popupObject,
            coordinates: popupObject.coordinates,
            position: const Offset(400, 300),
            onDismiss: onDismiss,
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
    extraOverrides: [
      observerLocationProvider.overrideWith(
        (ref) => PlanetariumObserverNotifier()
          ..setLocation(latitude: _latitude, longitude: _longitude),
      ),
      observationMinuteProvider.overrideWithValue(_instant),
      // Astronomical dark, so the observability badge grades on altitude and
      // not on a daylight penalty.
      sunAltitudeProvider.overrideWithValue(-20.0),
    ],
  );
}

void main() {
  // Real bundled fonts: flutter_test's default typeface makes every glyph a
  // square of the font size, which overflows the 340 px popup and buries the
  // assertions below under layout errors.
  setUpAll(SurfaceGoldenHarness.ensureFonts);

  testWidgets(
      'the horizon block belongs to the popup object, not to the selection',
      (tester) async {
    var dismissed = 0;
    final handle = await _pumpPopup(
      tester,
      popupObject: _highStar,
      onDismiss: () => dismissed++,
    );
    handle.container
        .read(selectedObjectProvider.notifier)
        .selectObject(_highStar);
    await tester.pump(const Duration(milliseconds: 300));

    // Sanity: the fixture really does straddle the horizon, otherwise the
    // assertions below could pass on a coincidence.
    expect(_altAzOf(_highStar).$1, greaterThan(45.0));
    expect(_altAzOf(_lowDso).$1, lessThan(-5.0));

    expect(find.text(_altLabel(_highStar)), findsOneWidget);
    expect(find.textContaining('Below horizon'), findsNothing);

    // Now select the OTHER object from a different surface, exactly as the
    // search panel does. Rebuild before the dismissal is acted on: this frame
    // is where the popup used to publish the other object's altitude.
    handle.container
        .read(selectedObjectProvider.notifier)
        .selectObject(_lowDso);
    await tester.pump();

    expect(
      find.text(_altLabel(_lowDso)),
      findsNothing,
      reason: 'the popup must never report an altitude for an object whose '
          'name, id and coordinates it is not showing',
    );
  });

  testWidgets('selecting a different object closes the popup', (tester) async {
    var dismissed = 0;
    final handle = await _pumpPopup(
      tester,
      popupObject: _highStar,
      onDismiss: () => dismissed++,
    );
    handle.container
        .read(selectedObjectProvider.notifier)
        .selectObject(_highStar);
    await tester.pump(const Duration(milliseconds: 300));
    expect(dismissed, 0, reason: 'the popup describes the selected object');

    handle.container
        .read(selectedObjectProvider.notifier)
        .selectObject(_lowDso);
    await tester.pump();

    expect(dismissed, 1);
  });

  testWidgets('re-selecting the same target from elsewhere keeps the popup',
      (tester) async {
    var dismissed = 0;
    final handle = await _pumpPopup(
      tester,
      popupObject: _lowDso,
      onDismiss: () => dismissed++,
    );
    handle.container
        .read(selectedObjectProvider.notifier)
        .selectObject(_lowDso);
    await tester.pump(const Duration(milliseconds: 300));

    // A search result rebuilds the model object rather than handing back the
    // instance the chart tap produced.
    handle.container.read(selectedObjectProvider.notifier).selectObject(
          const DeepSkyObject(
            id: 'NGC6720',
            name: 'Ring Nebula',
            coordinates: CelestialCoordinate(ra: 18.89306, dec: 33.02889),
            type: DsoType.planetaryNebula,
            magnitude: 8.8,
            catalogIds: ['M57', 'NGC6720'],
          ),
        );
    await tester.pump();

    expect(dismissed, 0);
  });
}
