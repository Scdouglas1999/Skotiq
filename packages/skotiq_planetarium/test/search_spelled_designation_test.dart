// The planetarium omnibox and the mount Go-To box (both resolveBest) accept a
// designation however it is spelled, and find the objects the downloaded
// OpenNGC file does not carry.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

void main() {
  const orion = DeepSkyObject(
    id: 'NGC1976',
    name: 'M42',
    coordinates: CelestialCoordinate(ra: 5.587911, dec: -5.389667),
    type: DsoType.clusterWithNebulosity,
    magnitude: 4.0,
    catalogIds: ['LBN 974', 'MWSC 0582', 'M42'],
    commonNames: 'Great Orion Nebula,Orion Nebula',
  );
  // Brighter, with "M42" inside a cross-identifier.
  const trap = DeepSkyObject(
    id: 'NGC9998',
    name: 'NGC9998',
    coordinates: CelestialCoordinate(ra: 7.968, dec: -60.753),
    type: DsoType.openCluster,
    magnitude: 3.8,
    catalogIds: ['Cl* NGC 2516 HTR M42', '[SSP2021] M42'],
  );
  const rosette = DeepSkyObject(
    id: 'NGC2238',
    name: 'Rosette Nebula',
    coordinates: CelestialCoordinate(ra: 6.511214, dec: 5.013056),
    type: DsoType.hiiRegion,
    catalogIds: ['C 049', 'LBN 948'],
    commonNames: 'Rosette Nebula',
  );

  Future<CelestialObject?> resolve(String query) async {
    final container = ProviderContainer(
      overrides: [
        loadedStarsProvider.overrideWith((ref) async => const <Star>[]),
        loadedDsosProvider.overrideWith(
          (ref) async => const [trap, orion, rosette],
        ),
        solarSystemSearchObjectsProvider.overrideWithValue(const []),
      ],
    );
    addTearDown(container.dispose);
    return container.read(objectSearchProvider.notifier).resolveBest(query);
  }

  const cases = <String, String>{
    'M42': 'NGC1976',
    'm 42': 'NGC1976',
    'Messier 42': 'NGC1976',
    'Orion Nebula': 'NGC1976',
    'Caldwell 49': 'NGC2238',
    'C49': 'NGC2238',
    'Pleiades': 'M45',
    'M45': 'M45',
  };
  for (final entry in cases.entries) {
    test('"${entry.key}" resolves to ${entry.value}', () async {
      final best = await resolve(entry.key);
      expect(best?.id, entry.value);
    });
  }
}
