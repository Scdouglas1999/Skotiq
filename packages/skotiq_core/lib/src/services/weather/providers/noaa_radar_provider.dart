import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import '../radar_colormaps.dart';
import '../radar_provider.dart';
import '../radar_tile_decoder.dart';
import '../../../models/weather/weather_models.dart';

/// NOAA NEXRAD radar provider for US and southern Canada coverage.
///
/// Uses the Iowa Environmental Mesonet (IEM) WMS service to provide
/// free NEXRAD base reflectivity radar imagery. This provider covers
/// the continental United States and southern portions of Canada.
///
/// The radar data is updated every 5 minutes and provides approximately
/// 2 hours of historical frames.
///
/// Technical details:
/// - Data source: Iowa State University IEM NEXRAD archive
/// - Update frequency: ~5 minutes
/// - Resolution: Base reflectivity (N0Q product)
/// - Coverage: CONUS + southern Canada (lat 24-55, lon -130 to -60)
class NoaaRadarProvider extends RadarProvider {
  /// HTTP client for fetching radar metadata and tiles.
  final http.Client _client;

  /// Base URL for the IEM NEXRAD WMS service.
  /// Note: Must end with '?' for flutter_map WMSTileLayerOptions to properly append query params
  static const String _baseWmsUrl =
      'https://mesonet.agron.iastate.edu/cgi-bin/wms/nexrad/n0q.cgi?';

  /// Maximum number of historical frames to fetch (last 2 hours at 5min intervals = ~24 frames).
  static const int _maxFrames = 24;

  /// Coverage area for NOAA NEXRAD: CONUS + southern Canada.
  static const GeoBounds _coverage = GeoBounds(
    north: 55.0, // Southern Canada
    south: 24.0, // Southern tip of Florida
    east: -60.0, // East coast + Atlantic margin
    west: -130.0, // West coast + Pacific margin
  );

  /// Width/height (pixels) of the WMS GetMap image fetched per frame for
  /// per-cell decoding. 256² over a ~200 km FOV is ~0.8 km/pixel — well finer
  /// than the analyzer's 10 km grid.
  static const int _wmsImageSize = 256;

  /// Resolution of the decoded intensity grid (cells per side) over the FOV.
  static const int _gridResolution = 48;

  /// Half-side padding (degrees) added around the FOV bounding box.
  static const double _boundsPaddingDeg = 0.25;

  /// Pure tile/image decoding helper (no I/O).
  final RadarTileDecoder _decoder;

  /// Creates a new NOAA NEXRAD radar provider.
  ///
  /// Optionally accepts a custom HTTP [client] for testing or custom configuration.
  NoaaRadarProvider({http.Client? client})
    : _client = client ?? http.Client(),
      _decoder = const RadarTileDecoder();

  @override
  String get name => 'NOAA NEXRAD';

  @override
  RadarProviderType get providerType => RadarProviderType.noaa;

  @override
  GeoBounds get coverageBounds => _coverage;

  @override
  (Duration, Duration) getAvailableTimeRange() {
    // NOAA NEXRAD provides ~2 hours of historical data, no forecast
    return (const Duration(hours: 2), Duration.zero);
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
        'Location ($latitude, $longitude) is outside NOAA NEXRAD coverage area',
      );
    }

    try {
      // Fetch available timestamps from the time series endpoint
      final timestamps = await _fetchAvailableTimestamps();

      if (timestamps.isEmpty) {
        return RadarFetchResult.error('No radar frames available from NOAA');
      }

      // Geographic bounding box of the analysis FOV around the observer.
      final fov = _fovBounds(latitude, longitude, radiusKm);

      // Decode a per-cell intensity field for each timestamp by fetching a WMS
      // GetMap image over the FOV (EPSG:4326 plate-carrée) and mapping the
      // NEXRAD N0Q reflectivity colormap. A frame whose image cannot be fetched
      // or decoded is emitted as a no-data frame, never a fabricated field.
      final frames = <RadarFrame>[];
      for (final timestamp in timestamps) {
        frames.add(await _decodeFrame(timestamp, fov));
      }

      developer.log(
        'NoaaRadarProvider: Built ${frames.length} frames '
        '(${frames.where((f) => !f.isNoData).length} with spatial data)',
        name: 'NoaaRadarProvider',
        level: 800,
      );

      return RadarFetchResult.success(frames);
    } on http.ClientException catch (e) {
      return RadarFetchResult.error('Network error fetching NOAA radar: $e');
    } on FormatException catch (e) {
      return RadarFetchResult.error('Failed to parse NOAA radar response: $e');
    } catch (e) {
      return RadarFetchResult.error('Unexpected error fetching NOAA radar: $e');
    }
  }

  /// Fetches and decodes the NEXRAD WMS image for one timestamp into a
  /// [RadarFrame] carrying a real per-cell intensity grid over the FOV. Returns
  /// a no-data frame when the image cannot be fetched or decoded.
  Future<RadarFrame> _decodeFrame(DateTime timestamp, _FovBounds fov) async {
    final timeParam = timestamp.toUtc().toIso8601String();
    final url = _getMapUrl(timeParam, fov);

    final wmsOptions = {'time': timeParam, 'transparent': 'true'};

    img.Image? image;
    try {
      final response = await _client.get(Uri.parse(url));
      if (response.statusCode == 200) {
        image = _decoder.decodePng(response.bodyBytes);
      } else {
        developer.log(
          'NOAA GetMap status ${response.statusCode}',
          name: 'NoaaRadarProvider',
          level: 900,
        );
      }
    } catch (e) {
      developer.log(
        'NOAA GetMap fetch failed: $e',
        name: 'NoaaRadarProvider',
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
        wmsLayers: 'nexrad-n0q-900913',
        wmsAdditionalOptions: wmsOptions,
        isNoData: true,
      );
    }

    final grid = _decoder.buildIntensityGridFromWmsImage(
      image: image,
      colormap: RadarColormaps.nexradN0q,
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
      wmsLayers: 'nexrad-n0q-900913',
      wmsAdditionalOptions: wmsOptions,
      intensityGrid: grid,
      isNoData: grid == null,
    );
  }

  /// Builds a WMS GetMap URL for the FOV in EPSG:4326 (plate-carrée), so the
  /// returned image maps linearly to lon/lat for per-cell sampling.
  String _getMapUrl(String timeParam, _FovBounds fov) {
    // WMS 1.1.1 EPSG:4326 BBOX order is minx,miny,maxx,maxy = west,south,east,north.
    final bbox = '${fov.west},${fov.south},${fov.east},${fov.north}';
    return Uri.parse(_baseWmsUrl)
        .replace(
          queryParameters: {
            'service': 'WMS',
            'version': '1.1.1',
            'request': 'GetMap',
            'layers': 'nexrad-n0q-900913',
            'format': 'image/png',
            'transparent': 'true',
            'srs': 'EPSG:4326',
            'width': '$_wmsImageSize',
            'height': '$_wmsImageSize',
            'time': timeParam,
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

  /// Fetches the list of available radar timestamps from IEM.
  ///
  /// Makes a GetCapabilities request to the WMS service and parses
  /// the temporal dimension to extract available frame timestamps.
  ///
  /// Returns a list of timestamps in reverse chronological order (newest first).
  Future<List<DateTime>> _fetchAvailableTimestamps() async {
    // Request GetCapabilities to get available time dimensions
    final url = Uri.parse(_baseWmsUrl).replace(
      queryParameters: {
        'service': 'WMS',
        'version': '1.1.1',
        'request': 'GetCapabilities',
      },
    );

    final response = await _client.get(url);

    if (response.statusCode != 200) {
      throw http.ClientException(
        'NOAA WMS GetCapabilities failed with status ${response.statusCode}',
        url,
      );
    }

    // Parse the XML response to extract time dimension
    final body = response.body;
    final timestamps = _parseTimestampsFromCapabilities(body);

    return timestamps;
  }

  /// Parses radar timestamps from the WMS GetCapabilities XML response.
  ///
  /// Extracts the time dimension values and converts them to DateTime objects.
  /// Returns up to [_maxFrames] most recent timestamps.
  List<DateTime> _parseTimestampsFromCapabilities(String xml) {
    final timestamps = <DateTime>[];

    // Look for <Dimension name="time"> element in the XML
    // Format is typically: <Dimension name="time">2024-01-15T12:00:00Z,2024-01-15T12:05:00Z,...</Dimension>
    final dimensionRegex = RegExp(
      r'<Dimension[^>]*name=["\x27]time["\x27][^>]*>([^<]+)</Dimension>',
      caseSensitive: false,
    );

    final match = dimensionRegex.firstMatch(xml);
    if (match == null) {
      // If we can't parse capabilities, fall back to generating timestamps
      // based on current time (last 2 hours, 5-minute intervals)
      return _generateFallbackTimestamps();
    }

    final timeString = match.group(1)!.trim();

    // Time values can be comma-separated or slash-separated (start/end/period)
    if (timeString.contains(',')) {
      // Comma-separated list of individual timestamps
      final timeStrings = timeString.split(',');
      for (final ts in timeStrings) {
        try {
          final dateTime = DateTime.parse(ts.trim());
          timestamps.add(dateTime);
        } catch (e) {
          developer.log(
            'Failed to parse NOAA timestamp: $ts',
            name: 'NoaaRadarProvider',
            level: 900,
            error: e,
          );
        }
      }
    } else if (timeString.contains('/')) {
      // ISO 8601 period format: start/end/period
      // e.g., "2024-01-15T10:00:00Z/2024-01-15T12:00:00Z/PT5M"
      final parts = timeString.split('/');
      if (parts.length == 3) {
        try {
          final start = DateTime.parse(parts[0]);
          final end = DateTime.parse(parts[1]);
          final period = _parseDuration(parts[2]);

          // Generate timestamps from start to end with given period
          var current = start;
          while (current.isBefore(end) || current.isAtSameMomentAs(end)) {
            timestamps.add(current);
            current = current.add(period);
          }
        } catch (e) {
          developer.log(
            'Failed to parse NOAA time period: $timeString',
            name: 'NoaaRadarProvider',
            level: 900,
            error: e,
          );
          return _generateFallbackTimestamps();
        }
      }
    }

    // Sort in reverse chronological order and limit to max frames
    timestamps.sort((a, b) => b.compareTo(a));
    return timestamps.take(_maxFrames).toList();
  }

  /// Generates fallback timestamps when GetCapabilities parsing fails.
  ///
  /// Creates timestamps for the last 2 hours at 5-minute intervals,
  /// rounded to the nearest 5-minute mark.
  List<DateTime> _generateFallbackTimestamps() {
    final now = DateTime.now().toUtc();
    final timestamps = <DateTime>[];

    // Round to nearest 5 minutes
    final roundedMinutes = (now.minute ~/ 5) * 5;
    var current = DateTime.utc(
      now.year,
      now.month,
      now.day,
      now.hour,
      roundedMinutes,
    );

    // Generate last 2 hours of 5-minute intervals
    for (var i = 0; i < _maxFrames; i++) {
      timestamps.add(current);
      current = current.subtract(const Duration(minutes: 5));
    }

    return timestamps;
  }

  /// Parses an ISO 8601 duration string (e.g., "PT5M" = 5 minutes).
  Duration _parseDuration(String iso8601) {
    // Simple parser for common cases: PT#M (minutes), PT#H (hours), PT#S (seconds)
    final regex = RegExp(r'PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?');
    final match = regex.firstMatch(iso8601);

    if (match == null) {
      throw FormatException('Invalid ISO 8601 duration: $iso8601');
    }

    final hours = int.tryParse(match.group(1) ?? '0') ?? 0;
    final minutes = int.tryParse(match.group(2) ?? '0') ?? 0;
    final seconds = int.tryParse(match.group(3) ?? '0') ?? 0;

    return Duration(hours: hours, minutes: minutes, seconds: seconds);
  }

  @override
  String buildTileUrl(RadarFrame frame, int z, int x, int y) {
    // Calculate Web Mercator bounding box for this tile
    final bbox = _tileToBBox(x, y, z);

    // Replace the {bbox} token in the template
    return frame.tileUrlTemplate.replaceAll(
      '{bbox}',
      '${bbox[0]},${bbox[1]},${bbox[2]},${bbox[3]}',
    );
  }

  /// Converts tile coordinates (x, y, z) to Web Mercator bounding box.
  ///
  /// Returns [west, south, east, north] in EPSG:3857 coordinates.
  List<double> _tileToBBox(int x, int y, int z) {
    const worldSize =
        20037508.342789244; // Half circumference of Earth in meters
    final tileSize = (2 * worldSize) / (1 << z);

    final west = -worldSize + (x * tileSize);
    final north = worldSize - (y * tileSize);
    final east = west + tileSize;
    final south = north - tileSize;

    return [west, south, east, north];
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
