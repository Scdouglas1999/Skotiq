// The objects the sky view and the search hand downstream know they are
// solar-system bodies.
//
// Built as a plain `Star(id: 'PLANET_Jupiter')`, every surface that asks "what
// is this?" answers "Star" — the object popup's Type row, and worse, the
// observation_logs row written from it. This pins the construction sites; the
// user-visible strings are pinned in skotiq_app's
// solar_system_object_identity_test.dart.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/celestial_object.dart';
import 'package:skotiq_planetarium/src/coordinate_system.dart';
import 'package:skotiq_planetarium/src/providers/deep_star_providers.dart';
import 'package:skotiq_planetarium/src/providers/planetarium_providers.dart';
import 'package:skotiq_planetarium/src/astronomy/planetary_positions.dart';
import 'package:skotiq_planetarium/src/widgets/interactive_sky_view.dart';

const _jupiter = PlanetData(
  name: 'Jupiter',
  ra: 8.65857,
  dec: 18.898,
  magnitude: -1.8,
  color: 0xFFF4A460,
);

void main() {
  testWidgets('tapping a planet hands out a typed solar-system body', (
    tester,
  ) async {
    CelestialObject? tapped;

    final container = ProviderContainer(
      overrides: [
        combinedStarsProvider.overrideWithValue(
          const AsyncValue.data(<Star>[]),
        ),
        fovFilteredDsosProvider.overrideWithValue(
          const AsyncValue.data(<DeepSkyObject>[]),
        ),
        planetPositionsProvider.overrideWithValue(const [_jupiter]),
      ],
    );
    // The sky is drawn from the observer's site; without one the view renders
    // its no-site state instead.
    container
        .read(observerLocationProvider.notifier)
        .setLocation(latitude: 40.0, longitude: -74.0);
    container
        .read(skyViewStateProvider.notifier)
        .setCenter(_jupiter.ra, _jupiter.dec);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: InteractiveSkyView(
              onObjectTapped: (object, _, __) => tapped = object,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tapAt(tester.getCenter(find.byType(InteractiveSkyView)));
    await tester.pump(const Duration(milliseconds: 500));

    expect(tapped, isA<SolarSystemBody>());
    expect((tapped! as SolarSystemBody).kind, SolarSystemBodyKind.planet);
    expect(tapped!.name, 'Jupiter');

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });

  test('the unified search publishes typed solar-system bodies', () {
    final container = ProviderContainer();
    // The sky is drawn from the observer's site; without one the view renders
    // its no-site state instead.
    container
        .read(observerLocationProvider.notifier)
        .setLocation(latitude: 40.0, longitude: -74.0);
    addTearDown(container.dispose);

    final bodies = container.read(solarSystemSearchObjectsProvider);
    expect(bodies, isNotEmpty);

    final jupiter = bodies.firstWhere((o) => o.name == 'Jupiter');
    expect(jupiter, isA<SolarSystemBody>());
    expect((jupiter as SolarSystemBody).kind, SolarSystemBodyKind.planet);

    // Every entry this provider publishes is a solar-system body — nothing here
    // may reach the popup or the observation log wearing a bare Star.
    for (final body in bodies) {
      expect(body, isA<SolarSystemBody>(), reason: '${body.id} is untyped');
    }
  });

  test('a solar-system body still satisfies the point-source paths', () {
    // Deliberate: ~20 call sites across the app branch on `obj is Star` for
    // point sources (icons, popup layout, framing hand-off, slew). The subtype
    // exists so those keep working while the type-stating surfaces get the
    // truth.
    const body = SolarSystemBody(
      id: 'PLANET_Saturn',
      name: 'Saturn',
      coordinates: CelestialCoordinate(ra: 0.9667, dec: 3.435),
      kind: SolarSystemBodyKind.planet,
      magnitude: 0.8,
    );
    expect(body, isA<Star>());
    expect(body, isA<CelestialObject>());
    expect(body.designation, 'Planet');
    expect(body.kind.storageKey, 'planet');
  });
}
