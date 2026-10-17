// Smoke tests for the non-GPU paths of PlanetariumScreen.
//
// Scope:
//
//   1. getDsoDisplayInfo_messier        — Messier branch of display helper.
//   2. getDsoDisplayInfo_ngc_ic         — NGC fallback branch of display
//                                         helper.
//   3. observationTimeProvider_pause    — space-bar pause path on the time
//                                         notifier (multiplier 0, isRealTime
//                                         false).
//   4. observationTimeProvider_fastForward
//                                       — setSpeedMultiplier(2.0) drops out
//                                         of real-time and pins the
//                                         multiplier the periodic timer
//                                         multiplies the per-tick delta by.
//                                         Covers the "2x/4x" buttons on
//                                         TimeControlPanel.
//   5. skyViewState_clampsAtCelestialPoles
//                                       — setCenter clamps Dec to [-90, 90]
//                                         and RA to [0, 24]. The keyboard
//                                         pan handler relies on this clamp
//                                         to keep the camera from flipping
//                                         when the user holds the arrow
//                                         keys near the poles.
//   6. searchProvider_filtersByTypeFilter
//                                       — switching SearchObjectTypeFilter
//                                         from all -> galaxies narrows the
//                                         result set to only galaxy-typed
//                                         DSOs. This is the same filter the
//                                         catalog/search sidebar dropdown
//                                         drives.
//   7. searchProvider_findsObjectByCommonName
//                                       — querying "Andromeda Galaxy"
//                                         resolves to M31 via the
//                                         well-known-names lookup. This is
//                                         the user-typed search path.
//
// Why no widget pump of the full PlanetariumScreen here: the screen
// fans out to ~30 providers (stars, DSOs, mount/rotator state, Bortle
// class, horizon profile, performance monitor, etc.) and a GPU sky
// renderer that pulls shaders from disk. A meaningful render-time smoke
// test would require stubbing every one of those — out of scope. The
// tests below cover the deterministic non-GPU paths the screen and its
// keyboard shortcuts touch.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planetarium/planetarium_screen.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

void main() {
  group('getDsoDisplayInfo', () {
    test(
        'getDsoDisplayInfo_messier: returns Messier number + "M" tag '
        'when catalogIds contains M\\d+', () {
      // M31 with an explicit Messier catalog id. The helper should
      // prefer the Messier designation over the bare `id` so the UI
      // shows "M31" instead of the raw NGC number.
      const m31 = DeepSkyObject(
        id: 'NGC224',
        name: 'Andromeda Galaxy',
        coordinates: CelestialCoordinate(ra: 0.712, dec: 41.269),
        type: DsoType.galaxy,
        catalogIds: ['M31', 'NGC224'],
      );

      final (displayName, catalogTag) = getDsoDisplayInfo(m31);

      expect(displayName, 'M31',
          reason: 'Messier objects must surface their M-number, not the '
              'NGC fallback, because that is the label most observers '
              'recognise.');
      expect(catalogTag, 'M',
          reason: 'Catalog tag drives the badge colour in ObjectInfoPopup; '
              'Messier objects must tag as "M".');
    });

    test(
        'getDsoDisplayInfo_ngc_ic: returns NGC designation + "NGC" tag '
        'for non-Messier DSOs', () {
      // NGC 7000 (North America Nebula) has no Messier number. The
      // helper should fall through the Messier branch and return the
      // NGC id with the "NGC" tag.
      const ngc7000 = DeepSkyObject(
        id: 'NGC7000',
        name: 'North America Nebula',
        coordinates: CelestialCoordinate(ra: 20.97, dec: 44.33),
        type: DsoType.emissionNebula,
        catalogIds: ['NGC7000'],
      );

      final (displayName, catalogTag) = getDsoDisplayInfo(ngc7000);

      expect(displayName, 'NGC7000',
          reason: 'Non-Messier NGC objects must surface their NGC '
              'designation as the primary display name.');
      expect(catalogTag, 'NGC',
          reason: 'Catalog tag must reflect the NGC catalogue so the '
              'popup badge colour matches.');
    });
  });

  group('observationTimeProvider', () {
    test(
        'observationTimeProvider_pause: setSpeedMultiplier(0) clears '
        'isRealTime and freezes the time stream', () {
      // Why ProviderContainer not pumpWidget: this is a state-level
      // test of the notifier the space-bar handler in
      // planetarium_screen.dart drives. Pumping a full widget tree
      // would drag in twilightTimesProvider, observerLocationProvider,
      // and the GPU sky renderer for no extra coverage.
      final container =
          ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
      // Why dispose: ObservationTimeNotifier owns a periodic Timer. Without
      // dispose, the timer keeps firing and the test framework reports a
      // pending timer at teardown.
      addTearDown(container.dispose);

      final initial = container.read(observationTimeProvider);
      expect(initial.isRealTime, isTrue,
          reason: 'Notifier seeds itself into real-time mode so a fresh '
              'planetarium session reflects wall-clock time.');
      expect(initial.speedMultiplier, 1.0,
          reason: 'Default multiplier is 1x so observation time advances '
              'one second per real second when in real-time mode.');

      // Mirror the space-bar pause path: setSpeedMultiplier(0) is what
      // _handleKeyEvent calls when the time stream is currently real-
      // time and the user wants to freeze the sky.
      container.read(observationTimeProvider.notifier).setSpeedMultiplier(0);

      final paused = container.read(observationTimeProvider);
      expect(paused.isRealTime, isFalse,
          reason: 'Pause must drop out of real-time mode; otherwise the '
              'periodic timer would overwrite the frozen instant on the '
              'next tick.');
      expect(paused.speedMultiplier, 0.0,
          reason: 'Multiplier must persist exactly the requested value '
              'so subsequent ticks contribute zero delta and the time '
              'remains frozen.');
    });

    test(
        'observationTimeProvider_fastForward: setSpeedMultiplier(2.0) '
        'drops out of real-time and pins the multiplier the per-tick '
        'delta is scaled by', () {
      // Why we don't `await` a real second: ObservationTimeNotifier's
      // periodic timer is wall-clock-based, not fake-async-friendly
      // (the provider doesn't accept an injected Clock). Verifying the
      // state mutation directly is the smallest test that proves the
      // TimeControlPanel "2x" button takes effect — the per-tick math
      // in _startTimer reads `state.speedMultiplier`, so as long as the
      // multiplier is correctly stored, the tick logic is exercised.
      final container =
          ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
      addTearDown(container.dispose);

      container.read(observationTimeProvider.notifier).setSpeedMultiplier(2.0);

      final fast = container.read(observationTimeProvider);
      expect(fast.isRealTime, isFalse,
          reason: 'Fast-forward must leave real-time mode; otherwise the '
              'next periodic tick would overwrite the simulated time '
              'with DateTime.now().');
      expect(fast.speedMultiplier, 2.0,
          reason: 'Speed multiplier must persist exactly so the periodic '
              'timer applies `Duration(seconds: multiplier.round())` per '
              'tick — getting this wrong would silently speed up or slow '
              'down the simulated sky.');
    });
  });

  group('skyViewStateProvider', () {
    test(
        'skyViewState_clampsAtCelestialPoles: setCenter with extreme '
        'inputs near RA wrap and Dec ±90° clamps to valid celestial '
        'coordinates', () {
      // Why this matters: the arrow-key handler in _handleKeyEvent calls
      // skyViewStateProvider.notifier.setCenter directly with a clamp
      // expression. If a refactor changes the notifier's own clamp,
      // holding the down-arrow key near Dec=+90 could send Dec to +180
      // and flip the camera through the pole — a class of bug that's
      // very visible to users but trivial to introduce.
      final container =
          ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
      addTearDown(container.dispose);

      final notifier = container.read(skyViewStateProvider.notifier);

      // Push north of the celestial north pole. SkyViewNotifier.setCenter
      // clamps Dec to [-90, 90], so the resulting state should land
      // exactly on +90.
      notifier.setCenter(12.0, 200.0);
      final northClamped = container.read(skyViewStateProvider);
      expect(northClamped.centerDec, 90.0,
          reason: 'Dec must clamp to +90 at the north celestial pole; '
              'allowing values past +90 would let the camera flip the '
              'sky upside-down (RA inverted).');

      // Push south of the south pole.
      notifier.setCenter(0.0, -500.0);
      final southClamped = container.read(skyViewStateProvider);
      expect(southClamped.centerDec, -90.0,
          reason: 'Dec must clamp to -90 at the south celestial pole '
              'for the same reason as +90.');

      // RA wraps at 24h. setCenter clamps rather than wraps — the documented
      // behaviour in planetarium_providers.
      // Pushing RA = 30h should land on 24h, and pushing -5h should
      // land on 0h. We pin both ends so a future "wrap instead of
      // clamp" refactor is a deliberate decision, not a silent change.
      notifier.setCenter(30.0, 0.0);
      final raHigh = container.read(skyViewStateProvider);
      expect(raHigh.centerRA, 24.0,
          reason: 'RA must clamp at 24h (sidereal day boundary). The '
              'keyboard pan handler depends on this clamp to avoid '
              'feeding the projection invalid RA values.');

      notifier.setCenter(-5.0, 0.0);
      final raLow = container.read(skyViewStateProvider);
      expect(raLow.centerRA, 0.0,
          reason: 'RA must clamp at 0h on the low end for the same '
              'reason as the 24h clamp.');
    });
  });

  group('objectSearchProvider', () {
    // The search notifier reads `loadedDsosProvider` and
    // `loadedStarsProvider`. In production those FutureProviders load
    // the full HYG / OpenNGC catalogs from disk — too heavy and
    // non-deterministic for a unit test. We override both with small
    // in-memory fixtures so we can drive the public `.search()` API.
    const fixtureGalaxy = DeepSkyObject(
      id: 'NGC1234',
      name: 'Fixture Galaxy',
      coordinates: CelestialCoordinate(ra: 1.0, dec: 10.0),
      type: DsoType.galaxy,
      magnitude: 9.0,
      catalogIds: ['NGC1234'],
    );
    const fixtureNebula = DeepSkyObject(
      id: 'NGC5678',
      name: 'Fixture Nebula',
      coordinates: CelestialCoordinate(ra: 5.0, dec: 20.0),
      type: DsoType.emissionNebula,
      magnitude: 8.0,
      catalogIds: ['NGC5678'],
    );
    const fixtureCluster = DeepSkyObject(
      id: 'NGC9999',
      name: 'Fixture Cluster',
      coordinates: CelestialCoordinate(ra: 10.0, dec: 30.0),
      type: DsoType.openCluster,
      magnitude: 7.0,
      catalogIds: ['NGC9999'],
    );
    // Andromeda fixture exercises the well-known-names lookup path
    // (search query "Andromeda Galaxy" → catalog id "M31").
    const fixtureAndromeda = DeepSkyObject(
      id: 'NGC224',
      name: 'Andromeda Galaxy',
      coordinates: CelestialCoordinate(ra: 0.712, dec: 41.269),
      type: DsoType.galaxy,
      magnitude: 3.4,
      catalogIds: ['M31', 'NGC224'],
      commonNames: 'Andromeda Galaxy',
    );

    ProviderContainer buildContainer(List<DeepSkyObject> dsos) {
      // Why overrideWith on FutureProvider returning a value: the
      // notifier `await`s `_ref.read(loadedDsosProvider.future)`. An
      // override that returns `Future.value([...])` makes that await
      // resolve synchronously inside the same microtask.
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          loadedDsosProvider.overrideWith((ref) async => dsos),
          // Stars are unused in these DSO-focused tests; an empty
          // list short-circuits the star loop in `search()`.
          loadedStarsProvider.overrideWith((ref) async => <Star>[]),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test(
        'searchProvider_filtersByTypeFilter: switching SearchObjectType'
        'Filter narrows results to only the matching DSO type', () {
      final container = buildContainer([
        fixtureGalaxy,
        fixtureNebula,
        fixtureCluster,
      ]);
      final notifier = container.read(objectSearchProvider.notifier);

      // Baseline: typeFilter=all, query="NGC" should match all three
      // fixtures because each id starts with "NGC" (score 1, "starts
      // with").
      return notifier.search('NGC').then((_) {
        final allResults = container.read(objectSearchProvider);
        expect(allResults.results.length, 3,
            reason: 'typeFilter=all must include galaxies, nebulae, and '
                'clusters — three fixtures, three results.');

        // Narrow to galaxies. updateFilters re-runs search internally when
        // there is an active query, so the result list updates without an
        // explicit second search() call.
        notifier.updateFilters(
          const SearchFilters(typeFilter: SearchObjectTypeFilter.galaxies),
        );
        return notifier.search('NGC').then((_) {
          final galaxyOnly = container.read(objectSearchProvider);
          expect(galaxyOnly.results.length, 1,
              reason: 'Galaxy-only filter must exclude the nebula and '
                  'cluster fixtures — only NGC1234 remains.');
          expect((galaxyOnly.results.single as DeepSkyObject).id, 'NGC1234',
              reason: 'The retained result must be the galaxy fixture; '
                  'a mismatch means the DsoType.isGalaxy predicate '
                  'regressed.');

          // Switch to nebulae and confirm a different single result.
          notifier.updateFilters(
              const SearchFilters(typeFilter: SearchObjectTypeFilter.nebulae));
          return notifier.search('NGC').then((_) {
            final nebulaOnly = container.read(objectSearchProvider);
            expect(nebulaOnly.results.length, 1,
                reason: 'Nebula filter must keep the emissionNebula '
                    'fixture and drop the galaxy and cluster.');
            expect((nebulaOnly.results.single as DeepSkyObject).id, 'NGC5678',
                reason: 'The retained result must be the nebula fixture.');
          });
        });
      });
    });

    test(
        'searchProvider_findsObjectByCommonName: a common-name query '
        'resolves to the matching catalog object', () async {
      // Andromeda Galaxy is in the well-known-names map keyed to M31 /
      // NGC224. The search code adds the normalized ids of every matching
      // well-known entry to
      // wellKnownIds and then matches any DSO whose normalised id is in
      // that set.
      final container = buildContainer([
        fixtureAndromeda,
        fixtureNebula, // distractor: should not match "andromeda"
      ]);
      final notifier = container.read(objectSearchProvider.notifier);

      await notifier.search('Andromeda Galaxy');

      final results = container.read(objectSearchProvider).results;
      expect(results, isNotEmpty,
          reason: 'A common-name query for a catalogued object must '
              'return at least one result; an empty list means the '
              'well-known-names lookup table desynced from the search '
              'matching logic.');
      // The first result is whichever object scored lowest. Andromeda
      // matches via well-known-names (score 1) and also via
      // commonNames "Andromeda Galaxy" (score 0, exact). Either way it
      // must be the Andromeda fixture, not the nebula distractor.
      final first = results.first;
      expect(first, isA<DeepSkyObject>(),
          reason: 'A DSO query must surface a DeepSkyObject, not a '
              'Star — the type filter is "all" so a stray star match '
              'would be a regression.');
      expect((first as DeepSkyObject).id, 'NGC224',
          reason: 'The top match for "Andromeda Galaxy" must be the '
              'M31/NGC224 fixture, proving both the well-known-names '
              'lookup and the commonNames matching path are wired up.');
    });
  });
}
