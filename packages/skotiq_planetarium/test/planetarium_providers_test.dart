import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

void main() {
  test('fovFilteredStarsProvider excludes stars outside viewport', () async {
    final stars = [
      const Star(
        id: 'in',
        name: 'In View',
        coordinates: CelestialCoordinate(ra: 0.1, dec: 0.0),
        magnitude: 2.0,
      ),
      const Star(
        id: 'far_ra',
        name: 'Far RA',
        coordinates: CelestialCoordinate(ra: 5.0, dec: 0.0),
        magnitude: 2.0,
      ),
      const Star(
        id: 'far_dec',
        name: 'Far Dec',
        coordinates: CelestialCoordinate(ra: 0.1, dec: 30.0),
        magnitude: 2.0,
      ),
    ];

    final container = ProviderContainer(
      overrides: [
        loadedStarsProvider.overrideWith((ref) async => stars),
        dynamicMagnitudeLimitsProvider.overrideWithValue((6.0, 10.0)),
      ],
    );
    addTearDown(container.dispose);

    container.read(skyViewStateProvider.notifier).setCenter(0, 0);
    container.read(skyViewStateProvider.notifier).setFieldOfView(10);

    await container.read(loadedStarsProvider.future);
    await container.read(starSpatialIndexProvider.future);
    await Future<void>.delayed(Duration.zero);

    final value = container.read(fovFilteredStarsProvider);
    expect(value, isA<AsyncData<List<Star>>>());
    final list = (value as AsyncData<List<Star>>).value;
    expect(list.map((star) => star.id).toList(), ['in']);
  });

  test('fovFilteredDsosProvider excludes DSOs outside viewport', () async {
    final dsos = [
      const DeepSkyObject(
        id: 'in',
        name: 'In View',
        coordinates: CelestialCoordinate(ra: 0.1, dec: 0.0),
        type: DsoType.galaxy,
        magnitude: 9.0,
      ),
      const DeepSkyObject(
        id: 'far_ra',
        name: 'Far RA',
        coordinates: CelestialCoordinate(ra: 5.0, dec: 0.0),
        type: DsoType.galaxy,
        magnitude: 9.0,
      ),
      const DeepSkyObject(
        id: 'far_dec',
        name: 'Far Dec',
        coordinates: CelestialCoordinate(ra: 0.1, dec: 30.0),
        type: DsoType.galaxy,
        magnitude: 9.0,
      ),
    ];

    final container = ProviderContainer(
      overrides: [
        loadedDsosProvider.overrideWith((ref) async => dsos),
        dynamicMagnitudeLimitsProvider.overrideWithValue((6.0, 10.0)),
      ],
    );
    addTearDown(container.dispose);

    container.read(skyViewStateProvider.notifier).setCenter(0, 0);
    container.read(skyViewStateProvider.notifier).setFieldOfView(10);

    await container.read(loadedDsosProvider.future);
    await container.read(dsoSpatialIndexProvider.future);
    await Future<void>.delayed(Duration.zero);

    final value = container.read(fovFilteredDsosProvider);
    expect(value, isA<AsyncData<List<DeepSkyObject>>>());
    final list = (value as AsyncData<List<DeepSkyObject>>).value;
    expect(list.map((dso) => dso.id).toList(), ['in']);
  });
}
