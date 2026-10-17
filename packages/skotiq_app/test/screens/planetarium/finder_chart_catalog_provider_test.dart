// The finder-chart catalog snapshot: an exported PDF is a durable artifact, so
// it must wait for the spatial indexes and preserve load failures instead of
// quietly becoming an empty chart.
//
// The snapshot is keyed by an explicit [FinderChartRegion] rather than the live
// view centre: filling it from whatever is on screen packs a chart titled for
// one object with a completely different patch of sky.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planetarium/providers/finder_chart_catalog_provider.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

const _subjectRegion = (
  centerRaHours: 8.63,
  centerDecDeg: 19.27,
  fovDeg: 1.5,
);

const _elsewhereRegion = (
  centerRaHours: 0.0,
  centerDecDeg: 0.0,
  fovDeg: 1.5,
);

Star _star(String id, double raHours, double dec, double mag) => Star(
      id: id,
      name: id,
      coordinates: CelestialCoordinate(ra: raHours, dec: dec),
      magnitude: mag,
    );

StarSpatialIndex _starIndex(List<Star> stars) =>
    StarSpatialIndex()..addAll(stars);

DsoSpatialIndex _dsoIndex(List<DeepSkyObject> dsos) =>
    DsoSpatialIndex()..addAll(dsos);

ProviderContainer _container({
  AsyncValue<StarSpatialIndex>? starIndex,
  AsyncValue<DsoSpatialIndex>? dsoIndex,
}) {
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      starSpatialIndexProvider.overrideWith(
        (ref) => switch (starIndex ?? AsyncValue.data(_starIndex(const []))) {
          AsyncData(:final value) => Future.value(value),
          AsyncError(:final error, :final stackTrace) =>
            Future<StarSpatialIndex>.error(error, stackTrace),
          _ => Future<StarSpatialIndex>.value(_starIndex(const [])),
        },
      ),
      dsoSpatialIndexProvider.overrideWith(
        (ref) => switch (dsoIndex ?? AsyncValue.data(_dsoIndex(const []))) {
          AsyncData(:final value) => Future.value(value),
          AsyncError(:final error, :final stackTrace) =>
            Future<DsoSpatialIndex>.error(error, stackTrace),
          _ => Future<DsoSpatialIndex>.value(_dsoIndex(const [])),
        },
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('catalog failure is preserved instead of becoming an empty chart',
      () async {
    final container = _container(
      starIndex: AsyncValue<StarSpatialIndex>.error(
        StateError('star index unavailable'),
        StackTrace.current,
      ),
    );

    await expectLater(
      container.read(finderChartCatalogSnapshotProvider(_subjectRegion).future),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('star index unavailable'),
        ),
      ),
    );
  });

  test('a DSO catalog failure is preserved too', () async {
    final container = _container(
      dsoIndex: AsyncValue<DsoSpatialIndex>.error(
        StateError('dso index unavailable'),
        StackTrace.current,
      ),
    );

    await expectLater(
      container.read(finderChartCatalogSnapshotProvider(_subjectRegion).future),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('dso index unavailable'),
        ),
      ),
    );
  });

  test('authoritative empty viewport remains a valid export snapshot',
      () async {
    final container = _container();

    final snapshot = await container
        .read(finderChartCatalogSnapshotProvider(_subjectRegion).future);

    expect(snapshot.stars, isEmpty);
    expect(snapshot.dsos, isEmpty);
  });

  test('the snapshot follows the requested region, not the live view',
      () async {
    // Two stars 8h37m apart. The chart region must decide which one is returned.
    final container = _container(
      starIndex: AsyncValue.data(
        _starIndex([
          _star('near-subject', 8.63, 19.27, 6.0),
          _star('near-zero', 0.0, 0.0, 6.0),
        ]),
      ),
    );

    final onSubject = await container
        .read(finderChartCatalogSnapshotProvider(_subjectRegion).future);
    expect(onSubject.stars.map((s) => s.id), ['near-subject']);

    final elsewhere = await container
        .read(finderChartCatalogSnapshotProvider(_elsewhereRegion).future);
    expect(elsewhere.stars.map((s) => s.id), ['near-zero']);
  });

  test(
      'the returned lists are unmodifiable so an export cannot be mutated '
      'mid-render', () async {
    final container = _container(
      starIndex: AsyncValue.data(
        _starIndex([_star('a', 8.63, 19.27, 6.0)]),
      ),
    );

    final snapshot = await container
        .read(finderChartCatalogSnapshotProvider(_subjectRegion).future);
    expect(snapshot.stars, hasLength(1));
    expect(
      () => snapshot.stars.add(_star('b', 8.63, 19.27, 7.0)),
      throwsUnsupportedError,
    );
  });
}
