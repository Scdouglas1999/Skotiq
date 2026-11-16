import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/weather/cloud_cover_forecast.dart';
import '../../models/weather/current_sky.dart';
import '../../utils/logging_service.dart';
import 'providers/metar_station_provider.dart';
import 'providers/metno_cloud_provider.dart';
import 'transient_http_retry.dart';

/// The one owner of "the sky over the site now".
///
/// A recent report from a station near the site is the reading; the model's
/// value for this quarter hour (Open-Meteo, which runs the best regional model
/// for the site: NOAA HRRR in the United States) stands beside it for
/// comparison, and stands in for it where no station reports. A forecast
/// grid issued hours ago is never "now".
class CurrentSkyService {
  CurrentSkyService({http.Client? httpClient, DateTime Function()? clock})
    : _client = httpClient ?? http.Client(),
      _clock = clock ?? DateTime.now {
    _stations = MetarStationProvider(client: _client, clock: _clock);
    _metNorway = MetNoCloudProvider(httpClient: _client);
  }

  final http.Client _client;
  final DateTime Function() _clock;
  late final MetarStationProvider _stations;
  late final MetNoCloudProvider _metNorway;

  /// A model sample farther than this from now is not "now".
  static const _modelWindow = Duration(minutes: 90);

  /// Null when neither a station nor a model has a value for now.
  Future<CurrentSky?> fetch({
    required double latitude,
    required double longitude,
  }) async {
    final (station, (model, high)) = await (
      _stations.nearest(latitude: latitude, longitude: longitude),
      _modelNow(latitude, longitude),
    ).wait;
    if (station == null && model == null) return null;
    return CurrentSky(
      station: station,
      model: model,
      modelHighCloudPercent: high,
    );
  }

  /// The model's total and high cloud for now: Open-Meteo, else the MET
  /// Norway sample nearest now.
  Future<(CloudCoverForecast?, double?)> _modelNow(
    double latitude,
    double longitude,
  ) async {
    try {
      final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
        'latitude': latitude.toString(),
        'longitude': longitude.toString(),
        'current': 'cloud_cover,cloud_cover_high',
        'timezone': 'UTC',
      });
      final response = await getWithTransientRetry(_client, uri);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is Map<String, dynamic>) {
          final forecast = CloudCoverForecast.fromOpenMeteo(data);
          if (_isNow(forecast)) {
            final current = data['current'];
            final high = current is Map ? current['cloud_cover_high'] : null;
            return (
              forecast,
              high is num && high.isFinite
                  ? high.toDouble().clamp(0.0, 100.0)
                  : null,
            );
          }
        }
      }
    } on Exception catch (error) {
      Log.warning(
        'Open-Meteo current cloud cover unavailable '
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
    return (_isNow(nearest) ? nearest : null, null);
  }

  bool _isNow(CloudCoverForecast? forecast) =>
      forecast != null &&
      forecast.percent.isFinite &&
      forecast.percent >= 0 &&
      forecast.percent <= 100 &&
      forecast.validAt != null &&
      forecast.validAt!.difference(_clock().toUtc()).abs() <= _modelWindow;

  /// The service owns the one shared client.
  void dispose() => _client.close();
}
