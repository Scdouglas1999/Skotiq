import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import '../../../models/weather/weather_models.dart';
import '../radar_colormaps.dart';
import '../radar_provider.dart';
import '../radar_tile_decoder.dart';

/// Radar provider implementation using the RainViewer global radar service.
///
/// RainViewer provides free global radar coverage without requiring an API key.
/// The service aggregates radar data from multiple sources worldwide.
///
/// API Documentation: https://www.rainviewer.com/api.html
///
/// Coverage: Global (entire world)
/// Update Frequency: Every 10 minutes
/// History: ~2 hours of past data
/// Forecast: ~30 minutes of nowcast data
class RainViewerRadarProvider extends RadarProvider {
  /// API endpoint for fetching radar data metadata.
  static const String _apiUrl =
      'https://api.rainviewer.com/public/weather-maps.json';

  /// Zoom level at which radar tiles are fetched and decoded for the per-cell
  /// intensity field. At z=7 a tile spans ~2.8° (~310 km at the equator,
  /// narrower in longitude at higher latitudes), so a 100 km analysis FOV is
  /// covered by a small handful of tiles — enough spatial detail for cloud
  /// tracking without fetching the whole world.
  static const int _decodeZoom = 7;

  /// Resolution of the decoded intensity grid (cells per side) over the
  /// analysis FOV. 48×48 over a ~200 km box is ~4 km/cell — finer than the
  /// analyzer's 10 km sampling grid, so no spatial detail is lost downstream.
  static const int _gridResolution = 48;

  /// Half-side padding (degrees) added around the FOV bounding box so a cloud
  /// band just outside the analysis radius is still captured for motion.
  static const double _boundsPaddingDeg = 0.25;

  /// HTTP client for making API requests.
  final http.Client _httpClient;

  /// Pure tile-decoding / resampling helper (no I/O).
  final RadarTileDecoder _decoder;

  /// Creates a new RainViewer radar provider instance.
  ///
  /// Optionally accepts a custom [httpClient] for testing purposes.
  RainViewerRadarProvider({http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client(),
      _decoder = const RadarTileDecoder();

  @override
  String get name => 'RainViewer';

  @override
  RadarProviderType get providerType => RadarProviderType.rainviewer;

  @override
  GeoBounds get coverageBounds => const GeoBounds.global();

  @override
  Future<RadarFetchResult> fetchRadarFrames({
    required double latitude,
    required double longitude,
    double radiusKm = 100.0,
  }) async {
    developer.log(
      'Fetching radar frames for ($latitude, $longitude)',
      name: 'RainViewer',
      level: 800,
    );
    try {
      // Fetch the radar metadata from RainViewer API
      final response = await _httpClient.get(Uri.parse(_apiUrl));

      if (response.statusCode != 200) {
        return RadarFetchResult.error(
          'RainViewer API returned status ${response.statusCode}: ${response.reasonPhrase}',
        );
      }

      // Parse JSON response
      final Map<String, dynamic> data;
      try {
        data = json.decode(response.body) as Map<String, dynamic>;
      } catch (e) {
        return RadarFetchResult.error(
          'Failed to parse RainViewer API response: $e',
        );
      }

      // Extract host URL and radar data
      final String host = data['host'] as String? ?? '';

      final Map<String, dynamic>? radarData =
          data['radar'] as Map<String, dynamic>?;

      if (radarData == null) {
        return RadarFetchResult.error(
          'RainViewer API response missing radar data',
        );
      }

      // Geographic bounding box of the analysis FOV (a [radiusKm] circle around
      // the observer), padded so a band just outside the radius is still seen.
      final fov = _fovBounds(latitude, longitude, radiusKm);

      // Which slippy-map tiles cover that box at the decode zoom.
      final tileRange = RadarTileDecoder.tileRangeForBounds(
        north: fov.north,
        south: fov.south,
        west: fov.west,
        east: fov.east,
        z: _decodeZoom,
      );

      // Collect raw (timestamp, tile-template, isForecast) frame descriptors.
      final descriptors = <_FrameDescriptor>[];

      final List<dynamic>? pastFrames = radarData['past'] as List<dynamic>?;
      if (pastFrames != null) {
        for (final frameData in pastFrames) {
          final d = _descriptorFor(frameData, host, isForecast: false);
          if (d != null) descriptors.add(d);
        }
      }

      final List<dynamic>? nowcastFrames =
          radarData['nowcast'] as List<dynamic>?;
      if (nowcastFrames != null) {
        for (final frameData in nowcastFrames) {
          final d = _descriptorFor(frameData, host, isForecast: true);
          if (d != null) descriptors.add(d);
        }
      }

      if (descriptors.isEmpty) {
        developer.log(
          'No frames returned from API',
          name: 'RainViewer',
          level: 900,
        );
        return RadarFetchResult.error(
          'RainViewer API returned no radar frames',
        );
      }

      descriptors.sort((a, b) => a.timestamp.compareTo(b.timestamp));

      // Decode each frame's tiles into a real per-cell intensity field over the
      // FOV. A frame whose tiles cannot be fetched/decoded is emitted as a
      // no-data frame (never a fabricated uniform field), so the analyzer
      // reports an honest unavailable reason instead of inventing motion.
      final List<RadarFrame> frames = [];
      for (final d in descriptors) {
        frames.add(await _decodeFrame(d, fov, tileRange));
      }

      developer.log(
        'Parsed ${frames.length} frames from host: $host '
        '(${frames.where((f) => !f.isNoData).length} with spatial data)',
        name: 'RainViewer',
        level: 800,
      );
      return RadarFetchResult.success(frames);
    } on http.ClientException catch (e) {
      return RadarFetchResult.error(
        'Network error fetching RainViewer data: $e',
      );
    } catch (e) {
      return RadarFetchResult.error(
        'Unexpected error fetching RainViewer data: $e',
      );
    }
  }

  @override
  (Duration history, Duration forecast) getAvailableTimeRange() {
    // RainViewer typically provides:
    // - 2 hours of historical radar data
    // - 30 minutes of nowcast (forecast) data
    return (const Duration(hours: 2), const Duration(minutes: 30));
  }

  @override
  String buildTileUrl(RadarFrame frame, int z, int x, int y) {
    // Replace tokens in the tile URL template
    // Template format: "https://tilecache.rainviewer.com/v2/radar/1234567890/256/{z}/{x}/{y}/2/1_1.png"
    return frame.tileUrlTemplate
        .replaceAll('{z}', z.toString())
        .replaceAll('{x}', x.toString())
        .replaceAll('{y}', y.toString());
  }

  String _buildFrameTileUrl(String host, String path) {
    final normalizedHost = host.endsWith('/')
        ? host.substring(0, host.length - 1)
        : host;
    final normalizedPath = path.startsWith('/') ? path : '/$path';

    // RainViewer generally returns a full tile template in `path`.
    if (normalizedPath.contains('{z}') &&
        normalizedPath.contains('{x}') &&
        normalizedPath.contains('{y}')) {
      return '$normalizedHost$normalizedPath';
    }

    return '$normalizedHost$normalizedPath/256/{z}/{x}/{y}/2/1_1.png';
  }

  /// Builds a frame descriptor from one RainViewer frame entry, or null when the
  /// entry is missing its time or path.
  _FrameDescriptor? _descriptorFor(
    dynamic frameData,
    String host, {
    required bool isForecast,
  }) {
    if (frameData is! Map<String, dynamic>) return null;
    final int? timestamp = frameData['time'] as int?;
    final String? path = frameData['path'] as String?;
    if (timestamp == null || path == null) return null;

    return _FrameDescriptor(
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp * 1000),
      tileUrlTemplate: _buildFrameTileUrl(host, path),
      isForecast: isForecast,
    );
  }

  /// Fetches and decodes the tiles covering the FOV for one frame, producing a
  /// [RadarFrame] with a real per-cell [RadarFrame.intensityGrid]. If no tile
  /// could be fetched and decoded, returns a no-data frame so the analyzer can
  /// report an honest unavailable reason rather than a fabricated field.
  Future<RadarFrame> _decodeFrame(
    _FrameDescriptor descriptor,
    _FovBounds fov,
    ({int minX, int maxX, int minY, int maxY}) tileRange,
  ) async {
    final tiles = <DecodedRadarTile>[];

    for (int x = tileRange.minX; x <= tileRange.maxX; x++) {
      for (int y = tileRange.minY; y <= tileRange.maxY; y++) {
        final url = buildTileUrl(
          RadarFrame(
            timestamp: descriptor.timestamp,
            tileUrlTemplate: descriptor.tileUrlTemplate,
            north: fov.north,
            south: fov.south,
            east: fov.east,
            west: fov.west,
          ),
          _decodeZoom,
          x,
          y,
        );

        final http.Response response;
        try {
          response = await _httpClient.get(Uri.parse(url));
        } catch (e) {
          // A single tile failing to fetch is non-fatal — other tiles may still
          // cover the FOV. Record nothing for this tile.
          developer.log(
            'Tile fetch failed ($url): $e',
            name: 'RainViewer',
            level: 900,
          );
          continue;
        }

        if (response.statusCode != 200) {
          developer.log(
            'Tile fetch status ${response.statusCode} for $url',
            name: 'RainViewer',
            level: 900,
          );
          continue;
        }

        final image = _decoder.decodePng(response.bodyBytes);
        if (image == null) {
          developer.log(
            'Tile decode failed for $url',
            name: 'RainViewer',
            level: 900,
          );
          continue;
        }

        tiles.add(DecodedRadarTile(z: _decodeZoom, x: x, y: y, image: image));
      }
    }

    final grid = _decoder.buildIntensityGrid(
      tiles: tiles,
      colormap: RadarColormaps.rainViewerScheme2,
      north: fov.north,
      south: fov.south,
      west: fov.west,
      east: fov.east,
      gridRows: _gridResolution,
      gridCols: _gridResolution,
      z: _decodeZoom,
    );

    if (grid == null) {
      // No tile decoded — emit an honest no-data frame.
      return RadarFrame(
        timestamp: descriptor.timestamp,
        tileUrlTemplate: descriptor.tileUrlTemplate,
        north: fov.north,
        south: fov.south,
        east: fov.east,
        west: fov.west,
        opacity: descriptor.isForecast ? 0.85 : 1.0,
        isForecast: descriptor.isForecast,
        isNoData: true,
      );
    }

    return RadarFrame(
      timestamp: descriptor.timestamp,
      tileUrlTemplate: descriptor.tileUrlTemplate,
      north: fov.north,
      south: fov.south,
      east: fov.east,
      west: fov.west,
      opacity: descriptor.isForecast ? 0.85 : 1.0,
      isForecast: descriptor.isForecast,
      intensityGrid: grid,
    );
  }

  /// Computes the padded geographic bounding box of a [radiusKm] circle around
  /// the observer. Longitude span widens with latitude so the box always
  /// encloses the circle.
  _FovBounds _fovBounds(double latitude, double longitude, double radiusKm) {
    const earthRadiusKm = 6371.0;
    final latDelta = (radiusKm / earthRadiusKm) * 180.0 / math.pi;
    final cosLat = math.cos(latitude * math.pi / 180.0).abs();
    // Guard against the poles where cos→0 (longitude span → whole world).
    final lonDelta = cosLat < 1e-6
        ? 180.0
        : (radiusKm / (earthRadiusKm * cosLat)) * 180.0 / math.pi;

    return _FovBounds(
      north: (latitude + latDelta + _boundsPaddingDeg).clamp(-90.0, 90.0),
      south: (latitude - latDelta - _boundsPaddingDeg).clamp(-90.0, 90.0),
      east: (longitude + lonDelta + _boundsPaddingDeg).clamp(-180.0, 180.0),
      west: (longitude - lonDelta - _boundsPaddingDeg).clamp(-180.0, 180.0),
    );
  }

  @override
  void dispose() {
    _httpClient.close();
    super.dispose();
  }
}

/// Raw per-frame data parsed from the RainViewer metadata, before tile decode.
class _FrameDescriptor {
  _FrameDescriptor({
    required this.timestamp,
    required this.tileUrlTemplate,
    required this.isForecast,
  });

  final DateTime timestamp;
  final String tileUrlTemplate;
  final bool isForecast;
}

/// Padded geographic bounding box of the analysis FOV.
class _FovBounds {
  _FovBounds({
    required this.north,
    required this.south,
    required this.east,
    required this.west,
  });

  final double north;
  final double south;
  final double east;
  final double west;
}
