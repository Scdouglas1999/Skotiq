import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../models/weather/cloud_cover_forecast.dart';
import '../../../models/weather/radar_frame.dart';
import '../radar_provider.dart';
import '../transient_http_retry.dart';

/// Numerical sky cover from the forecast office serving the observing site.
/// NWS merges equal hourly values into ISO-8601 intervals; a value belongs
/// to that whole interval, not merely the instant at its start.
/// See https://weather-gov.github.io/api/gridpoints.
class NwsCloudProvider {
  NwsCloudProvider({http.Client? httpClient, DateTime Function()? clock})
    : _client = httpClient ?? http.Client(),
      _ownsClient = httpClient == null,
      _clock = clock ?? DateTime.now;

  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _clock;
  final _inFlight = <(double, double), Future<List<_SkyCoverInterval>>>{};
  (double, double)? _cachedPoint;
  List<_SkyCoverInterval>? _cachedIntervals;
  DateTime? _cachedAt;
  bool _disposed = false;

  static const _cacheLifetime = Duration(minutes: 5);
  static const _maximumHourlyFrames = 14 * 24;
  static const _headers = {
    'User-Agent': 'Skotiq (+https://github.com/Scdouglas1999/Skotiq)',
    'Accept': 'application/geo+json',
  };

  String get name => 'National Weather Service';

  /// Hourly samples for planning, without map tiles or invented spatial data.
  Future<RadarFetchResult> fetchRadarFrames({
    required double latitude,
    required double longitude,
    double radiusKm = 100.0,
  }) async {
    try {
      final intervals = await _intervals(latitude, longitude);
      final now = _clock().toUtc();
      final frames = <RadarFrame>[];
      for (final interval in intervals) {
        for (
          var time = interval.start;
          time.isBefore(interval.end);
          time = time.add(const Duration(hours: 1))
        ) {
          if (frames.length == _maximumHourlyFrames) {
            return RadarFetchResult.error(
              'NWS returned more than 14 days of hourly sky cover.',
            );
          }
          frames.add(
            RadarFrame(
              timestamp: time,
              tileUrlTemplate: '',
              north: (latitude + 0.5).clamp(-90.0, 90.0),
              south: (latitude - 0.5).clamp(-90.0, 90.0),
              east: (longitude + 0.5).clamp(-180.0, 180.0),
              west: (longitude - 0.5).clamp(-180.0, 180.0),
              opacity: interval.percent / 100,
              isForecast: time.isAfter(now),
            ),
          );
        }
      }
      return RadarFetchResult.success(frames, providerName: name);
    } on _NwsUnavailable catch (error) {
      return RadarFetchResult.error(error.message);
    }
  }

  /// The interval containing now, never a nearest point outside its coverage.
  /// A null result leaves another provider free to answer; it is not 0% cloud.
  Future<CloudCoverForecast?> fetchCurrentCloudForecast({
    required double latitude,
    required double longitude,
  }) async {
    try {
      final intervals = await _intervals(latitude, longitude);
      final now = _clock().toUtc();
      for (final interval in intervals) {
        if (!now.isBefore(interval.start) && now.isBefore(interval.end)) {
          return CloudCoverForecast(
            percent: interval.percent,
            source: name,
            validAt: interval.start,
          );
        }
      }
      return null;
    } on _NwsUnavailable {
      return null;
    }
  }

  Future<List<_SkyCoverInterval>> _intervals(
    double latitude,
    double longitude,
  ) {
    if (_disposed) {
      return Future.error(const _NwsUnavailable('NWS provider is closed.'));
    }
    if (!latitude.isFinite ||
        !longitude.isFinite ||
        latitude.abs() > 90 ||
        longitude.abs() > 180) {
      return Future.error(
        const _NwsUnavailable('The observing coordinates are invalid.'),
      );
    }
    final point = (latitude, longitude);
    final cachedAt = _cachedAt;
    if (_cachedPoint == point && cachedAt != null) {
      final age = _clock().toUtc().difference(cachedAt);
      if (!age.isNegative && age < _cacheLifetime) {
        return Future.value(_cachedIntervals!);
      }
    }
    final pending = _inFlight[point];
    if (pending != null) return pending;
    final request = _fetchIntervals(latitude, longitude).then((intervals) {
      if (!_disposed) {
        _cachedPoint = point;
        _cachedIntervals = intervals;
        _cachedAt = _clock().toUtc();
      }
      return intervals;
    });
    _inFlight[point] = request;
    return request.whenComplete(() => _inFlight.remove(point));
  }

  Future<List<_SkyCoverInterval>> _fetchIntervals(
    double latitude,
    double longitude,
  ) async {
    final points = await _getJson(
      Uri.https('api.weather.gov', '/points/$latitude,$longitude'),
    );
    final properties = points['properties'];
    final gridLink = properties is Map ? properties['forecastGridData'] : null;
    final grid = gridLink is String ? Uri.tryParse(gridLink) : null;
    if (grid == null ||
        grid.scheme != 'https' ||
        grid.host != 'api.weather.gov' ||
        grid.port != 443 ||
        grid.userInfo.isNotEmpty ||
        !grid.path.startsWith('/gridpoints/')) {
      throw const _NwsUnavailable(
        'NWS did not return a forecast grid for this site.',
      );
    }
    final data = await _getJson(grid);
    final gridProperties = data['properties'];
    final cover = gridProperties is Map ? gridProperties['skyCover'] : null;
    if (cover is! Map ||
        cover['uom'] != 'wmoUnit:percent' ||
        cover['values'] is! List) {
      throw const _NwsUnavailable(
        'NWS did not return numerical sky cover in percent.',
      );
    }
    final values = cover['values'] as List;
    if (values.length > 4096) {
      throw const _NwsUnavailable('NWS returned too many sky-cover intervals.');
    }
    final intervals = <_SkyCoverInterval>[];
    for (final value in values) {
      final parsed = _SkyCoverInterval.parse(value);
      if (parsed != null) intervals.add(parsed);
    }
    if (intervals.isEmpty) {
      throw const _NwsUnavailable(
        'NWS has no usable sky-cover intervals for this site.',
      );
    }
    intervals.sort((a, b) => a.start.compareTo(b.start));
    for (var i = 1; i < intervals.length; i++) {
      if (intervals[i].start.isBefore(intervals[i - 1].end)) {
        throw const _NwsUnavailable(
          'NWS returned overlapping sky-cover intervals.',
        );
      }
    }
    return intervals;
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    try {
      final response = await getWithTransientRetry(
        _client,
        uri,
        maxAttempts: 2,
        perAttemptTimeout: const Duration(seconds: 8),
        headers: _headers,
      );
      if (response.statusCode != 200) {
        throw _NwsUnavailable('NWS returned HTTP ${response.statusCode}.');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const _NwsUnavailable('NWS returned an unreadable forecast.');
      }
      return decoded;
    } on FormatException {
      throw const _NwsUnavailable('NWS returned an unreadable forecast.');
    } on TimeoutException {
      throw const _NwsUnavailable('The NWS request timed out.');
    } on SocketException {
      throw const _NwsUnavailable('NWS could not be reached.');
    } on TlsException {
      throw const _NwsUnavailable(
        'A secure connection to NWS could not be established.',
      );
    } on http.ClientException {
      throw const _NwsUnavailable('NWS could not be reached.');
    }
  }

  void dispose() {
    _disposed = true;
    _cachedIntervals = null;
    _cachedAt = null;
    if (_ownsClient) _client.close();
  }
}

class _SkyCoverInterval {
  const _SkyCoverInterval(this.start, this.end, this.percent);

  final DateTime start;
  final DateTime end;
  final double percent;

  static final _timestamp = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?(Z|[+-]\d{2}:\d{2})$',
  );
  static final _duration = RegExp(
    r'^P(?:(\d+(?:\.\d+)?)D)?(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?)?$',
  );

  static _SkyCoverInterval? parse(Object? entry) {
    if (entry is! Map) return null;
    final percent = entry['value'];
    final validTime = entry['validTime'];
    if (percent is! num ||
        !percent.isFinite ||
        percent < 0 ||
        percent > 100 ||
        validTime is! String) {
      return null;
    }
    final parts = validTime.split('/');
    if (parts.length != 2 || parts.last.endsWith('T')) return null;
    final start = _parseStart(parts.first);
    final duration = _duration.firstMatch(parts.last);
    if (start == null || duration == null) return null;
    double units(int group) =>
        double.tryParse(duration.group(group) ?? '0') ?? double.nan;
    final seconds =
        units(1) * 86400 + units(2) * 3600 + units(3) * 60 + units(4);
    // NWS supplies about a week. Reject absurd durations before expansion,
    // instead of allocating years of hourly values from a malformed reply.
    if (!seconds.isFinite || seconds <= 0 || seconds > 14 * 86400) return null;
    final span = Duration(
      microseconds: (seconds * Duration.microsecondsPerSecond).round(),
    );
    if (span == Duration.zero) return null;
    return _SkyCoverInterval(start, start.add(span), percent.toDouble());
  }

  static DateTime? _parseStart(String value) {
    final fields = _timestamp.firstMatch(value);
    if (fields == null) return null;
    int field(int index) => int.parse(fields.group(index)!);
    final year = field(1);
    final month = field(2);
    final day = field(3);
    final date = DateTime.utc(year, month, day);
    // DateTime.parse normalizes February 30 and hour 25. A forecast must not
    // silently acquire a different valid date when its input is malformed.
    if (date.year != year ||
        date.month != month ||
        date.day != day ||
        field(4) > 23 ||
        field(5) > 59 ||
        (fields.group(6) != null && field(6) > 59)) {
      return null;
    }
    final offset = fields.group(7)!;
    if (offset != 'Z' &&
        (int.parse(offset.substring(1, 3)) > 23 ||
            int.parse(offset.substring(4)) > 59)) {
      return null;
    }
    return DateTime.tryParse(value)?.toUtc();
  }
}

class _NwsUnavailable implements Exception {
  const _NwsUnavailable(this.message);

  final String message;
}
