import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// Tests for the unified search omnibox resolver.
///
/// Verifies that catalog ids, NGC designations, and common names all resolve to
/// the same underlying object, and that solar-system bodies (which are not in
/// the static star/DSO catalogs) are resolvable by name.
void main() {
  // Andromeda Galaxy: M31 == NGC224, with a catalog-supplied common name.
  const andromeda = DeepSkyObject(
    id: 'NGC224',
    name: 'NGC224',
    coordinates: CelestialCoordinate(ra: 0.712, dec: 41.27),
    type: DsoType.galaxy,
    magnitude: 3.4,
    catalogIds: ['M31', 'NGC224'],
    commonNames: 'Andromeda Galaxy',
  );

  // An unrelated DSO so the resolver has to actually rank, not just return the
  // only entry.
  const orion = DeepSkyObject(
    id: 'NGC1976',
    name: 'NGC1976',
    coordinates: CelestialCoordinate(ra: 5.59, dec: -5.39),
    type: DsoType.nebula,
    magnitude: 4.0,
    catalogIds: ['M42', 'NGC1976'],
    commonNames: 'Orion Nebula',
  );

  const sirius = Star(
    id: 'HIP32349',
    name: 'Sirius',
    coordinates: CelestialCoordinate(ra: 6.75, dec: -16.7),
    magnitude: -1.46,
    catalogIds: ['HIP32349', 'HD48915'],
  );

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        loadedStarsProvider.overrideWith((ref) async => [sirius]),
        loadedDsosProvider.overrideWith((ref) async => [andromeda, orion]),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<CelestialObject?> resolve(
    ProviderContainer container,
    String query,
  ) async {
    return container.read(objectSearchProvider.notifier).resolveBest(query);
  }

  test(
    '"m31", "andromeda galaxy", and "NGC224" resolve to the same object',
    () async {
      final container = makeContainer();

      final byMessier = await resolve(container, 'm31');
      final byCommonName = await resolve(container, 'andromeda galaxy');
      final byNgc = await resolve(container, 'NGC224');

      expect(byMessier, isNotNull);
      expect(byMessier!.id, 'NGC224');
      expect(byCommonName?.id, byMessier.id);
      expect(byNgc?.id, byMessier.id);
    },
  );

  test('fuzzy common-name typo still resolves Andromeda', () async {
    final container = makeContainer();

    final result = await resolve(container, 'andromea galaxy');
    expect(result?.id, 'NGC224');
  });

  test('star catalog id (HD) resolves the star', () async {
    final container = makeContainer();

    final result = await resolve(container, 'HD48915');
    expect(result?.id, sirius.id);
  });

  test('"jupiter" resolves to the major planet', () async {
    final container = makeContainer();

    final result = await resolve(container, 'jupiter');
    expect(result, isNotNull);
    expect(result!.name, 'Jupiter');
    // Solar-system bodies are wrapped as Star objects with a PLANET_ id.
    expect(result.id, 'PLANET_Jupiter');
  });

  test('"ceres" resolves to a minor body', () async {
    final container = makeContainer();

    final result = await resolve(container, 'ceres');
    expect(result, isNotNull);
    expect(result!.id, startsWith('MINORBODY_'));
    expect(result.name.toLowerCase(), contains('ceres'));
  });

  test('solarSystemSearchObjectsProvider includes all major planets', () {
    final container = makeContainer();

    final bodies = container.read(solarSystemSearchObjectsProvider);
    final names = bodies.map((b) => b.name).toSet();
    for (final planet in PlanetaryPositions.planetNames) {
      expect(names, contains(planet));
    }
  });

  test('empty query resolves to nothing', () async {
    final container = makeContainer();
    expect(await resolve(container, ''), isNull);
  });

  test('clearing search retires an in-flight catalog result', () async {
    final stars = Completer<List<Star>>();
    final container = ProviderContainer(
      overrides: [
        loadedStarsProvider.overrideWith((ref) => stars.future),
        loadedDsosProvider.overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(objectSearchProvider.notifier);
    notifier.updateFilters(
      const SearchFilters(typeFilter: SearchObjectTypeFilter.stars),
    );

    final pending = notifier.search('Sirius');
    await Future<void>.delayed(Duration.zero);
    expect(container.read(objectSearchProvider).isSearching, isTrue);

    notifier.clear();
    stars.complete([sirius]);
    await pending;

    final state = container.read(objectSearchProvider);
    expect(state.query, isEmpty);
    expect(state.results, isEmpty);
    expect(state.isSearching, isFalse);
  });
}
