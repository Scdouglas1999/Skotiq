import 'package:flutter/foundation.dart';
import '../../models/weather/weather_models.dart';

/// Result wrapper for radar frame fetch operations.
///
/// Contains either a successful list of frames or an error message.
class RadarFetchResult {
  /// List of radar frames fetched from the provider.
  final List<RadarFrame> frames;

  /// Timestamp when the data was fetched.
  final DateTime fetchedAt;

  /// Human-readable name of the provider that produced these frames
  /// (e.g. "GOES Satellite", "NOAA NEXRAD"). Null when the producing provider
  /// is unknown (e.g. the raw provider call doesn't tag itself; the
  /// [WeatherRadarService] fills this in when it selects a provider).
  final String? providerName;

  /// Error message if the fetch failed, null otherwise.
  final String? errorMessage;

  /// Whether the fetch was successful.
  bool get isSuccess => errorMessage == null;

  const RadarFetchResult._({
    required this.frames,
    required this.fetchedAt,
    this.providerName,
    this.errorMessage,
  });

  /// Creates a successful result with the given frames.
  ///
  /// [providerName] optionally records which provider produced the frames so
  /// the UI can attribute the data source.
  factory RadarFetchResult.success(
    List<RadarFrame> frames, {
    String? providerName,
  }) {
    return RadarFetchResult._(
      frames: frames,
      fetchedAt: DateTime.now(),
      providerName: providerName,
    );
  }

  /// Returns a copy of this result tagged with the producing provider's name.
  ///
  /// Used by the [WeatherRadarService] to attach attribution after it selects
  /// a provider, without each provider having to know its own display name in
  /// the result payload.
  RadarFetchResult withProviderName(String name) {
    return RadarFetchResult._(
      frames: frames,
      fetchedAt: fetchedAt,
      providerName: name,
      errorMessage: errorMessage,
    );
  }

  /// Creates an error result with the given message.
  factory RadarFetchResult.error(String message) {
    return RadarFetchResult._(
      frames: const [],
      fetchedAt: DateTime.now(),
      errorMessage: message,
    );
  }
}

/// Geographic bounding box helper for checking coverage areas.
class GeoBounds {
  /// Northern boundary in degrees latitude.
  final double north;

  /// Southern boundary in degrees latitude.
  final double south;

  /// Eastern boundary in degrees longitude.
  final double east;

  /// Western boundary in degrees longitude.
  final double west;

  const GeoBounds({
    required this.north,
    required this.south,
    required this.east,
    required this.west,
  });

  /// Checks if a given latitude/longitude point is within these bounds.
  ///
  /// Handles the antimeridian crossing case where east < west.
  bool contains(double lat, double lon) {
    // Check latitude (simple case)
    if (lat < south || lat > north) {
      return false;
    }

    // Check longitude (handle antimeridian crossing)
    if (east >= west) {
      // Normal case: bounds don't cross antimeridian
      return lon >= west && lon <= east;
    } else {
      // Bounds cross the antimeridian (e.g., 170°E to -170°E)
      return lon >= west || lon <= east;
    }
  }

  /// Creates a global coverage bounds (entire world).
  const GeoBounds.global()
    : north = 90.0,
      south = -90.0,
      east = 180.0,
      west = -180.0;

  /// Creates bounds for the contiguous United States.
  const GeoBounds.conus()
    : north = 50.0,
      south = 24.0,
      east = -66.0,
      west = -125.0;
}

/// Abstract base class for radar data providers.
///
/// Implementations fetch radar imagery from various sources (NOAA, RainViewer, etc.)
/// and provide tile URLs for rendering on maps.
abstract class RadarProvider {
  /// Human-readable name of this provider.
  String get name;

  /// Type identifier for this provider.
  RadarProviderType get providerType;

  /// Geographic bounds where this provider has coverage.
  GeoBounds get coverageBounds;

  /// Checks if this provider covers a specific location.
  ///
  /// Delegates to [coverageBounds.contains].
  bool coversLocation(double latitude, double longitude) {
    return coverageBounds.contains(latitude, longitude);
  }

  /// Fetches radar frames for a given location.
  ///
  /// Parameters:
  /// - [latitude]: Center latitude in degrees
  /// - [longitude]: Center longitude in degrees
  /// - [radiusKm]: Search radius in kilometers (default: 100.0)
  ///
  /// Returns a [RadarFetchResult] containing frames or an error.
  Future<RadarFetchResult> fetchRadarFrames({
    required double latitude,
    required double longitude,
    double radiusKm = 100.0,
  });

  /// Returns the available time range for radar data.
  ///
  /// Returns a tuple of (history duration, forecast duration).
  /// For example, (Duration(hours: 2), Duration(hours: 1)) means
  /// 2 hours of historical data and 1 hour of forecast.
  (Duration history, Duration forecast) getAvailableTimeRange();

  /// Builds a tile URL for a specific radar frame and tile coordinates.
  ///
  /// Parameters:
  /// - [frame]: The radar frame to render
  /// - [z]: Zoom level
  /// - [x]: Tile X coordinate
  /// - [y]: Tile Y coordinate
  ///
  /// Returns the URL string for the tile image.
  String buildTileUrl(RadarFrame frame, int z, int x, int y);

  /// Disposes of resources used by this provider.
  ///
  /// Subclasses should override and call super.dispose().
  @mustCallSuper
  void dispose() {
    // Base implementation does nothing, but ensures subclasses call super
  }
}
