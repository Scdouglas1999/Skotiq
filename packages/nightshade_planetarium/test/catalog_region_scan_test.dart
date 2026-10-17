import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightshade_planetarium/nightshade_planetarium.dart';

/// Answering a half-degree annotation query must not load the whole catalog.
///
/// GLADE+ is ~22 million rows. The old cone query called `loadAll()` first,
/// which did `File.readAsLines()` and then ran a synchronous parse loop over
/// every row. On the rig that froze the app outright: the loop never yielded,
/// so nothing else on that isolate ever ran again, the working set climbed into
/// the gigabytes, and a core stayed pinned with no log output because the code
/// that logs never got the isolate back. It reproduced on every launch, on the
/// first plate solve that actually succeeded — a failed solve returned before
/// the catalog was ever touched, which is why it looked intermittent.
///
/// These tests hold the two properties that make that impossible: the scan
/// keeps only what the cone asked for, and it does not run on the caller's
/// isolate.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ns-region-scan');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// A GLADE+ CSV: RAJ2000, DEJ2000, Bmag, zhelio(velocity), PGC.
  Future<String> writeGladeCatalog(List<String> rows) async {
    final file = File('${tempDir.path}/glade.csv');
    await file.writeAsString(
      ['RAJ2000,DEJ2000,Bmag,zhelio,PGC', ...rows].join('\n'),
    );
    return file.path;
  }

  group('CatalogRegionFilter', () {
    const filter = CatalogRegionFilter(ra: 10.0, dec: 20.0, radiusDegrees: 1.0);

    test('accepts an object inside the cone', () {
      expect(
        filter.accepts(objRa: 10.2, objDec: 20.2, magnitude: 12.0),
        isTrue,
      );
    });

    test('rejects an object outside the cone', () {
      expect(
        filter.accepts(objRa: 15.0, objDec: 20.0, magnitude: 12.0),
        isFalse,
      );
    });

    test('compresses the RA axis by cos(dec)', () {
      // 1.0 deg of RA at dec 20 spans only ~0.94 deg on the sky, so an object
      // 1.05 deg away in RA is still inside a 1.0 deg cone. Treating RA
      // degrees as sky degrees would wrongly reject it.
      expect(
        filter.accepts(objRa: 11.05, objDec: 20.0, magnitude: 12.0),
        isTrue,
      );
    });

    test('measures across the RA 0h/24h seam', () {
      const seam = CatalogRegionFilter(ra: 0.5, dec: 0.0, radiusDegrees: 1.0);
      // 0.5 deg away, but on the other side of the wrap. A plain subtraction
      // makes this 359.0 deg and drops half the field.
      expect(seam.accepts(objRa: 359.9, objDec: 0.0, magnitude: 10.0), isTrue);
    });

    test('rejects anything fainter than the magnitude cutoff', () {
      const cut = CatalogRegionFilter(
        ra: 10.0,
        dec: 20.0,
        radiusDegrees: 1.0,
        maxMagnitude: 14.0,
      );
      expect(cut.accepts(objRa: 10.0, objDec: 20.0, magnitude: 13.9), isTrue);
      expect(cut.accepts(objRa: 10.0, objDec: 20.0, magnitude: 14.1), isFalse);
    });

    test('treats a missing magnitude as fainter than any cutoff', () {
      const cut = CatalogRegionFilter(
        ra: 10.0,
        dec: 20.0,
        radiusDegrees: 1.0,
        maxMagnitude: 14.0,
      );
      expect(cut.accepts(objRa: 10.0, objDec: 20.0, magnitude: null), isFalse);
    });
  });

  test('GLADE numeric and quoted CSV paths preserve the same fields', () {
    final plain = GladePlusData.fromCsvLine(
      ' 341.8338,58.0635,1.2e1,3000,123 ',
    );
    final quoted = GladePlusData.fromCsvLine(
      '"341.8338","58.0635","1.2e1","3000","123"',
    );
    expect(plain.ra, quoted.ra);
    expect(plain.dec, quoted.dec);
    expect(plain.magnitude, quoted.magnitude);
    expect(plain.redshift, quoted.redshift);
    expect(plain.pgc, quoted.pgc);
  });

  group('GladePlusCatalogLoader.searchNearby', () {
    test('keeps only the rows inside the cone', () async {
      final path = await writeGladeCatalog([
        '10.0,20.0,12.0,3000,1', // centre
        '10.1,20.1,13.0,3000,2', // inside
        '40.0,20.0,13.0,3000,3', // far away in RA
        '10.0,70.0,13.0,3000,4', // far away in Dec
        '200.0,-40.0,13.0,3000,5', // other side of the sky
      ]);

      final found = await GladePlusCatalogLoader(
        path,
      ).searchNearby(ra: 10.0, dec: 20.0, radiusDegrees: 1.0);

      expect(found.map((g) => g.pgc), [1, 2]);
    });

    test('returns the nearest object first', () async {
      final path = await writeGladeCatalog([
        '10.5,20.0,12.0,3000,10',
        '10.1,20.0,12.0,3000,11',
        '10.3,20.0,12.0,3000,12',
      ]);

      final found = await GladePlusCatalogLoader(
        path,
      ).searchNearby(ra: 10.0, dec: 20.0, radiusDegrees: 1.0);

      expect(found.map((g) => g.pgc), [11, 12, 10]);
    });

    test('applies the magnitude cutoff', () async {
      final path = await writeGladeCatalog([
        '10.0,20.0,12.0,3000,20',
        '10.1,20.0,18.0,3000,21',
      ]);

      final found = await GladePlusCatalogLoader(path).searchNearby(
        ra: 10.0,
        dec: 20.0,
        radiusDegrees: 1.0,
        maxMagnitude: 15.0,
      );

      expect(found.map((g) => g.pgc), [20]);
    });

    test('skips the header row rather than parsing it as an object', () async {
      final path = await writeGladeCatalog(['0.0,0.0,12.0,3000,30']);

      final found = await GladePlusCatalogLoader(
        path,
      ).searchNearby(ra: 0.0, dec: 0.0, radiusDegrees: 1.0);

      expect(found.map((g) => g.pgc), [30]);
    });

    test('carries on past a malformed row', () async {
      final path = await writeGladeCatalog([
        '10.0,20.0,12.0,3000,40',
        'not,enough',
        '',
        '10.1,20.0,12.0,3000,41',
      ]);

      final found = await GladePlusCatalogLoader(
        path,
      ).searchNearby(ra: 10.0, dec: 20.0, radiusDegrees: 1.0);

      expect(found.map((g) => g.pgc), [40, 41]);
    });

    test('reports a missing catalog file instead of returning empty', () async {
      await expectLater(
        GladePlusCatalogLoader(
          '${tempDir.path}/absent.csv',
        ).searchNearby(ra: 0.0, dec: 0.0, radiusDegrees: 1.0),
        throwsA(isA<FileSystemException>()),
      );
    });

    test(
      'retains only the cone, not the catalog, when most rows are outside it',
      () async {
        // 5,000 rows scattered across the sky with 3 inside the cone. The old
        // shape held all 5,000 (and, on the rig, 22 million) in memory before
        // filtering; this asserts the answer is proportional to the cone.
        final rows = <String>[];
        for (var i = 0; i < 5000; i++) {
          final ra = (i * 0.07) % 360.0;
          final dec = -80.0 + (i % 160);
          rows.add('$ra,$dec,12.0,3000,${1000 + i}');
        }
        rows.add('30.0,5.0,12.0,3000,1');
        rows.add('30.1,5.0,12.0,3000,2');
        rows.add('30.0,5.1,12.0,3000,3');

        final path = await writeGladeCatalog(rows);
        final found = await GladePlusCatalogLoader(
          path,
        ).searchNearby(ra: 30.0, dec: 5.0, radiusDegrees: 0.5);

        expect(found.map((g) => g.pgc), containsAll(<int>[1, 2, 3]));
        expect(
          found.length,
          lessThan(20),
          reason: 'a 0.5 deg cone must not come back with the catalog',
        );
      },
    );

    test('leaves the calling isolate free to make progress', () async {
      // The freeze was a synchronous parse loop monopolising the UI isolate.
      // A one-shot timer is not enough to catch that — the old code awaited
      // `readAsLines()` first, so a single tick could slip through before the
      // blocking loop began. A PERIODIC timer must keep being serviced for the
      // whole scan, which is only true if the parse is on another isolate.
      final rows = <String>[];
      for (var i = 0; i < 150000; i++) {
        rows.add('${(i * 0.11) % 360.0},${-80.0 + (i % 160)},12.0,3000,$i');
      }
      final path = await writeGladeCatalog(rows);

      var ticks = 0;
      final ticker = Timer.periodic(
        const Duration(milliseconds: 5),
        (_) => ticks++,
      );
      final started = DateTime.now();
      await GladePlusCatalogLoader(
        path,
      ).searchNearby(ra: 12.0, dec: 3.0, radiusDegrees: 0.25);
      final elapsed = DateTime.now().difference(started);
      ticker.cancel();

      expect(
        elapsed.inMilliseconds,
        greaterThan(20),
        reason:
            'the fixture must be big enough for the assertion to mean '
            'something',
      );
      expect(
        ticks,
        greaterThanOrEqualTo(2),
        reason: 'the calling isolate was starved while the catalog was parsed',
      );
    });

    test(
      'truncates a pathological radius instead of growing unbounded',
      () async {
        final rows = <String>[];
        for (var i = 0; i < 400; i++) {
          rows.add('${10.0 + i * 0.001},20.0,12.0,3000,$i');
        }
        final path = await writeGladeCatalog(rows);

        final found = await GladePlusCatalogLoader(path).searchNearby(
          ra: 10.0,
          dec: 20.0,
          radiusDegrees: 180.0,
          maxResults: 50,
        );

        expect(found, hasLength(50));
      },
    );
  });

  group('cached field reuse', () {
    test(
      'a later cone inside the scanned field is served from memory',
      () async {
        final path = await writeGladeCatalog([
          '30.0,5.0,12.0,3000,1',
          '30.05,5.0,13.0,3000,2',
        ]);
        final loader = GladePlusCatalogLoader(path);

        final first = await loader.searchNearby(
          ra: 30.0,
          dec: 5.0,
          radiusDegrees: 0.5,
        );
        expect(first.map((g) => g.pgc), [1, 2]);

        // Delete the file. A second, narrower query can only succeed if it was
        // answered from the cached field rather than by re-reading the catalog.
        await File(path).delete();

        final second = await loader.searchNearby(
          ra: 30.01,
          dec: 5.0,
          radiusDegrees: 0.2,
        );
        expect(second.map((g) => g.pgc), [1, 2]);
      },
    );

    test(
      'a deeper magnitude request is not answered from a shallower cache',
      () async {
        final path = await writeGladeCatalog([
          '30.0,5.0,12.0,3000,1',
          '30.05,5.0,19.0,3000,2',
        ]);
        final loader = GladePlusCatalogLoader(path);

        // The scanned field is magnitude-blind, so the faint row is cached and a
        // deeper cutoff is still answered correctly.
        expect(
          (await loader.searchNearby(
            ra: 30.0,
            dec: 5.0,
            radiusDegrees: 0.5,
            maxMagnitude: 15.0,
          )).map((g) => g.pgc),
          [1],
        );
        expect(
          (await loader.searchNearby(
            ra: 30.0,
            dec: 5.0,
            radiusDegrees: 0.5,
            maxMagnitude: 20.0,
          )).map((g) => g.pgc),
          [1, 2],
        );
      },
    );

    test('a cone outside the scanned field is re-read, not guessed', () async {
      final path = await writeGladeCatalog([
        '30.0,5.0,12.0,3000,1',
        '120.0,-40.0,12.0,3000,2',
      ]);
      final loader = GladePlusCatalogLoader(path);

      await loader.searchNearby(ra: 30.0, dec: 5.0, radiusDegrees: 0.5);
      final elsewhere = await loader.searchNearby(
        ra: 120.0,
        dec: -40.0,
        radiusDegrees: 0.5,
      );

      expect(elsewhere.map((g) => g.pgc), [2]);
    });

    test('clearCache forces the catalog to be read again', () async {
      final path = await writeGladeCatalog(['30.0,5.0,12.0,3000,1']);
      final loader = GladePlusCatalogLoader(path);

      await loader.searchNearby(ra: 30.0, dec: 5.0, radiusDegrees: 0.5);
      loader.clearCache();
      await File(path).delete();

      await expectLater(
        loader.searchNearby(ra: 30.0, dec: 5.0, radiusDegrees: 0.5),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
