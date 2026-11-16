import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:skotiq_astro/skotiq_astro.dart';

import '../../../models/weather/current_sky.dart';
import '../transient_http_retry.dart';

/// The latest METAR reports around the site from the Aviation Weather Center
/// (aviationweather.gov, worldwide, no key). See
/// https://aviationweather.gov/data/api/.
class MetarStationProvider {
  MetarStationProvider({
    required http.Client client,
    DateTime Function()? clock,
  }) : _client = client,
       _clock = clock ?? DateTime.now;

  final http.Client _client;
  final DateTime Function() _clock;

  static const _automatedCeilingFeet = 12000;
  static const _cavokCeilingFeet = 5000;

  /// The nearest station within [StationSky.maximumDistanceKm] whose report
  /// is younger than [StationSky.maximumAge] and states a cloud amount, or null when there is none
  /// or the service cannot be reached.
  Future<StationSky?> nearest({
    required double latitude,
    required double longitude,
  }) async {
    final List<Object?> reports;
    try {
      final response = await getWithTransientRetry(
        _client,
        _searchArea(latitude, longitude),
        maxAttempts: 2,
        perAttemptTimeout: const Duration(seconds: 10),
        headers: const {
          'User-Agent': 'Skotiq (+https://github.com/Scdouglas1999/Skotiq)',
        },
      );
      // 204 is the service's answer for an area with no reports.
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is! List) return null;
      reports = decoded;
    } on FormatException {
      return null;
    } on TimeoutException {
      return null;
    } on SocketException {
      return null;
    } on TlsException {
      return null;
    } on http.ClientException {
      return null;
    }

    final now = _clock().toUtc();
    StationSky? best;
    for (final report in reports) {
      final sky = _parse(report, latitude, longitude);
      if (sky == null ||
          sky.distanceKm > StationSky.maximumDistanceKm ||
          now.difference(sky.observedAt) > StationSky.maximumAge ||
          sky.observedAt.isAfter(now.add(const Duration(minutes: 10)))) {
        continue;
      }
      if (best == null || sky.distanceKm < best.distanceKm) best = sky;
    }
    return best;
  }

  /// A box of about ±45 km around the site, its center rounded to 0.1° so
  /// the request does not carry the site's exact position.
  static Uri _searchArea(double latitude, double longitude) {
    double tenth(double degrees) => (degrees * 10).roundToDouble() / 10;
    final lat = tenth(latitude);
    final lon = tenth(longitude);
    final dLon = (0.5 / math.cos(lat.abs().clamp(0, 80) * math.pi / 180)).clamp(
      0.5,
      3.0,
    );
    String f(double v) => v.toStringAsFixed(1);
    final bbox = [
      f((lat - 0.5).clamp(-90, 90)),
      f((lon - dLon).clamp(-180, 180)),
      f((lat + 0.5).clamp(-90, 90)),
      f((lon + dLon).clamp(-180, 180)),
    ].join(',');
    return Uri.https('aviationweather.gov', '/api/data/metar', {
      'bbox': bbox,
      'format': 'json',
    });
  }

  StationSky? _parse(Object? report, double latitude, double longitude) {
    if (report is! Map) return null;
    final id = report['icaoId'];
    final lat = report['lat'];
    final lon = report['lon'];
    final obsTime = report['obsTime'];
    if (id is! String || lat is! num || lon is! num || obsTime is! int) {
      return null;
    }
    final amount = _amount(report);
    if (amount == null) return null;
    final raw = report['rawOb'];
    final automated = raw is String && RegExp(r'\bAUTO\b').hasMatch(raw);
    final cover = report['cover'];
    final name = report['name'];
    return StationSky(
      stationId: id,
      stationName: name is String ? name : id,
      distanceKm: _distanceKm(
        latitude,
        longitude,
        lat.toDouble(),
        lon.toDouble(),
      ),
      observedAt: DateTime.fromMillisecondsSinceEpoch(
        obsTime * 1000,
        isUtc: true,
      ),
      amount: amount,
      seesUpToFeet: cover == 'CAVOK'
          ? _cavokCeilingFeet
          : automated
          ? _automatedCeilingFeet
          : null,
    );
  }

  /// The summary cover, else the most covering layer: METAR layer amounts
  /// accumulate upward, so the largest one is the total.
  static CloudAmount? _amount(Map<Object?, Object?> report) {
    final cover = report['cover'];
    final summary = cover is String ? CloudAmount.fromMetar(cover) : null;
    if (summary != null) return summary;
    CloudAmount? most;
    final layers = report['clouds'];
    if (layers is! List) return null;
    for (final layer in layers) {
      final code = layer is Map ? layer['cover'] : null;
      final amount = code is String ? CloudAmount.fromMetar(code) : null;
      if (amount != null && (most == null || amount.percent > most.percent)) {
        most = amount;
      }
    }
    return most;
  }

  /// Great-circle distance on a sphere of the Earth's mean radius.
  static double _distanceKm(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadiusKm = 6371.0;
    final degrees = AstronomyCalculations.angularSeparation(
      ra1Deg: lon1,
      dec1Deg: lat1,
      ra2Deg: lon2,
      dec2Deg: lat2,
    );
    return degrees * math.pi / 180 * earthRadiusKm;
  }
}
