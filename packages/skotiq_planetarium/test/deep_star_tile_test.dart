import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/catalogs/deep_star_tile.dart';

void main() {
  group('NSDT tile encode/decode round-trip', () {
    test('records survive a round-trip within quantization tolerance', () {
      final tile = DeepStarTile(
        raBand: 7,
        decBand: 12,
        records: const [
          DeepStarRecord(
            raHours: 12.345678,
            decDeg: -5.123456,
            magnitude: 12.4,
            bv: 0.65,
          ),
          DeepStarRecord(raHours: 0.0, decDeg: 89.9, magnitude: 11.8, bv: -0.1),
          DeepStarRecord(
            raHours: 23.999999,
            decDeg: -89.9,
            magnitude: 12.9,
            bv: null,
          ),
        ],
      );

      final decoded = DeepStarTile.decode(tile.encode());

      expect(decoded.raBand, 7);
      expect(decoded.decBand, 12);
      expect(decoded.records.length, 3);

      // Encoder sorts brightest-first, so order is by magnitude.
      final mags = decoded.records.map((r) => r.magnitude).toList();
      expect(mags, [11.8, 12.4, 12.9]);

      // Find the round-tripped record for the high-precision input.
      final r = decoded.records.firstWhere(
        (x) => (x.magnitude - 12.4).abs() < 1e-6,
      );
      expect(r.raHours, closeTo(12.345678, 1e-6));
      expect(r.decDeg, closeTo(-5.123456, 1e-6));
      expect(r.bv, closeTo(0.65, 1e-3));

      // Unknown B-V stays null after the sentinel round-trips.
      final noColor = decoded.records.firstWhere(
        (x) => (x.magnitude - 12.9).abs() < 1e-6,
      );
      expect(noColor.bv, isNull);
    });

    test('empty tile round-trips', () {
      final tile = DeepStarTile(raBand: 0, decBand: 0, records: const []);
      final decoded = DeepStarTile.decode(tile.encode());
      expect(decoded.records, isEmpty);
      expect(decoded.encode().length, DeepStarTile.headerBytes);
    });

    test('rejects bad magic', () {
      final bytes = Uint8List(DeepStarTile.headerBytes);
      expect(() => DeepStarTile.decode(bytes), throwsFormatException);
    });

    test('rejects truncated payload', () {
      final good = DeepStarTile(
        raBand: 1,
        decBand: 1,
        records: const [DeepStarRecord(raHours: 1, decDeg: 1, magnitude: 12)],
      ).encode();
      final truncated = good.sublist(0, good.length - 3);
      expect(() => DeepStarTile.decode(truncated), throwsFormatException);
    });

    test('toStars maps B-V to a spectral letter and emits empty labels', () {
      final tile = DeepStarTile(
        raBand: 2,
        decBand: 3,
        records: const [
          DeepStarRecord(raHours: 6, decDeg: 10, magnitude: 12, bv: 1.6),
        ],
      );
      final star = tile.toStars().single;
      expect(star.name, isEmpty);
      expect(star.spectralType, 'M'); // red star
      expect(star.id, 'DEEP_2_3_0');
    });
  });

  group('DeepStarTileScheme culling', () {
    test('band geometry matches the spatial index cells', () {
      expect(DeepStarTileScheme.raBands, 24);
      expect(DeepStarTileScheme.decBands, 18);
      expect(DeepStarTileScheme.raBandOf(0.0), 0);
      expect(DeepStarTileScheme.raBandOf(23.99), 23);
      expect(DeepStarTileScheme.decBandOf(-90), 0);
      expect(DeepStarTileScheme.decBandOf(89.9), 17);
      // RA wraps.
      expect(
        DeepStarTileScheme.raBandOf(24.5),
        DeepStarTileScheme.raBandOf(0.5),
      );
    });

    test('narrow viewport selects only a handful of tiles', () {
      final tiles = DeepStarTileScheme.tilesForViewport(12.0, 0.0, 4.0);
      // A 4-deg FOV near the equator should touch only a couple of cells.
      expect(tiles, isNotEmpty);
      expect(tiles.length, lessThan(8));
      // All selected tiles are around RA band for 12h (band 12) and Dec band
      // for 0 deg (band 9).
      for (final (ra, dec) in tiles) {
        expect((ra - 12).abs() <= 1 || (ra - 12).abs() >= 23, isTrue);
        expect((dec - 9).abs() <= 1, isTrue);
      }
    });

    test('wide near-pole viewport wraps all RA bands', () {
      final tiles = DeepStarTileScheme.tilesForViewport(6.0, 88.0, 6.0);
      final raBandsSeen = tiles.map((t) => t.$1).toSet();
      // Near the pole the RA window widens to the whole sky.
      expect(raBandsSeen.length, DeepStarTileScheme.raBands);
    });

    test('RA wraparound across 0h selects bands on both sides', () {
      final tiles = DeepStarTileScheme.tilesForViewport(23.8, 0.0, 8.0);
      final raBandsSeen = tiles.map((t) => t.$1).toSet();
      expect(raBandsSeen.any((b) => b >= 22), isTrue);
      expect(raBandsSeen.any((b) => b == 0), isTrue);
    });
  });

  group('DeepStarManifest JSON', () {
    test('round-trips through JSON', () {
      const manifest = DeepStarManifest(
        name: 'Test tier',
        source: 'unit test',
        magnitudeFloor: 11.5,
        magnitudeLimit: 13.0,
        tiles: [
          DeepStarManifestTile(
            raBand: 1,
            decBand: 2,
            file: 'tile_r01_d02.nsdt',
            sizeBytes: 100,
            sha256: 'abc',
            starCount: 7,
          ),
        ],
      );
      final decoded = DeepStarManifest.decodeJson(manifest.encodeJson());
      expect(decoded.name, 'Test tier');
      expect(decoded.tiles.single.file, 'tile_r01_d02.nsdt');
      expect(decoded.totalStars, 7);
    });

    test('rejects a foreign manifest', () {
      expect(
        () => DeepStarManifest.decodeJson('{"format":"something-else"}'),
        throwsFormatException,
      );
    });
  });
}
