// Best tonight lists each object once. A run saves its target by name ("M1"),
// and the rig's list then showed both "M1" and "NGC1952 · Supernova Remnant".
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';

DbTarget _target(int id, String name, {String? catalogId, String? type}) =>
    DbTarget(
      id: id,
      name: name,
      catalogId: catalogId,
      objectType: type,
      ra: 5.575,
      dec: 22.01,
      minAltitude: 30,
      priority: 5,
      totalPlannedSubs: 0,
      capturedSubs: 12,
      totalIntegrationSecs: 360,
      goalIntegrationSecs: 0,
      createdAt: DateTime(2026, 11, 15),
      updatedAt: DateTime(2026, 11, 15),
      isFavorite: false,
    );

void main() {
  final crab = _target(
    -1,
    'NGC1952',
    catalogId: 'NGC1952',
    type: 'Supernova Remnant',
  );
  final m31 = _target(-2, 'NGC224', catalogId: 'NGC224', type: 'Galaxy');
  final designations = DsoDesignations.of(const [
    DeepSkyObject(
      id: 'NGC1952',
      name: 'NGC1952',
      coordinates: CelestialCoordinate(ra: 5.575, dec: 22.01),
      type: DsoType.supernova,
      catalogIds: ['M1'],
    ),
    DeepSkyObject(
      id: 'NGC224',
      name: 'NGC224',
      coordinates: CelestialCoordinate(ra: 0.712, dec: 41.27),
      type: DsoType.galaxy,
      catalogIds: ['M31'],
    ),
  ]);

  test('a target saved by its Messier name is its catalog object', () {
    final joined = joinUserAndCatalogTargets(
      [_target(7, 'M1', type: 'Nebula')],
      [crab, m31],
      designations,
    );

    expect(joined.map((t) => t.name), ['M1', 'NGC224']);
    final m1 = joined.first;
    expect(m1.id, 7, reason: 'the user row keeps its progress');
    expect(m1.capturedSubs, 12);
    expect(m1.catalogId, 'NGC1952');
    expect(m1.objectType, 'Supernova Remnant', reason: "the catalog's type");
  });

  test('a catalog id in another catalog matches too', () {
    final joined = joinUserAndCatalogTargets(
      [_target(8, 'Andromeda', catalogId: 'M 31')],
      [crab, m31],
      designations,
    );
    expect(joined.map((t) => t.id), [8, -1]);
  });

  test('a target that names no catalog object stays as it is', () {
    final mine = _target(9, 'My comet field');
    final joined = joinUserAndCatalogTargets([mine], [crab], designations);
    expect(joined, [mine, crab]);
  });
}
