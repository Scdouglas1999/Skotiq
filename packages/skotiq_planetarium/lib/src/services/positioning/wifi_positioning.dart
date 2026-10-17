import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import 'positioning_result.dart';
import 'wifi_scan.dart';

/// Turns a list of nearby access points into a position.
///
/// Both services speak the same request and reply format (Google defined it;
/// Mozilla's Ichnaea copied it, and beaconDB is Ichnaea's live successor), so
/// one client covers both and the only difference is the endpoint and whether
/// a key rides along.
class WifiPositioningProvider {
  /// Open, key-free, and community-mapped. The default because it costs
  /// nothing and asks for no account — but its coverage is only as good as
  /// the volunteers who have driven past, which is why the Google tier exists.
  static final Uri beaconDbEndpoint = Uri.parse(
    'https://api.beacondb.net/v1/geolocate',
  );

  static const String beaconDbName = 'beaconDB';

  /// Google's Geolocation API. Same request body; the key is a query
  /// parameter, so it never appears in the payload that could be logged
  /// alongside the BSSIDs.
  static Uri googleEndpoint(String apiKey) => Uri.parse(
    'https://www.googleapis.com/geolocation/v1/geolocate',
  ).replace(queryParameters: {'key': apiKey});

  static const String googleName = 'Google Location Services';

  /// How many access points ride along.
  ///
  /// The services weight by signal strength and stop gaining accuracy well
  /// before twenty; sending every radio a busy apartment block can hear only
  /// widens what leaves the machine.
  static const int maxAccessPointsSent = 20;

  /// The strongest [maxAccessPointsSent] of a scan, strongest first.
  static List<WifiAccessPoint> strongest(List<WifiAccessPoint> points) {
    final sorted = [...points]
      ..sort((a, b) => b.signalStrengthDbm.compareTo(a.signalStrengthDbm));
    return sorted.take(maxAccessPointsSent).toList(growable: false);
  }

  /// Build the geolocate request body.
  ///
  /// `considerIp: false` is the load-bearing field. Left at its default, both
  /// services answer an unmappable network list with an IP estimate instead of
  /// an error — beaconDB returns HTTP 200, `accuracy: 25000` and
  /// `fallback: "ipf"` — and a caller that only checked the status code would
  /// present a 25 km guess as a Wi-Fi fix. With it false, beaconDB answers 404
  /// `notFound` and the tier fails honestly.
  @visibleForTesting
  static String buildRequestBody(List<WifiAccessPoint> accessPoints) =>
      json.encode(<String, Object?>{
        'considerIp': false,
        'wifiAccessPoints': [
          for (final point in accessPoints) point.toGeolocateJson(),
        ],
      });

  /// Parse a geolocate reply into a fix, or null when it is not a Wi-Fi fix.
  ///
  /// Rejects any body carrying a `fallback` key even on HTTP 200: that is the
  /// service saying "I could not map your networks, here is your IP address
  /// instead". Belt and braces with `considerIp: false` — the flag stops the
  /// service volunteering it, this stops a future flag change from quietly
  /// turning an IP guess into a claimed Wi-Fi fix.
  @visibleForTesting
  static PositioningResult? parseGeolocateBody(
    String body, {
    required String provider,
    required int accessPointsUsed,
  }) {
    final decoded = json.decode(body);
    if (decoded is! Map<String, dynamic>) return null;
    if (decoded.containsKey('fallback')) return null;
    if (decoded['error'] != null) return null;

    final location = decoded['location'];
    if (location is! Map) return null;
    final lat = (location['lat'] as num?)?.toDouble();
    final lon = (location['lng'] as num?)?.toDouble();
    if (lat == null || lon == null) return null;

    return PositioningResult(
      latitude: lat,
      longitude: lon,
      accuracyMetres: (decoded['accuracy'] as num?)?.toDouble(),
      source: PositioningSource.wifiScan,
      provider: provider,
      accessPointsUsed: accessPointsUsed,
    );
  }

  /// Ask one service to place this machine from [accessPoints].
  ///
  /// Returns null on any refusal: a 404 `notFound` (the honest answer when the
  /// service has never seen these networks), a transport failure, or a reply
  /// that turns out to be an IP fallback.
  static Future<PositioningResult?> locate({
    required List<WifiAccessPoint> accessPoints,
    required Uri endpoint,
    required String provider,
    required http.Client Function() clientFactory,
  }) async {
    if (accessPoints.isEmpty) return null;
    final sent = strongest(accessPoints);
    final client = clientFactory();
    try {
      final response = await client
          .post(
            endpoint,
            headers: const {'Content-Type': 'application/json'},
            body: buildRequestBody(sent),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      return parseGeolocateBody(
        response.body,
        provider: provider,
        accessPointsUsed: sent.length,
      );
    } catch (e) {
      developer.log(
        '[Positioning] Wi-Fi lookup failed ($provider): $e',
        name: 'WifiPositioningProvider',
        level: 900,
        error: e,
      );
      return null;
    } finally {
      client.close();
    }
  }
}
