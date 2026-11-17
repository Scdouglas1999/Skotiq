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

  group('common names and positions', () {
    // IC 405 as OpenNGC lists it: 50' x 30', "Flaming Star Nebula".
    const ic405 = DeepSkyObject(
      id: 'IC0405',
      name: 'IC0405',
      coordinates: CelestialCoordinate(ra: 5.27486, dec: 34.35617),
      type: DsoType.nebula,
      magnitude: 10.0,
      sizeArcMin: 50,
      minorAxisArcMin: 30,
      catalogIds: ['C 031', 'LBN 795'],
      commonNames: 'Flaming Star Nebula',
    );
    // A small object inside IC 405's extent.
    const inner = DeepSkyObject(
      id: 'IC9998',
      name: 'IC9998',
      coordinates: CelestialCoordinate(ra: 5.2800, dec: 34.20),
      type: DsoType.openCluster,
      magnitude: 12,
      sizeArcMin: 2,
    );
    // An object that shares a designation-style common name with nothing.
    const namedLikeDesignation = DeepSkyObject(
      id: 'NGC9999',
      name: 'NGC9999',
      coordinates: CelestialCoordinate(ra: 12, dec: 10),
      type: DsoType.galaxy,
      sizeArcMin: 1,
      commonNames: 'IC405',
    );
    final sky = DsoDesignations.of([ic405, inner, namedLikeDesignation]);

    test('a common name from the catalog names its object', () {
      for (final text in [
        'Flaming Star Nebula',
        'flaming star nebula',
        'Flaming-Star Nebula',
      ]) {
        expect(sky.named(text), same(ic405), reason: text);
      }
    });

    test('a designation wins over another object\'s common name', () {
      expect(sky.named('IC 405'), same(ic405));
    });

    test('a target no name identifies is the object its position is in', () {
      expect(
        sky.ofTarget(
          name: 'My Auriga field',
          raHours: 5.2700,
          decDegrees: 34.50,
        ),
        same(ic405),
      );
    });

    test('of nested objects the position is the one it sits most centrally '
        'in', () {
      expect(
        sky.ofTarget(name: 'Custom', raHours: 5.2800, decDegrees: 34.20),
        same(inner),
      );
    });

    test('a position outside every object\'s size is none', () {
      expect(
        sky.ofTarget(name: 'Custom', raHours: 5.40, decDegrees: 34.36),
        isNull,
      );
      expect(sky.ofTarget(name: 'Custom'), isNull);
    });

    test('a name match wins over the position', () {
      expect(
        sky.ofTarget(name: 'NGC9999', raHours: 5.2749, decDegrees: 34.356),
        same(namedLikeDesignation),
      );
    });
  });

  test('objects the catalog does not carry come from the supplement', () {
    expect(catalog.named('Sh2-155')?.type, DsoType.hiiRegion);
  });
}
