import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:test/test.dart';

DeepSkyObject _object(
  String id, {
  List<String> catalogIds = const [],
  DsoType type = DsoType.nebula,
  double? magnitude,
}) => DeepSkyObject(
  id: id,
  name: id,
  coordinates: const CelestialCoordinate(ra: 3.48, dec: 31.37),
  type: type,
  magnitude: magnitude,
  catalogIds: catalogIds,
);

void main() {
  final ngc1333 = _object(
    'NGC1333',
    catalogIds: ['LBN 741', 'MWSC 0279'],
    type: DsoType.clusterWithReflectionNebula,
    magnitude: 10.9,
  );
  final m42 = _object(
    'NGC1976',
    catalogIds: ['M42', 'LBN 974'],
    type: DsoType.clusterWithEmissionNebula,
    magnitude: 4.0,
  );
  final catalog = DsoDesignations.of([m42, ngc1333]);

  test('every way of writing a designation names the object', () {
    for (final text in ['NGC1333', 'NGC 1333', 'ngc1333', 'LBN 741']) {
      expect(catalog.named(text), same(ngc1333), reason: text);
    }
    expect(catalog.named('Messier 42'), same(m42));
    expect(catalog.named('Orion Nebula'), isNull);
    expect(catalog.named(''), isNull);
  });

  test('a target is the object its catalog id names, else its name', () {
    expect(catalog.ofTarget(catalogId: 'LBN 741', name: 'M42'), same(ngc1333));
    expect(catalog.ofTarget(catalogId: 'Sh2-999', name: 'M42'), same(m42));
    expect(catalog.ofTarget(name: 'My comet field'), isNull);
  });

  test('a designation two objects list names the brighter', () {
    final faint = _object('IC9999', catalogIds: ['LBN 974'], magnitude: 13);
    expect(DsoDesignations.of([m42, faint]).named('LBN 974'), same(m42));
  });

  test('objects the catalog does not carry come from the supplement', () {
    expect(catalog.named('Sh2-155')?.type, DsoType.hiiRegion);
  });
}
