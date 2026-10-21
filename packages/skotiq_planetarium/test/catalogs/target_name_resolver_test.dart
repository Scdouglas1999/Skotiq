import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// Real OpenNGC rows for the objects under test, plus one synthetic row
/// (NGC9998) whose cross-identifiers contain "M42" as a substring, the shape of
/// the SIMBAD objects ("Cl* NGC 2516 HTR M42", "[SSP2021] M42") that the old
/// substring search returned for "M42".
const _fixture = 'test/fixtures/target_search_ngc.csv';

void main() {
  late List<DeepSkyObject> catalog;

  setUpAll(() async {
    catalog = await OpenNgcDsoCatalog(catalogPath: _fixture).loadObjects();
    expect(catalog, isNotEmpty);
  });

  group('CatalogDesignation.parse', () {
    const cases = <String, String?>{
      'M42': 'm42',
      'M 42': 'm42',
      'm42': 'm42',
      'Messier 42': 'm42',
      'M042': 'm42',
      'NGC891': 'ngc891',
      'ngc 891': 'ngc891',
      'NGC0891': 'ngc891',
      'IC1805': 'ic1805',
      'IC 1805': 'ic1805',
      'Sh2-129': 'sh2129',
      'SH 2-129': 'sh2129',
      'sh2 129': 'sh2129',
      'Sharpless 129': 'sh2129',
      'Caldwell 49': 'c49',
      'C 049': 'c49',
      'B33': 'b33',
      'Barnard 33': 'b33',
      'LDN 1622': 'ldn1622',
      'LBN 974': 'lbn974',
      'Abell 39': 'abell39',
      'Arp 273': 'arp273',
      'Mel 22': 'mel22',
      'Orion Nebula': null,
      'Pleiades': null,
      '2MASX J02223290+4220539': null,
      'Cl* NGC 2516 HTR M42': null,
      '[SSP2021] M42': null,
    };
    for (final entry in cases.entries) {
      test('"${entry.key}" -> ${entry.value}', () {
        expect(CatalogDesignation.parse(entry.key)?.key, entry.value);
      });
    }
  });

  group('TargetNameResolver: Enter selects the named object', () {
    // query -> (catalog id that must be selected, RA hours, Dec degrees)
    const cases = <String, (String, double, double)>{
      'M42': ('NGC1976', 5.588, -5.390),
      'M 42': ('NGC1976', 5.588, -5.390),
      'm42': ('NGC1976', 5.588, -5.390),
      'Messier 42': ('NGC1976', 5.588, -5.390),
      'Orion Nebula': ('NGC1976', 5.588, -5.390),
      'orion nebula': ('NGC1976', 5.588, -5.390),
      'NGC 1976': ('NGC1976', 5.588, -5.390),
      'M31': ('NGC224', 0.712, 41.269),
      'Andromeda': ('NGC224', 0.712, 41.269),
      'Andromeda Galaxy': ('NGC224', 0.712, 41.269),
      'NGC891': ('NGC891', 2.376, 42.349),
      'NGC 891': ('NGC891', 2.376, 42.349),
      'ngc 891': ('NGC891', 2.376, 42.349),
      'IC 1805': ('IC1805', 2.545, 61.457),
      'IC1805': ('IC1805', 2.545, 61.457),
      'Heart Nebula': ('IC1805', 2.545, 61.457),
      'Pleiades': ('M45', 3.773, 24.114),
      'M45': ('M45', 3.773, 24.114),
      'Caldwell 49': ('NGC2238', 6.511, 5.013),
      'C49': ('NGC2238', 6.511, 5.013),
      'M102': ('NGC5866', 15.108, 55.763),
      'Double Cluster': ('C14', 2.344, 57.141),
    };
    for (final entry in cases.entries) {
      test('"${entry.key}" -> ${entry.value.$1}', () {
        final ranked = TargetNameResolver.rank(entry.key, catalog);
        final decision = TargetNameResolver.decide(ranked);
        expect(decision, isA<SelectTarget>());
        final object = (decision as SelectTarget).object;
        expect(object.id, entry.value.$1);
        expect(object.coordinates.ra, closeTo(entry.value.$2, 0.002));
        expect(object.coordinates.dec, closeTo(entry.value.$3, 0.002));
        // The selected object also heads the list a click would pick from.
        expect(ranked.first.object.id, entry.value.$1);
      });
    }
  });

  test('"M42" never resolves to an identifier that merely contains M42', () {
    final ranked = TargetNameResolver.rank('M42', catalog);
    final trap = ranked.where((r) => r.object.id == 'NGC9998').single;
    expect(trap.quality, TargetMatchQuality.partial);
    expect(ranked.first.object.id, 'NGC1976');
    expect(ranked.first.quality, TargetMatchQuality.designation);
    // The trap is brighter (3.8 vs 4.0), so magnitude order alone would have
    // put it first.
    expect(trap.object.magnitude! < ranked.first.object.magnitude!, isTrue);
  });

  test('a designation prefix ("M4" of M42, M43) is never an exact match', () {
    final ranked = TargetNameResolver.rank('M4', catalog);
    // M4 itself is not in the fixture; only prefixes, so Enter goes online.
    expect(ranked.every((r) => !r.quality.isExact), isTrue);
    expect(TargetNameResolver.decide(ranked), isA<ResolveTargetOnline>());
  });

  test('designations the local catalog lacks go to the online resolver', () {
    for (final query in ['Sh2-129', 'SH 2-129', 'B33', 'LDN 1622']) {
      final decision = TargetNameResolver.decide(
        TargetNameResolver.rank(query, catalog),
      );
      expect(decision, isA<ResolveTargetOnline>(), reason: query);
    }
  });

  test('a name shared by two objects shows the list instead of guessing', () {
    // OpenNGC calls IC 434 the "Flame Nebula" as well as NGC 2024.
    final decision = TargetNameResolver.decide(
      TargetNameResolver.rank('Flame Nebula', catalog),
    );
    expect(decision, isA<ChooseTarget>());
    final ids = (decision as ChooseTarget).candidates.map((c) => c.object.id);
    expect(ids, containsAll(['IC434', 'NGC2024']));
  });

  test('the limit applies after ranking, not before', () {
    final ranked = TargetNameResolver.rank('M42', catalog, limit: 1);
    expect(ranked.single.object.id, 'NGC1976');
  });
}
