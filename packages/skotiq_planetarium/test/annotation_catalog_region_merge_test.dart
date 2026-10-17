import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// `AnnotationCatalog.searchNearby` merges per-region results, not whole sky.
///
/// It used to call `loadAll()`, which merged OpenNGC + HyperLEDA + GLADE+ in
/// full before filtering to the requested cone, and resolved each position
/// collision with `List.indexOf` — an O(n) scan of the growing merged list, so
/// the merge was quadratic in colliding rows on top of being whole-sky.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sk-annotation-merge');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<String> writeGlade(List<String> rows) async {
    final file = File('${tempDir.path}/glade.csv');
    await file.writeAsString(
      ['RAJ2000,DEJ2000,Bmag,zhelio,PGC', ...rows].join('\n'),
    );
    return file.path;
  }

  test('returns only objects inside the requested cone', () async {
    final catalog = AnnotationCatalog(
      gladeLoader: GladePlusCatalogLoader(
        await writeGlade([
          '30.0,5.0,12.0,3000,1',
          '30.1,5.0,13.0,3000,2',
          '120.0,-60.0,11.0,3000,3',
        ]),
      ),
    );

    final found = await catalog.searchNearby(
      ra: 30.0,
      dec: 5.0,
      radiusDegrees: 0.5,
    );

    expect(found.map((o) => o.primaryName), ['PGC 1', 'PGC 2']);
  });

  test('orders the answer brightest first', () async {
    final catalog = AnnotationCatalog(
      gladeLoader: GladePlusCatalogLoader(
        await writeGlade([
          '30.0,5.0,15.0,3000,10',
          '30.05,5.0,11.0,3000,11',
          '30.1,5.0,13.0,3000,12',
        ]),
      ),
    );

    final found = await catalog.searchNearby(
      ra: 30.0,
      dec: 5.0,
      radiusDegrees: 0.5,
    );

    expect(found.map((o) => o.magnitude), [11.0, 13.0, 15.0]);
  });

  test(
    'collapses two catalog rows at the same position into one object',
    () async {
      // Both rows round to the same 0.01 deg dedup key, so the merge must emit a
      // single object rather than two overlapping labels on the same galaxy.
      final catalog = AnnotationCatalog(
        gladeLoader: GladePlusCatalogLoader(
          await writeGlade([
            '30.0,5.0,12.0,3000,20',
            '30.002,5.001,12.5,3000,21',
          ]),
        ),
      );

      final found = await catalog.searchNearby(
        ra: 30.0,
        dec: 5.0,
        radiusDegrees: 0.5,
      );

      expect(found, hasLength(1));
    },
  );

  test('honours the magnitude cutoff', () async {
    final catalog = AnnotationCatalog(
      gladeLoader: GladePlusCatalogLoader(
        await writeGlade(['30.0,5.0,12.0,3000,30', '30.1,5.0,19.0,3000,31']),
      ),
    );

    final found = await catalog.searchNearby(
      ra: 30.0,
      dec: 5.0,
      radiusDegrees: 0.5,
      maxMagnitude: 15.0,
    );

    expect(found.map((o) => o.primaryName), ['PGC 30']);
  });

  test('filters by object type when asked', () async {
    final catalog = AnnotationCatalog(
      gladeLoader: GladePlusCatalogLoader(
        await writeGlade(['30.0,5.0,12.0,3000,40']),
      ),
    );

    expect(
      await catalog.searchNearby(
        ra: 30.0,
        dec: 5.0,
        radiusDegrees: 0.5,
        typeFilter: const {AnnotationObjectType.galaxy},
      ),
      hasLength(1),
    );
    expect(
      await catalog.searchNearby(
        ra: 30.0,
        dec: 5.0,
        radiusDegrees: 0.5,
        typeFilter: const {AnnotationObjectType.nebula},
      ),
      isEmpty,
    );
  });

  test('reports itself unavailable with no loaders wired', () async {
    expect(AnnotationCatalog().isAvailable, isFalse);
  });

  test(
    'merges many colliding rows without a per-collision linear scan',
    () async {
      // 4,000 rows all landing on the same dedup key. Under the old
      // `List.indexOf` merge this is quadratic; it must now complete promptly.
      final rows = <String>[];
      for (var i = 0; i < 4000; i++) {
        rows.add('30.0,5.0,12.0,3000,$i');
      }
      final catalog = AnnotationCatalog(
        gladeLoader: GladePlusCatalogLoader(await writeGlade(rows)),
      );

      final found = await catalog.searchNearby(
        ra: 30.0,
        dec: 5.0,
        radiusDegrees: 0.5,
      );

      expect(found, hasLength(1));
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
}
