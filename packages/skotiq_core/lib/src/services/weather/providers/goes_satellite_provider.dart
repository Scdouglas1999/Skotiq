import 'dart:developer' as developer;
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import '../radar_colormaps.dart';
import '../radar_provider.dart';
import '../radar_tile_decoder.dart';
import '../../../models/weather/weather_models.dart';

/// GOES satellite infrared imagery provider for cloud cover visualization.
///
/// Uses the Iowa Environmental Mesonet (IEM) WMS service to provide
/// GOES-16/17/18 infrared satellite imagery. Unlike radar which shows
/// precipitation, infrared satellite shows actual cloud cover by detecting
/// cloud top temperatures - clouds appear bright (cold) against dark (warm) ground.
///
/// This provider is ideal for astrophotography applications where you need
/// to see ALL clouds, not just precipitating ones.
///
/// Technical details:
/// - Data source: Iowa State University IEM GOES archive
/// - Update frequency: ~5-15 minutes
/// - Resolution: 4km (CONUS IR)
/// - Coverage: CONUS (lat 14-57, lon -153 to -53)
/// - Works 24/7 (infrared doesn't require sunlight)
class GoesSatelliteProvider extends RadarProvider {
  /// HTTP client for fetching metadata.
  final http.Client _client;

  /// Base URL for the IEM GOES CONUS IR WMS service.
  static const String _baseWmsUrl =
      'https://mesonet.agron.iastate.edu/cgi-bin/wms/goes/conus_ir.cgi?';

  /// Layer name for CONUS infrared imagery.
  static const String _layerName = 'conus_ir_4km';

  /// Coverage area for GOES CONUS: Continental US + margins.
  static const GeoBounds _coverage = GeoBounds(
    north: 56.0, // Northern US/Canada border
    south: 15.0, // Southern Mexico
    east: -53.0, // East Atlantic margin
    west: -152.0, // West Pacific margin (includes Hawaii)
  );

  /// Width/height (pixels) of the WMS GetMap image fetched per frame.
  static const int _wmsImageSize = 256;

  /// Resolution of the decoded intensity grid (cells per side) over the FOV.
  static const int _gridResolution = 48;

  /// Half-side padding (degrees) added around the FOV bounding box.
  static const double _boundsPaddingDeg = 0.25;

  /// Pure image decoding/resampling helper (no I/O).
  final RadarTileDecoder _decoder;

  /// Creates a new GOES satellite provider.
  GoesSatelliteProvider({http.Client? client})
    : _client = client ?? http.Client(),
      _decoder = const RadarTileDecoder();

  @override
  String get name => 'GOES Satellite';

  @override
  RadarProviderType get providerType => RadarProviderType.goesSatellite;

  @override
  GeoBounds get coverageBounds => _coverage;

  @override
  (Duration, Duration) getAvailableTimeRange() {
    // GOES provides near real-time imagery, no forecast
    // Historical imagery available but we'll just use current
    return (const Duration(hours: 1), Duration.zero);
  }

  @override
  Future<RadarFetchResult> fetchRadarFrames({
    required double latitude,
    required double longitude,
    double radiusKm = 100.0,
  }) async {
    // Verify coverage
    if (!coversLocation(latitude, longitude)) {
      return RadarFetchResult.error(
        'Location ($latitude, $longitude) is outside GOES satellite coverage area',
      );
    }

    try {
      // GOES satellite imagery is essentially real-time with automatic refresh
      // We'll create a single frame representing "now" - the WMS service
      // automatically returns the most recent imagery
      final now = DateTime.now().toUtc();

      // Round to nearest 5 minutes for consistency
      final roundedMinutes = (now.minute ~/ 5) * 5;
      final timestamp = DateTime.utc(
        now.year,
        now.month,
        now.day,
        now.hour,
        roundedMinutes,
      );

      // Geographic bounding box of the analysis FOV around the observer.
      final fov = _fovBounds(latitude, longitude, radiusKm);

      final frame = await _decodeFrame(timestamp, fov);

      developer.log(
        'Built satellite frame for $timestamp, layer: $_layerName '
        '(${frame.isNoData ? "no-data" : "with spatial data"})',
        name: 'GoesSatellite',
        level: 800,
      );

      return RadarFetchResult.success([frame]);
    } on http.ClientException catch (e) {
      return RadarFetchResult.error(
        'Network error fetching GOES satellite: $e',
      );
    } catch (e) {
      return RadarFetchResult.error(
        'Unexpected error fetching GOES satellite: $e',
      );
    }
  }

  @override
  String buildTileUrl(RadarFrame frame, int z, int x, int y) {
    // Calculate Web Mercator bounding box for this tile
    final bbox = _tileToBBox(x, y, z);

    // Build WMS GetMap URL
    final params = {
      'service': 'WMS',
      'version': '1.1.1',
      'request': 'GetMap',
      'layers': frame.wmsLayers ?? _layerName,
      'format': 'image/png',
      'transparent': 'true',
      'srs': 'EPSG:3857',
      'width': '256',
      'height': '256',
      'bbox': '${bbox[0]},${bbox[1]},${bbox[2]},${bbox[3]}',
    };

    final url = Uri.parse(_baseWmsUrl).replace(queryParameters: params);
    return url.toString();
  }

  /// Converts tile coordinates (x, y, z) to Web Mercator bounding box.
  List<double> _tileToBBox(int x, int y, int z) {
    const worldSize = 20037508.342789244;
    final tileSize = (2 * worldSize) / (1 << z);

    final west = -worldSize + (x * tileSize);
    final north = worldSize - (y * tileSize);
    final east = west + tileSize;
    final south = north - tileSize;

    return [west, south, east, north];
  }

  /// Fetches and decodes the GOES IR WMS image for one timestamp into a
  /// [RadarFrame] with a real per-cell cloud-intensity grid over the FOV.
  /// Returns a no-data frame when the image cannot be fetched or decoded.
  Future<RadarFrame> _decodeFrame(DateTime timestamp, _FovBounds fov) async {
    final url = _getMapUrl(fov);
    const wmsOptions = {'transparent': 'true'};

    img.Image? image;
    try {
      final response = await _client.get(Uri.parse(url));
      if (response.statusCode == 200) {
        image = _decoder.decodePng(response.bodyBytes);
      } else {
        developer.log(
          'GOES GetMap status ${response.statusCode}',
          name: 'GoesSatellite',
          level: 900,
        );
      }
    } catch (e) {
      developer.log(
        'GOES GetMap fetch failed: $e',
        name: 'GoesSatellite',
        level: 900,
      );
    }

    if (image == null) {
      return RadarFrame(
        timestamp: timestamp,
        tileUrlTemplate: _baseWmsUrl,
        north: fov.north,
        south: fov.south,
        east: fov.east,
        west: fov.west,
        opacity: 1.0,
        isForecast: false,
        tileType: RadarTileType.wms,
        wmsLayers: _layerName,
        wmsAdditionalOptions: wmsOptions,
        isNoData: true,
      );
    }

    final grid = _decoder.buildIntensityGridFromWmsImage(
      image: image,
      colormap: RadarColormaps.goesInfrared,
      imageNorth: fov.north,
      imageSouth: fov.south,
      imageWest: fov.west,
      imageEast: fov.east,
      gridRows: _gridResolution,
      gridCols: _gridResolution,
    );

    return RadarFrame(
      timestamp: timestamp,
      tileUrlTemplate: _baseWmsUrl,
      north: fov.north,
      south: fov.south,
      east: fov.east,
      west: fov.west,
      opacity: 1.0,
      isForecast: false,
      tileType: RadarTileType.wms,
      wmsLayers: _layerName,
      wmsAdditionalOptions: wmsOptions,
      intensityGrid: grid,
      isNoData: grid == null,
    );
  }

  /// Builds a WMS GetMap URL for the FOV in EPSG:4326 (plate-carrée).
  String _getMapUrl(_FovBounds fov) {
    final bbox = '${fov.west},${fov.south},${fov.east},${fov.north}';
    return Uri.parse(_baseWmsUrl)
        .replace(
          queryParameters: {
            'service': 'WMS',
            'version': '1.1.1',
            'request': 'GetMap',
            'layers': _layerName,
            'format': 'image/png',
            'transparent': 'true',
            'srs': 'EPSG:4326',
            'width': '$_wmsImageSize',
            'height': '$_wmsImageSize',
            'bbox': bbox,
          },
        )
        .toString();
  }

  /// Computes the padded geographic bounding box of a [radiusKm] circle around
  /// the observer.
  _FovBounds _fovBounds(double latitude, double longitude, double radiusKm) {
    const earthRadiusKm = 6371.0;
    final latDelta = (radiusKm / earthRadiusKm) * 180.0 / math.pi;
    final cosLat = math.cos(latitude * math.pi / 180.0).abs();
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
    _client.close();
    super.dispose();
  }
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
