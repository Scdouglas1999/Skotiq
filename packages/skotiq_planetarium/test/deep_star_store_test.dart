import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/catalogs/deep_star_store.dart';

void main() {
  final fixtureDir = Directory('test/fixtures/deep_star_tiles');

  group('DeepStarTileStore (synthetic fixture)', () {
    test('fixture exists — regenerate with tools/catalog_prep if missing', () {
      expect(
        fixtureDir.existsSync(),
        isTrue,
        reason:
            'run: python3 tools/catalog_prep/make_deep_star_tiles.py '
            '--synthetic --out test/fixtures/deep_star_tiles',
      );
    });

    test('loads the manifest', () async {
      final store = DeepStarTileStore(directory: fixtureDir.path);
      expect(await store.loadManifest(), isTrue);
      expect(store.manifest, isNotNull);
      expect(store.manifest!.totalStars, greaterThan(0));
    });

    test(
      'queryBrightest returns only in-view, magnitude-filtered stars',
      () async {
        final store = DeepStarTileStore(directory: fixtureDir.path);
        await store.loadManifest();

        const centerRa = 12.0;
        const centerDec = 0.0;
        const fov = 6.0;

        final results = await store.queryBrightest(
          centerRa,
          centerDec,
          fov,
          maxMagnitude: 13.0,
          maxResults: 500,
        );

        expect(results, isNotEmpty);

        // Brightest-first ordering.
        for (var i = 1; i < results.length; i++) {
          expect(results[i - 1].magnitude! <= results[i].magnitude!, isTrue);
        }

        // Every result is within the generous viewport region in Dec.
        for (final s in results) {
          expect((s.coordinates.dec - centerDec).abs(), lessThan(fov));
        }
      },
    );

    test('minMagnitude excludes the HYG-floor hand-off range', () async {
      final store = DeepStarTileStore(directory: fixtureDir.path);
      await store.loadManifest();

      final all = await store.queryBrightest(
        12.0,
        0.0,
        6.0,
        maxMagnitude: 13.0,
        maxResults: 5000,
      );
      final faintOnly = await store.queryBrightest(
        12.0,
        0.0,
        6.0,
        maxMagnitude: 13.0,
        minMagnitude: 12.0,
        maxResults: 5000,
      );

      expect(faintOnly.length, lessThanOrEqualTo(all.length));
      for (final s in faintOnly) {
        expect(s.magnitude! > 12.0, isTrue);
      }
    });

    test('caps results to maxResults', () async {
      final store = DeepStarTileStore(directory: fixtureDir.path);
      await store.loadManifest();
      final results = await store.queryBrightest(
        12.0,
        0.0,
        6.0,
        maxMagnitude: 13.0,
        maxResults: 5,
      );
      expect(results.length, lessThanOrEqualTo(5));
    });

    test('LRU keeps decoded tiles bounded', () async {
      final store = DeepStarTileStore(
        directory: fixtureDir.path,
        maxCachedTiles: 4,
      );
      await store.loadManifest();
      // Several queries across the sky touch many tiles.
      for (var ra = 0.0; ra < 24.0; ra += 3.0) {
        await store.queryBrightest(
          ra,
          0.0,
          4.0,
          maxMagnitude: 13.0,
          maxResults: 50,
        );
      }
      expect(store.cachedTileCount, lessThanOrEqualTo(4));
    });

    test('returns empty when no manifest is installed', () async {
      final empty = await Directory.systemTemp.createTemp('sk_deep_empty_');
      try {
        final store = DeepStarTileStore(directory: empty.path);
        expect(await store.loadManifest(), isFalse);
        final results = await store.queryBrightest(
          12.0,
          0.0,
          4.0,
          maxMagnitude: 13.0,
          maxResults: 50,
        );
        expect(results, isEmpty);
      } finally {
        await empty.delete(recursive: true);
      }
    });
  });
}
