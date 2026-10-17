import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../../models/weather/weather_models.dart';
import '../radar_provider.dart';
import '../transient_http_retry.dart';

/// MET Norway Locationforecast provider for cloud cover percentage data.
///
/// An independent fallback for [OpenMeteoCloudProvider]: when Open-Meteo's
/// single host degrades, this fetches the same numerical cloud-cover signal
/// from a different operator (api.met.no) so the cloud panels and multi-night
/// forecast keep working. It mirrors Open-Meteo's RadarFrame conventions
/// exactly (±0.5° point bounds, opacity = cloudCover/100, UTC timestamps) so
/// downstream consumers can't tell the providers apart.
///
/// MET Norway provides NO past data — the forecast starts at "now" — and
/// REQUIRES an identifying User-Agent (403 without), so all requests carry
/// [_userAgent].
class MetNoCloudProvider extends RadarProvider {
  /// HTTP client for API requests.
  final http.Client _httpClient;

  /// Compact Locationforecast endpoint (hourly near-term, 6-hourly out to ~9
  /// days). Lat/lon are appended per request.
  static const String _baseUrl =
      'https://api.met.no/weatherapi/locationforecast/2.0/compact';

  /// Identifying User-Agent. MET Norway's terms require a contactable
  /// identifier and reject anonymous requests with 403.
  static const String _userAgent =
      'Skotiq/4.0 (+https://github.com/Scdouglas1999/Skotiq)';

  /// Creates a MET Norway cloud cover provider.
  ///
  /// Optionally accepts a custom [httpClient] for testing.
  MetNoCloudProvider({http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client();

  @override
  String get name => 'MET Norway';

  @override
  RadarProviderType get providerType => RadarProviderType.metno;

  @override
  GeoBounds get coverageBounds => const GeoBounds.global();

  @override
  Future<RadarFetchResult> fetchRadarFrames({
    required double latitude,
    required double longitude,
    double radiusKm = 100.0,
  }) async {
    try {
      final uri = Uri.parse(_baseUrl).replace(
        queryParameters: {
          'lat': latitude.toString(),
          'lon': longitude.toString(),
        },
      );

      // Retry transient 5xx / dropped-TLS blips; the User-Agent must ride along
      // on every attempt or MET Norway answers 403.
      final response = await getWithTransientRetry(
        _httpClient,
        uri,
        headers: const {'User-Agent': _userAgent},
      );

      if (response.statusCode != 200) {
        return RadarFetchResult.error(
          'MET Norway API returned status ${response.statusCode}',
        );
      }

      final Map<String, dynamic> json;
      try {
        json = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (e) {
        return RadarFetchResult.error('Failed to parse JSON response: $e');
      }

      final properties = json['properties'];
      if (properties is! Map<String, dynamic>) {
        return RadarFetchResult.error('Missing properties in response');
      }
      final timeseries = properties['timeseries'];
      if (timeseries is! List) {
        return RadarFetchResult.error('Missing timeseries in response');
      }

      // Timestamps carry a trailing 'Z' (true UTC), so compare against a UTC
      // "now" for the forecast flag.
      final now = DateTime.now().toUtc();
      final frames = <RadarFrame>[];

      for (final entry in timeseries) {
        final cloudCover = _cloudCoverFraction(entry);
        if (cloudCover == null) {
          continue; // Skip entries with no usable cloud value.
        }
        final timestamp = _entryTime(entry);
        if (timestamp == null) {
          continue; // Skip entries with a missing/unparseable time.
        }

        final clamped = cloudCover.clamp(0.0, 100.0);
        final opacity = clamped / 100.0;
        final isForecast = timestamp.isAfter(now);

        // Point bounds: ±0.5° around the requested location, matching
        // Open-Meteo so frame geometry is identical across providers.
        frames.add(
          RadarFrame(
            timestamp: timestamp,
            tileUrlTemplate: '', // No tiles for this provider.
            north: latitude + 0.5,
            south: latitude - 0.5,
            east: longitude + 0.5,
            west: longitude - 0.5,
            opacity: opacity,
            isForecast: isForecast,
          ),
        );
      }

      if (frames.isEmpty) {
        return RadarFetchResult.error('No valid cloud cover data available');
      }

      return RadarFetchResult.success(frames);
    } on http.ClientException catch (e) {
      return RadarFetchResult.error('Network error: $e');
    } catch (e) {
      return RadarFetchResult.error('Unexpected error: $e');
    }
  }

  /// Extracts `data.instant.details.cloud_area_fraction` from a timeseries
  /// entry, or null if any link in the chain is missing or non-numeric.
  static double? _cloudCoverFraction(dynamic entry) {
    if (entry is! Map) return null;
    final data = entry['data'];
    if (data is! Map) return null;
    final instant = data['instant'];
    if (instant is! Map) return null;
    final details = instant['details'];
    if (details is! Map) return null;
    final value = details['cloud_area_fraction'];
    return value is num ? value.toDouble() : null;
  }

  /// Parses a timeseries entry's `time` field as a UTC instant. MET Norway
  /// timestamps carry a trailing 'Z', so a plain parse + `.toUtc()` is correct.
  /// Returns null if the field is missing or unparseable.
  static DateTime? _entryTime(dynamic entry) {
    if (entry is! Map) return null;
    final timeStr = entry['time'];
    if (timeStr is! String) return null;
    final parsed = DateTime.tryParse(timeStr);
    return parsed?.toUtc();
  }

  @override
  (Duration history, Duration forecast) getAvailableTimeRange() {
    // MET Norway has NO past data — the forecast starts at "now" — and reaches
    // out to roughly 9 days.
    return (Duration.zero, const Duration(days: 9));
  }

  @override
  String buildTileUrl(RadarFrame frame, int z, int x, int y) {
    // This provider doesn't have map tiles — cloud cover is stored as opacity.
    return '';
  }

  /// Fetches the current cloud cover percentage (0-100) at [lat]/[lon].
  ///
  /// Used as a same-endpoint fallback for the real-time cloud-cover signal that
  /// feeds the weather-safety triggers. Returns the `cloud_area_fraction` of
  /// the timeseries entry nearest to now, but only if that entry is within
  /// ±90 minutes (MET Norway's near-term cadence is hourly, so a wider gap
  /// means we'd be reporting stale data). Returns null on any failure.
  static Future<double?> fetchCurrentCloudCover(
    http.Client client,
    double lat,
    double lon,
  ) async {
    try {
      final uri = Uri.parse(_baseUrl).replace(
        queryParameters: {'lat': lat.toString(), 'lon': lon.toString()},
      );
      final response = await getWithTransientRetry(
        client,
        uri,
        headers: const {'User-Agent': _userAgent},
      );
      if (response.statusCode != 200) return null;

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final properties = json['properties'];
      if (properties is! Map<String, dynamic>) return null;
      final timeseries = properties['timeseries'];
      if (timeseries is! List) return null;

      final now = DateTime.now().toUtc();
      double? nearestCover;
      Duration? nearestGap;
      for (final entry in timeseries) {
        final cover = _cloudCoverFraction(entry);
        if (cover == null) continue;
        final time = _entryTime(entry);
        if (time == null) continue;
        final gap = time.difference(now).abs();
        if (nearestGap == null || gap < nearestGap) {
          nearestGap = gap;
          nearestCover = cover;
        }
      }

      if (nearestCover == null || nearestGap == null) return null;
      if (nearestGap > const Duration(minutes: 90)) return null;
      return nearestCover.clamp(0.0, 100.0);
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _httpClient.close();
    super.dispose();
  }
}
