import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// M102 is not in OpenNGC; it is conventionally NGC 5866. The planetarium
/// search (and Tonight's Go to, which resolves through it) finds it the way
/// Framing does.
void main() {
  const spindle = DeepSkyObject(
    id: 'NGC5866',
    name: 'NGC5866',
    coordinates: CelestialCoordinate(ra: 15.108, dec: 55.763),
    type: DsoType.galaxy,
    magnitude: 9.9,
    catalogIds: ['NGC5866'],
  );
  const pinwheel = DeepSkyObject(
    id: 'NGC5457',
    name: 'NGC5457',
    coordinates: CelestialCoordinate(ra: 14.054, dec: 54.349),
    type: DsoType.galaxy,
    magnitude: 7.9,
    catalogIds: ['M101', 'NGC5457'],
  );

  test('"M102" resolves to NGC 5866 in the planetarium search', () async {
    final container = ProviderContainer(
      overrides: [
        loadedStarsProvider.overrideWith((ref) async => const <Star>[]),
        loadedDsosProvider.overrideWith(
          (ref) async => const [pinwheel, spindle],
        ),
      ],
    );
    addTearDown(container.dispose);

    for (final query in ['M102', 'm 102', 'Messier 102']) {
      final best = await container
          .read(objectSearchProvider.notifier)
          .resolveBest(query);
      expect(best?.id, 'NGC5866', reason: query);
    }
  });

  test('the shared resolver Framing uses agrees', () {
    final ranked = TargetNameResolver.rank('M102', const [pinwheel, spindle]);
    expect(ranked.first.object.id, 'NGC5866');
  });
}
