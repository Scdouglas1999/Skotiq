import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// A single anchor in a radar reflectivity colormap: the RGB colour a provider
/// paints for a given normalised intensity (0..1, where 0 is the lightest
/// precipitation step and 1 the heaviest).
class RadarColorStop {
  const RadarColorStop({
    required this.r,
    required this.g,
    required this.b,
    required this.intensity,
  });

  /// Red channel of the colormap colour (0..255).
  final int r;

  /// Green channel of the colormap colour (0..255).
  final int g;

  /// Blue channel of the colormap colour (0..255).
  final int b;

  /// Normalised reflectivity this colour represents (0..1).
  final double intensity;
}

/// Converts a single RGBA pixel to a normalised 0..1 radar/cloud intensity.
///
/// Different providers encode intensity differently (a reflectivity colour ramp
/// for precipitation radar, a grayscale brightness-temperature ramp for
/// infrared satellite), so the per-pixel mapping is pluggable.
abstract class IntensityColormap {
  /// Diagnostic name.
  String get name;

  /// Maps one straight-alpha RGBA pixel to a 0..1 intensity.
  double intensityForPixel(int r, int g, int b, int a);
}

/// Maps a provider's radar reflectivity colormap to a 0..1 intensity per pixel
/// and downsamples a decoded tile mosaic into a fixed grid for cloud-motion
/// analysis.
///
/// The colormap is expressed as a list of [RadarColorStop] anchors. Each opaque
/// pixel is matched to the nearest anchor in RGB space and assigned that
/// anchor's intensity; the match is rejected (intensity 0) when the pixel is too
/// far from every anchor to be a colormap colour (e.g. an anti-aliased boundary
/// pixel or a basemap artefact), so only genuine precipitation paint counts.
/// Fully- or near-transparent pixels are intensity 0 (no echo).
class RadarColormap implements IntensityColormap {
  const RadarColormap({
    required this.name,
    required this.stops,
    this.alphaThreshold = 16,
    this.maxRgbDistance = 64.0,
  });

  /// Human-readable name of the colormap (for diagnostics/tests).
  @override
  final String name;

  /// Reflectivity anchors, lightest→heaviest.
  final List<RadarColorStop> stops;

  /// Pixels with alpha at or below this value are treated as no-echo (0). Radar
  /// overlays paint precipitation opaque over a transparent background.
  final int alphaThreshold;

  /// Maximum Euclidean RGB distance (0..441.7) for a pixel to be accepted as a
  /// colormap colour. Beyond this the pixel is not precipitation paint and maps
  /// to intensity 0 rather than being snapped to a distant anchor.
  final double maxRgbDistance;

  /// Maps one straight-alpha RGBA pixel to a 0..1 intensity.
  @override
  double intensityForPixel(int r, int g, int b, int a) {
    if (a <= alphaThreshold) {
      return 0.0;
    }

    double bestDistSq = double.infinity;
    double bestIntensity = 0.0;
    for (final stop in stops) {
      final dr = (r - stop.r).toDouble();
      final dg = (g - stop.g).toDouble();
      final db = (b - stop.b).toDouble();
      final distSq = dr * dr + dg * dg + db * db;
      if (distSq < bestDistSq) {
        bestDistSq = distSq;
        bestIntensity = stop.intensity;
      }
    }

    if (bestDistSq > maxRgbDistance * maxRgbDistance) {
      // Not a colormap colour — not precipitation.
      return 0.0;
    }

    return bestIntensity;
  }
}

/// Maps a grayscale infrared brightness ramp to a 0..1 cloud intensity.
///
/// GOES infrared imagery encodes cloud-top temperature as luminance: cold (high,
/// thick) cloud tops are painted bright, warm (clear-ground) areas dark. The
/// per-pixel luminance, scaled between [darkLuminance] (treated as clear, 0) and
/// [brightLuminance] (treated as solid cloud, 1), is therefore a real per-cell
/// cloud field — exactly the spatial structure the analyzer tracks. Pixels below
/// the alpha threshold (transparent margins) are clear.
class LuminanceColormap implements IntensityColormap {
  const LuminanceColormap({
    required this.name,
    this.darkLuminance = 40,
    this.brightLuminance = 230,
    this.alphaThreshold = 16,
  });

  @override
  final String name;

  /// Luminance (0..255) at or below which a pixel is treated as clear sky (0).
  final int darkLuminance;

  /// Luminance (0..255) at or above which a pixel is treated as solid cloud (1).
  final int brightLuminance;

  /// Pixels with alpha at or below this value are treated as clear (0).
  final int alphaThreshold;

  @override
  double intensityForPixel(int r, int g, int b, int a) {
    if (a <= alphaThreshold) {
      return 0.0;
    }

    // ITU-R BT.601 luma.
    final luma = 0.299 * r + 0.587 * g + 0.114 * b;
    if (brightLuminance <= darkLuminance) {
      return 0.0;
    }
    final t = (luma - darkLuminance) / (brightLuminance - darkLuminance);
    return t.clamp(0.0, 1.0);
  }
}

/// One decoded radar tile placed in a mosaic: its pixels plus the Web-Mercator
/// XYZ tile coordinate that fixes its position in the world.
class DecodedRadarTile {
  DecodedRadarTile({
    required this.z,
    required this.x,
    required this.y,
    required this.image,
  });

  /// Slippy-map zoom level.
  final int z;

  /// Slippy-map tile column.
  final int x;

  /// Slippy-map tile row.
  final int y;

  /// Decoded tile image (RGBA).
  final img.Image image;
}

/// Decodes radar tiles and resamples them into a per-cell intensity grid that
/// the cloud-motion analyzer can track through time.
///
/// All maths is pure (no I/O), so it is fully unit-testable with synthetic
/// in-memory PNG tiles.
class RadarTileDecoder {
  const RadarTileDecoder();

  /// Decodes PNG [bytes] into an [img.Image], or null when the bytes are not a
  /// decodable image. Never throws on malformed input — callers treat null as a
  /// decode failure and emit an honest no-data frame.
  img.Image? decodePng(Uint8List bytes) {
    try {
      return img.decodePng(bytes);
    } catch (_) {
      return null;
    }
  }

  /// Converts a (lat, lon) point to fractional slippy-map tile coordinates at
  /// [z]. The integer parts are the tile x/y; the fractional parts are the
  /// pixel offset within that tile.
  static ({double x, double y}) latLonToTileXY(double lat, double lon, int z) {
    final n = math.pow(2, z).toDouble();
    final x = (lon + 180.0) / 360.0 * n;
    final latRad = lat * math.pi / 180.0;
    final y =
        (1.0 - math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi) /
        2.0 *
        n;
    return (x: x, y: y);
  }

  /// Builds a `gridRows × gridCols` intensity grid over the geographic
  /// rectangle [north]/[south]/[west]/[east] by sampling the decoded [tiles]
  /// through [colormap].
  ///
  /// Rows run NORTH→SOUTH, columns WEST→EAST (matching
  /// [RadarFrame.intensityGrid]). Each cell is sampled at its geographic centre:
  /// the matching tile is located by Web-Mercator XYZ maths, the pixel within it
  /// read, and the colormap applied. Cells whose covering tile is absent from
  /// [tiles] are left at 0.0 (no data for that cell).
  ///
  /// Returns null when [tiles] is empty (nothing decoded) so the caller can emit
  /// a no-data frame instead of a fabricated all-zero grid.
  List<List<double>>? buildIntensityGrid({
    required List<DecodedRadarTile> tiles,
    required IntensityColormap colormap,
    required double north,
    required double south,
    required double west,
    required double east,
    required int gridRows,
    required int gridCols,
    required int z,
  }) {
    if (tiles.isEmpty || gridRows <= 0 || gridCols <= 0) {
      return null;
    }

    // Index tiles by (x, y) for O(1) lookup during sampling.
    final tileIndex = <int, DecodedRadarTile>{};
    for (final tile in tiles) {
      tileIndex[_tileKey(tile.x, tile.y)] = tile;
    }

    final grid = List<List<double>>.generate(
      gridRows,
      (_) => List<double>.filled(gridCols, 0.0),
      growable: false,
    );

    for (int row = 0; row < gridRows; row++) {
      // Cell-centre latitude, north (row 0) → south.
      final latFrac = (row + 0.5) / gridRows;
      final lat = north - latFrac * (north - south);

      for (int col = 0; col < gridCols; col++) {
        // Cell-centre longitude, west (col 0) → east.
        final lonFrac = (col + 0.5) / gridCols;
        final lon = west + lonFrac * (east - west);

        final tileXY = latLonToTileXY(lat, lon, z);
        final tileX = tileXY.x.floor();
        final tileY = tileXY.y.floor();

        final tile = tileIndex[_tileKey(tileX, tileY)];
        if (tile == null) {
          continue; // No tile covers this cell — leave at 0.0.
        }

        final image = tile.image;
        final px = ((tileXY.x - tileX) * image.width).floor().clamp(
          0,
          image.width - 1,
        );
        final py = ((tileXY.y - tileY) * image.height).floor().clamp(
          0,
          image.height - 1,
        );

        final pixel = image.getPixel(px, py);
        grid[row][col] = colormap.intensityForPixel(
          pixel.r.toInt(),
          pixel.g.toInt(),
          pixel.b.toInt(),
          pixel.a.toInt(),
        );
      }
    }

    return grid;
  }

  /// Builds a `gridRows × gridCols` intensity grid from a single WMS GetMap
  /// [image] requested in a plate-carrée (EPSG:4326) projection over
  /// [imageNorth]/[imageSouth]/[imageWest]/[imageEast]. In that projection pixel
  /// position maps linearly to lon/lat, so each grid cell's centre samples one
  /// pixel directly. [colormap] converts the pixel colour to intensity.
  ///
  /// Rows run NORTH→SOUTH, columns WEST→EAST. Returns null when the image has no
  /// pixels so the caller can emit a no-data frame.
  List<List<double>>? buildIntensityGridFromWmsImage({
    required img.Image image,
    required IntensityColormap colormap,
    required double imageNorth,
    required double imageSouth,
    required double imageWest,
    required double imageEast,
    required int gridRows,
    required int gridCols,
  }) {
    if (image.width <= 0 ||
        image.height <= 0 ||
        gridRows <= 0 ||
        gridCols <= 0) {
      return null;
    }

    final grid = List<List<double>>.generate(
      gridRows,
      (_) => List<double>.filled(gridCols, 0.0),
      growable: false,
    );

    for (int row = 0; row < gridRows; row++) {
      // Row 0 = north edge → image top (py = 0).
      final vFrac = (row + 0.5) / gridRows;
      final py = (vFrac * image.height).floor().clamp(0, image.height - 1);

      for (int col = 0; col < gridCols; col++) {
        // Col 0 = west edge → image left (px = 0).
        final uFrac = (col + 0.5) / gridCols;
        final px = (uFrac * image.width).floor().clamp(0, image.width - 1);

        final pixel = image.getPixel(px, py);
        grid[row][col] = colormap.intensityForPixel(
          pixel.r.toInt(),
          pixel.g.toInt(),
          pixel.b.toInt(),
          pixel.a.toInt(),
        );
      }
    }

    return grid;
  }

  /// Returns the inclusive range of slippy-map tile coordinates covering the
  /// geographic rectangle at zoom [z]. Used to know which tiles to fetch.
  static ({int minX, int maxX, int minY, int maxY}) tileRangeForBounds({
    required double north,
    required double south,
    required double west,
    required double east,
    required int z,
  }) {
    final topLeft = latLonToTileXY(north, west, z);
    final bottomRight = latLonToTileXY(south, east, z);

    final n = (math.pow(2, z) - 1).toInt();
    final minX = topLeft.x.floor().clamp(0, n);
    final maxX = bottomRight.x.floor().clamp(0, n);
    final minY = topLeft.y.floor().clamp(0, n);
    final maxY = bottomRight.y.floor().clamp(0, n);

    return (minX: minX, maxX: maxX, minY: minY, maxY: maxY);
  }

  static int _tileKey(int x, int y) => (x << 20) ^ y;
}
