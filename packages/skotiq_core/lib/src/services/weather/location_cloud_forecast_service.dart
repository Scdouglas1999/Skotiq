import 'package:http/http.dart' as http;

import 'providers/metno_cloud_provider.dart';
import 'providers/nws_cloud_provider.dart';
import 'providers/openmeteo_cloud_provider.dart';
import 'radar_provider.dart';

/// The one owner of the site's hourly cloud forecast.
///
/// Open-Meteo's best-match model comes first: it runs the best regional model
/// for the site (NOAA HRRR, updated hourly, for the first hours in the United
/// States) and global models after. The National Weather Service grid, a
/// forecast issued a few times a day, and MET Norway follow when it fails.
/// The sky now is [CurrentSkyService]'s.
class LocationCloudForecastService {
  LocationCloudForecastService({
    http.Client? httpClient,
    DateTime Function()? clock,
  }) : _client = httpClient ?? http.Client(),
       _clock = clock ?? DateTime.now {
    _nws = NwsCloudProvider(httpClient: _client, clock: _clock);
    _openMeteo = OpenMeteoCloudProvider(httpClient: _client);
    _metNorway = MetNoCloudProvider(httpClient: _client);
  }

  final http.Client _client;
  final DateTime Function() _clock;
  late final NwsCloudProvider _nws;
  late final OpenMeteoCloudProvider _openMeteo;
  late final MetNoCloudProvider _metNorway;

  /// Broad Americas/Pacific envelope, including Alaska across the date line
  /// and US island territories. The NWS points response decides coverage;
  /// this only avoids needless US-service requests for the rest of the world.
  bool _mayHaveNwsCoverage(double latitude, double longitude) =>
      latitude >= -20 &&
      latitude <= 75 &&
      (longitude <= -60 || longitude >= 125);

  Future<RadarFetchResult> fetchRadarFrames({
    required double latitude,
    required double longitude,
  }) async {
    final model = await _openMeteo.fetchRadarFrames(
      latitude: latitude,
      longitude: longitude,
    );
    if (_hasFutureForecast(model)) {
      return model.withProviderName('Open-Meteo');
    }
    if (_mayHaveNwsCoverage(latitude, longitude)) {
      final regional = await _nws.fetchRadarFrames(
        latitude: latitude,
        longitude: longitude,
      );
      if (_hasFutureForecast(regional)) return regional;
    }
    final fallback = await _metNorway.fetchRadarFrames(
      latitude: latitude,
      longitude: longitude,
    );
    if (_hasFutureForecast(fallback)) {
      return fallback.withProviderName(_metNorway.name);
    }
    return RadarFetchResult.error('No cloud forecast source is available');
  }

  bool _hasFutureForecast(RadarFetchResult result) =>
      result.isSuccess &&
      result.frames.any((frame) => !frame.timestamp.isBefore(_clock().toUtc()));

  /// The facade owns the one shared client; providers must not close it early.
  void dispose() {
    _nws.dispose();
    _client.close();
  }
}
