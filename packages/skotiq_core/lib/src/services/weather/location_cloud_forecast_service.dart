import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/weather/cloud_cover_forecast.dart';
import '../logging_service.dart';
import 'providers/metno_cloud_provider.dart';
import 'providers/nws_cloud_provider.dart';
import 'providers/openmeteo_cloud_provider.dart';
import 'radar_provider.dart';
import 'transient_http_retry.dart';

/// One source-selection policy for the site's current and hourly cloud cover.
/// Regional NWS forecasts take precedence where its points API supplies a grid;
/// the existing global models remain fallbacks for unavailable regional data.
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

  Future<CloudCoverForecast?> fetchCurrentCloudForecast({
    required double latitude,
    required double longitude,
  }) async {
    if (_mayHaveNwsCoverage(latitude, longitude)) {
      final forecast = await _nws.fetchCurrentCloudForecast(
        latitude: latitude,
        longitude: longitude,
      );
      // NWS itself requires an interval containing now, including long blocks.
      if (forecast != null) return forecast;
    }

    try {
      final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
        'latitude': latitude.toString(),
        'longitude': longitude.toString(),
        'current': 'cloud_cover',
        'timezone': 'UTC',
      });
      final response = await getWithTransientRetry(_client, uri);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final forecast = data is Map<String, dynamic>
            ? CloudCoverForecast.fromOpenMeteo(data)
            : null;
        if (_isCurrentSample(forecast)) return forecast;
      }
    } on Exception catch (error) {
      Log.warning(
        'Open-Meteo current cloud forecast unavailable '
        '(${error.runtimeType}); trying MET Norway',
        source: 'Weather',
      );
    }

    final fallback = await _metNorway.fetchRadarFrames(
      latitude: latitude,
      longitude: longitude,
    );
    CloudCoverForecast? nearest;
    Duration? nearestGap;
    final now = _clock().toUtc();
    for (final frame in fallback.frames) {
      final gap = frame.timestamp.difference(now).abs();
      if (nearestGap == null || gap < nearestGap) {
        nearestGap = gap;
        nearest = CloudCoverForecast(
          percent: frame.opacity * 100,
          source: _metNorway.name,
          validAt: frame.timestamp,
        );
      }
    }
    return _isCurrentSample(nearest) ? nearest : null;
  }

  bool _isCurrentSample(CloudCoverForecast? forecast) =>
      forecast != null &&
      forecast.percent.isFinite &&
      forecast.percent >= 0 &&
      forecast.percent <= 100 &&
      forecast.validAt != null &&
      forecast.validAt!.difference(_clock().toUtc()).abs() <=
          const Duration(minutes: 90);

  Future<RadarFetchResult> fetchRadarFrames({
    required double latitude,
    required double longitude,
  }) async {
    if (_mayHaveNwsCoverage(latitude, longitude)) {
      final regional = await _nws.fetchRadarFrames(
        latitude: latitude,
        longitude: longitude,
      );
      if (_hasFutureForecast(regional)) return regional;
    }
    final global = await _openMeteo.fetchRadarFrames(
      latitude: latitude,
      longitude: longitude,
    );
    if (_hasFutureForecast(global)) {
      return global.withProviderName('Open-Meteo');
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
