import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/framing_search_provider.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

const _m42 = DeepSkyObject(
  id: 'M42',
  name: 'Orion Nebula',
  coordinates: CelestialCoordinate(ra: 5.588, dec: -5.391),
  type: DsoType.emissionNebula,
  magnitude: 4.0,
  catalogIds: ['NGC 1976'],
);

void main() {
  test('whitespace query clears instead of matching the entire catalog',
      () async {
    var catalogRead = false;
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        loadedDsosProvider.overrideWith((ref) {
          catalogRead = true;
          return const <DeepSkyObject>[_m42];
        }),
        loggingServiceProvider.overrideWithValue(LoggingService()),
      ],
    );
    addTearDown(container.dispose);

    await container.read(targetSearchProvider.notifier).search('   ');

    expect(container.read(targetSearchProvider), const TargetSearchState());
    expect(catalogRead, isFalse);
  });

  test('catalog failure is represented as an error, not no matches', () async {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        loadedDsosProvider.overrideWith(
          (ref) => Future<List<DeepSkyObject>>.error(
            StateError('catalog unreadable'),
          ),
        ),
        loggingServiceProvider.overrideWithValue(LoggingService()),
      ],
    );
    addTearDown(container.dispose);

    await container.read(targetSearchProvider.notifier).search('M42');

    final state = container.read(targetSearchProvider);
    expect(state.results, isEmpty);
    expect(state.isSearching, isFalse);
    expect(state.errorMessage, isNotNull);
  });

  test('clearing search prevents an in-flight result from reappearing',
      () async {
    final catalog = Completer<List<DeepSkyObject>>();
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        loadedDsosProvider.overrideWith((ref) => catalog.future),
        loggingServiceProvider.overrideWithValue(LoggingService()),
      ],
    );
    addTearDown(container.dispose);

    final search = container.read(targetSearchProvider.notifier).search('M42');
    await Future<void>.delayed(Duration.zero);
    container.read(targetSearchProvider.notifier).clear();
    catalog.complete(const [_m42]);
    await search;

    final state = container.read(targetSearchProvider);
    expect(state.query, isEmpty);
    expect(state.results, isEmpty);
    expect(state.errorMessage, isNull);
  });
}
