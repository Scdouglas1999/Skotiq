// Typing an unambiguous catalogue number resolves it.
//
// OpenNGC ships every cross-identifier it knows, zero-padded — NGC7107 carries
// "PGC 067209", IC728 carries "UGC 06720", NGC7112 carries "PGC 067208". Scoring
// a typed "6720" as a plain SUBSTRING match against all of them lands those
// galaxies level with NGC6720 itself, separated only by the brightness
// tie-break. An exact designation ranks above every fuzzier band, so the number
// an observer types names the object they meant whatever else contains those
// digits.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

void main() {
  // M57 == NGC6720. Deliberately the FAINTER of the two DSOs here so the
  // brightness tie-break cannot be what puts it first.
  const ring = DeepSkyObject(
    id: 'NGC6720',
    name: 'Ring Nebula',
    coordinates: CelestialCoordinate(ra: 18.893, dec: 33.03),
    type: DsoType.planetaryNebula,
    magnitude: 8.8,
    catalogIds: ['M57', 'IRAS 18517+3257', 'PN G063.1+13.9'],
    commonNames: 'Ring Nebula',
  );

  // A galaxy that has nothing to do with "6720" except that its UGC number
  // contains those digits — and is brighter, so a substring match ranks it
  // first.
  const ugcDecoy = DeepSkyObject(
    id: 'IC728',
    name: 'IC728',
    coordinates: CelestialCoordinate(ra: 11.747, dec: -1.601),
    type: DsoType.galaxy,
    magnitude: 5.0,
    catalogIds: ['UGC 06720', 'PGC 036580'],
  );

  // Same shape via a zero-padded PGC number.
  const pgcDecoy = DeepSkyObject(
    id: 'NGC7107',
    name: 'NGC7107',
    coordinates: CelestialCoordinate(ra: 21.707, dec: -44.79),
    type: DsoType.galaxy,
    magnitude: 6.0,
    catalogIds: ['PGC 067209', 'ESO 287-052'],
  );

  // A bright star whose HD number is exactly 6720: a bare "6720" must NOT
  // promote it, because a bare number is NGC/IC/M shorthand, not HD shorthand.
  const hdStar = Star(
    id: 'HD6720',
    name: 'HD6720',
    coordinates: CelestialCoordinate(ra: 1.13, dec: 12.5),
    magnitude: 4.0,
    catalogIds: ['HD6720', 'HIP5300'],
  );

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        loadedStarsProvider.overrideWith((ref) async => [hdStar]),
        loadedDsosProvider.overrideWith(
          (ref) async => [ugcDecoy, pgcDecoy, ring],
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<List<CelestialObject>> search(
    ProviderContainer container,
    String query,
  ) async {
    await container.read(objectSearchProvider.notifier).search(query);
    return container.read(objectSearchProvider).results;
  }

  test('a bare NGC number resolves that object, not a brighter PGC/UGC '
      'coincidence', () async {
    final container = makeContainer();

    final results = await search(container, '6720');

    expect(results, isNotEmpty);
    expect(
      results.first.id,
      'NGC6720',
      reason: 'the typed designation must win over substring coincidences',
    );
    // The coincidences are still reachable — just not first.
    expect(results.map((o) => o.id), containsAll(<String>['IC728', 'NGC7107']));
  });

  test('Enter/fly-to resolves the typed designation', () async {
    final container = makeContainer();

    final best = await container
        .read(objectSearchProvider.notifier)
        .resolveBest('6720');

    expect(best?.id, 'NGC6720');
  });

  test(
    'a bare number does not promote a star with the same HD number',
    () async {
      final container = makeContainer();

      final results = await search(container, '6720');

      expect(results.first.id, 'NGC6720');
      expect(
        results.indexWhere((o) => o.id == 'HD6720'),
        isNot(0),
        reason: 'nobody types a bare number meaning HD',
      );
    },
  );

  test('a prefixed query pins the catalogue', () async {
    final container = makeContainer();

    expect((await search(container, 'UGC 6720')).first.id, 'IC728');
    expect((await search(container, 'PGC 67209')).first.id, 'NGC7107');
    expect((await search(container, 'HD 6720')).first.id, 'HD6720');
    expect((await search(container, 'NGC 6720')).first.id, 'NGC6720');
  });

  test('zero padding and spacing do not change the answer', () async {
    final container = makeContainer();

    for (final query in ['ngc6720', 'NGC 6720', 'ngc06720', 'M57', 'm 57']) {
      expect(
        (await search(container, query)).first.id,
        'NGC6720',
        reason: 'query "$query"',
      );
    }
  });

  // The star loop needs its own coverage: every case above is decided inside
  // the DSO loop, so deleting the designation branch in the star loop leaves
  // them all green.
  //
  // Two shapes, because the padded one is NOT what HYG emits: star_catalog.dart
  // builds ids as `HIP$n` / `HD$n` and cross-ids as `HIP $n` / `HD $n`, with no
  // zero padding. Padding is the DSO cross-identifier shape (and whatever a
  // future star catalog ships), so it stays covered — and the branch is pinned
  // against the shape the SHIPPED loader produces as well, or the star half is
  // only ever exercised by fixtures the app cannot generate.
  test('a padded star catalogue id is an exact designation too', () async {
    const paddedStar = Star(
      id: 'HD006720',
      name: 'HD006720',
      coordinates: CelestialCoordinate(ra: 1.13, dec: 12.5),
      magnitude: 4.0,
      catalogIds: ['HD 006720', 'HIP 005300'],
    );
    // Scores 1 ("starts with") on its display name, which beats the fuzzy band
    // the padded star would otherwise fall into.
    const prefixDecoy = DeepSkyObject(
      id: 'NGC9999',
      name: 'NGC9999',
      coordinates: CelestialCoordinate(ra: 5.0, dec: 10.0),
      type: DsoType.galaxy,
      magnitude: 9.0,
      commonNames: 'HIP 5300 Field',
    );

    final container = ProviderContainer(
      overrides: [
        loadedStarsProvider.overrideWith((ref) async => [paddedStar]),
        loadedDsosProvider.overrideWith((ref) async => [prefixDecoy]),
      ],
    );
    addTearDown(container.dispose);

    final results = await search(container, 'HIP 5300');

    expect(
      results.first.id,
      'HD006720',
      reason:
          'the typed HIP number names the star, not a name that '
          'merely begins with those characters',
    );
  });

  test('an UNPADDED HYG-shaped star id is an exact designation too', () async {
    // Exactly what star_catalog.dart emits for HIP 5300 / HD 6720.
    const hygStar = Star(
      id: 'HD6720',
      name: 'HD6720',
      coordinates: CelestialCoordinate(ra: 1.13, dec: 12.5),
      magnitude: 9.5,
      catalogIds: ['HIP 5300', 'HD 6720'],
    );
    // Its common name IS the typed string, so _scoreMatch gives it 0 — the same
    // band the star's own id reaches once whitespace is normalised. Brighter,
    // so the magnitude tie-break hands it the top slot unless the designation
    // branch lifts the star to -1.
    const exactNameDecoy = DeepSkyObject(
      id: 'NGC9998',
      name: 'NGC9998',
      coordinates: CelestialCoordinate(ra: 5.0, dec: 10.0),
      type: DsoType.galaxy,
      magnitude: 6.0,
      commonNames: 'HIP 5300',
    );

    final container = ProviderContainer(
      overrides: [
        loadedStarsProvider.overrideWith((ref) async => [hygStar]),
        loadedDsosProvider.overrideWith((ref) async => [exactNameDecoy]),
      ],
    );
    addTearDown(container.dispose);

    expect((await search(container, 'HIP 5300')).first.id, 'HD6720');
    expect((await search(container, 'hip5300')).first.id, 'HD6720');
  });
}
