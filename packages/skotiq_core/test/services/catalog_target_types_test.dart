// The rig's 2026-11-16 night framed "Flaming Star Nebula" by name through
// the API, and the filter recipe said it "has no object type in the
// catalog", though the catalog lists IC 405 with that common name.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/services.dart';

DbTarget _target(
  String name, {
  double ra = 5.27,
  double dec = 34.40,
  String? type,
}) => DbTarget(
  id: 1,
  name: name,
  objectType: type,
  ra: ra,
  dec: dec,
  minAltitude: 30,
  priority: 5,
  totalPlannedSubs: 0,
  capturedSubs: 0,
  totalIntegrationSecs: 0,
  goalIntegrationSecs: 0,
  createdAt: DateTime(2026, 11, 16),
  updatedAt: DateTime(2026, 11, 16),
  isFavorite: false,
);

void main() {
  final catalog = DsoDesignations.of(const [
    DeepSkyObject(
      id: 'IC0405',
      name: 'IC0405',
      coordinates: CelestialCoordinate(ra: 5.27486, dec: 34.35617),
      type: DsoType.nebula,
      sizeArcMin: 50,
      catalogIds: ['C 031', 'LBN 795'],
      commonNames: 'Flaming Star Nebula',
    ),
  ]);

  test('a target saved by its common name reads the catalog type', () {
    expect(
      withCatalogObjectType(_target('Flaming Star Nebula'), catalog).objectType,
      DsoType.nebula.displayName,
    );
  });

  test('an untyped position inside an object reads its type', () {
    expect(
      withCatalogObjectType(_target('Custom Location'), catalog).objectType,
      DsoType.nebula.displayName,
    );
  });

  test('a typed position the user entered keeps its own type', () {
    expect(
      withCatalogObjectType(
        _target('My field', type: 'Galaxy'),
        catalog,
      ).objectType,
      'Galaxy',
    );
  });

  test('a position outside every object stays untyped', () {
    expect(
      withCatalogObjectType(
        _target('Custom Location', ra: 6.5),
        catalog,
      ).objectType,
      isNull,
    );
  });
}
