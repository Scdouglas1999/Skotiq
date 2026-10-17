import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:skotiq_core/src/services/weather/radar_colormaps.dart';
import 'package:skotiq_core/src/services/weather/radar_tile_decoder.dart';

/// Tests for the radar tile decoder + colormap mapping.
///
/// These pin the colormap → intensity contract with SYNTHETIC in-memory PNG
/// tiles (no network): a tile painted with a colormap anchor colour must decode
/// to that anchor's intensity, transparent pixels to 0, and the downsampled grid
/// must place a painted band in the correct rows.
void main() {
  const decoder = RadarTileDecoder();
  const colormap = RadarColormaps.rainViewerScheme2;

  /// Encodes an [img.Image] as PNG bytes (round-trips through the real codec the
  /// providers use).
  Uint8List encode(img.Image image) => Uint8List.fromList(img.encodePng(image));

  /// A 256×256 RGBA tile filled with a single straight-alpha colour.
  img.Image solidTile(int r, int g, int b, int a) {
    final image = img.Image(width: 256, height: 256, numChannels: 4);
    img.fill(image, color: img.ColorRgba8(r, g, b, a));
    return image;
  }

  group('RadarColormap.intensityForPixel (RainViewer scheme 2)', () {
    test('each anchor colour maps to its pinned intensity', () {
      for (final stop in colormap.stops) {
        final intensity = colormap.intensityForPixel(
          stop.r,
          stop.g,
          stop.b,
          255,
        );
        expect(
          intensity,
          closeTo(stop.intensity, 1e-9),
          reason:
              'anchor (${stop.r},${stop.g},${stop.b}) must map to '
              '${stop.intensity}',
        );
      }
    });

    test('a fully transparent pixel is no-echo (0) regardless of colour', () {
      // Heavy-rain magenta but fully transparent → no precipitation.
      expect(colormap.intensityForPixel(220, 0, 220, 0), 0.0);
    });

    test('a colour far from every anchor is rejected as not-precipitation', () {
      // Mid grey is not on the ramp and is > maxRgbDistance from any anchor.
      expect(colormap.intensityForPixel(128, 128, 128, 255), 0.0);
    });

    test('the heaviest anchor is the maximum intensity (1.0)', () {
      final heaviest = colormap.stops.last;
      expect(heaviest.intensity, 1.0);
      expect(
        colormap.intensityForPixel(heaviest.r, heaviest.g, heaviest.b, 255),
        1.0,
      );
    });
  });

  group('RadarTileDecoder.decodePng', () {
    test('decodes a valid PNG', () {
      final bytes = encode(solidTile(0, 120, 255, 255));
      final image = decoder.decodePng(bytes);
      expect(image, isNotNull);
      expect(image!.width, 256);
    });

    test('returns null (no throw) on garbage bytes', () {
      final image = decoder.decodePng(Uint8List.fromList([1, 2, 3, 4, 5]));
      expect(image, isNull);
    });
  });

  group('buildIntensityGrid (slippy tiles)', () {
    // A single z=7 tile covering a small region; we sample a grid wholly inside
    // it. Tile (x=33, y=48) at z=7 lies over the central US.
    const z = 7;
    const tileX = 33;
    const tileY = 48;

    // Geographic span of that tile (from the inverse slippy transform), shrunk
    // slightly so all sampled cells fall inside the one tile.
    ({double north, double south, double west, double east}) tileBounds() {
      final tl = _tileTopLeftLatLon(tileX, tileY, z);
      final br = _tileTopLeftLatLon(tileX + 1, tileY + 1, z);
      final latPad = (tl.lat - br.lat) * 0.1;
      final lonPad = (br.lon - tl.lon) * 0.1;
      return (
        north: tl.lat - latPad,
        south: br.lat + latPad,
        west: tl.lon + lonPad,
        east: br.lon - lonPad,
      );
    }

    test('a uniformly-painted tile yields a uniform-intensity grid', () {
      final stop = colormap.stops[3]; // moderate green, intensity 0.55
      final tile = DecodedRadarTile(
        z: z,
        x: tileX,
        y: tileY,
        image: solidTile(stop.r, stop.g, stop.b, 255),
      );
      final bounds = tileBounds();

      final grid = decoder.buildIntensityGrid(
        tiles: [tile],
        colormap: colormap,
        north: bounds.north,
        south: bounds.south,
        west: bounds.west,
        east: bounds.east,
        gridRows: 8,
        gridCols: 8,
        z: z,
      );

      expect(grid, isNotNull);
      for (final row in grid!) {
        for (final v in row) {
          expect(v, closeTo(stop.intensity, 1e-9));
        }
      }
    });

    test(
      'a tile with a painted northern half places intensity in top rows',
      () {
        // Top half = heavy rain (magenta, 1.0); bottom half = transparent (0).
        final stop = colormap.stops.last;
        final image = img.Image(width: 256, height: 256, numChannels: 4);
        img.fill(image, color: img.ColorRgba8(0, 0, 0, 0)); // transparent
        img.fillRect(
          image,
          x1: 0,
          y1: 0,
          x2: 255,
          y2: 127,
          color: img.ColorRgba8(stop.r, stop.g, stop.b, 255),
        );

        final tile = DecodedRadarTile(z: z, x: tileX, y: tileY, image: image);
        final bounds = tileBounds();

        final grid = decoder.buildIntensityGrid(
          tiles: [tile],
          colormap: colormap,
          north: bounds.north,
          south: bounds.south,
          west: bounds.west,
          east: bounds.east,
          gridRows: 8,
          gridCols: 8,
          z: z,
        );

        expect(grid, isNotNull);
        // Top rows (north, image top) should be the painted intensity...
        expect(grid![0][0], closeTo(1.0, 1e-9));
        // ...and bottom rows (south) clear.
        expect(grid[7][0], 0.0);
      },
    );

    test('empty tile list returns null (no-data, not a fabricated grid)', () {
      final grid = decoder.buildIntensityGrid(
        tiles: const [],
        colormap: colormap,
        north: 41,
        south: 39,
        west: -91,
        east: -89,
        gridRows: 8,
        gridCols: 8,
        z: z,
      );
      expect(grid, isNull);
    });
  });

  group('buildIntensityGridFromWmsImage (plate-carrée)', () {
    test('NEXRAD heavy-rain image maps to high intensity', () {
      final stop = RadarColormaps.nexradN0q.stops.last; // violet, 1.0
      final image = solidTile(stop.r, stop.g, stop.b, 255);

      final grid = decoder.buildIntensityGridFromWmsImage(
        image: image,
        colormap: RadarColormaps.nexradN0q,
        imageNorth: 42,
        imageSouth: 38,
        imageWest: -92,
        imageEast: -88,
        gridRows: 6,
        gridCols: 6,
      );

      expect(grid, isNotNull);
      expect(grid![0][0], closeTo(1.0, 1e-9));
    });

    test('GOES bright (cold cloud) pixels map high, dark ground maps to 0', () {
      // North half bright (cloud), south half dark (clear ground).
      final image = img.Image(width: 64, height: 64, numChannels: 4);
      img.fillRect(
        image,
        x1: 0,
        y1: 0,
        x2: 63,
        y2: 31,
        color: img.ColorRgba8(255, 255, 255, 255),
      );
      img.fillRect(
        image,
        x1: 0,
        y1: 32,
        x2: 63,
        y2: 63,
        color: img.ColorRgba8(0, 0, 0, 255),
      );

      final grid = decoder.buildIntensityGridFromWmsImage(
        image: image,
        colormap: RadarColormaps.goesInfrared,
        imageNorth: 42,
        imageSouth: 38,
        imageWest: -92,
        imageEast: -88,
        gridRows: 8,
        gridCols: 8,
      );

      expect(grid, isNotNull);
      // North (top) is solid cloud → ~1.0.
      expect(grid![0][0], closeTo(1.0, 1e-9));
      // South (bottom) is clear ground → 0.
      expect(grid[7][0], 0.0);
    });
  });
}

/// Inverse slippy-map transform: top-left (NW) lat/lon of integer tile (x, y).
({double lat, double lon}) _tileTopLeftLatLon(int x, int y, int z) {
  final n = (1 << z).toDouble();
  final lon = x / n * 360.0 - 180.0;
  // atan(sinh(...)) is the Web-Mercator inverse-y latitude function.
  final t = math.pi * (1 - 2 * y / n);
  final sinh = (math.exp(t) - math.exp(-t)) / 2.0;
  final lat = math.atan(sinh) * 180.0 / math.pi;
  return (lat: lat, lon: lon);
}
