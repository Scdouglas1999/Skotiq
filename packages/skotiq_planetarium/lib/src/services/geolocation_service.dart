import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:geolocator/geolocator.dart';

import 'positioning/positioning_result.dart';
import 'positioning/wifi_positioning.dart';
import 'positioning/wifi_scan.dart';

export 'positioning/positioning_result.dart';
export 'positioning/wifi_positioning.dart';
export 'positioning/wifi_scan.dart';

/// A named place from the geocoding lookup. Town-accurate, with elevation
/// when the service has a DEM sample — unlike an IP estimate, which is a
/// ZIP or city centroid with elevation 0.
class PlaceSearchHit {
  const PlaceSearchHit({
    required this.latitude,
    required this.longitude,
    required this.label,
    this.elevation,
  });

  final double latitude;
  final double longitude;
  final double? elevation;
  final String label;
}

class GeolocationService {
  /// Client used for the IP-geolocation lookups. Injectable so a test can
  /// assert what actually goes on the wire — the transport of these requests
  /// is the point (see [fetchLocationFromIPAlternative]), and a hard-coded
  /// `http.get` cannot be inspected.
  @visibleForTesting
  static http.Client Function() clientFactory = http.Client.new;

  /// Read a JSON coordinate that may arrive as an int (a whole-degree
  /// latitude serialises as `40`, not `40.0`). A bare `as double?` throws on
  /// that, and every call site here swallows the throw — so the lookup would
  /// silently report "no location" for anyone who happens to sit on a round
  /// degree.
  static double? _coord(Object? value) => (value as num?)?.toDouble();

  /// Primary IP lookup. ipinfo.io's `loc` is typically ZIP-level for US
  /// residential IPs; city-centroid services pin a metro ISP to city hall,
  /// which is where Weather then draws the observatory.
  static final Uri ipPrimaryEndpoint = Uri.parse('https://ipinfo.io/json');

  /// TLS fallback when the primary is unreachable or has no coordinate.
  static final Uri ipFallbackEndpoint = Uri.parse('https://ipwho.is/');

  /// Open-Meteo geocoding. Same vendor as the cloud forecast, TLS, no key.
  static final Uri placeSearchEndpoint = Uri.parse(
    'https://geocoding-api.open-meteo.com/v1/search',
  );

  /// Fetch location from IP using ipinfo.io (free, no API key required).
  /// Returns (latitude, longitude, locationName) or null if failed.
  static Future<(double latitude, double longitude, String? locationName)?>
  fetchLocationFromIP() async => _tupleOf(await _fetchIp(ipPrimaryEndpoint));

  /// Fallback for when the primary service is unreachable or rate-limited.
  /// The fallback must remain HTTPS because its coordinates become the active
  /// observing site.
  static Future<(double latitude, double longitude, String? locationName)?>
  fetchLocationFromIPAlternative() async =>
      _tupleOf(await _fetchIp(ipFallbackEndpoint));

  /// The internet lookup with its provenance attached: which host answered
  /// rides along so the caller can say "from your internet address
  /// (ipwho.is)" instead of presenting an estimate as a fix.
  static Future<PositioningResult?> _fetchIp(Uri uri) async {
    final client = clientFactory();
    try {
      final response = await client
          .get(uri)
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return null;
      final parsed = _parseIpBody(response.body);
      if (parsed == null) return null;
      return PositioningResult(
        latitude: parsed.$1,
        longitude: parsed.$2,
        locationName: parsed.$3,
        source: PositioningSource.ipAddress,
        provider: uri.host,
        // Neither IP service reports a radius. Left null rather than filled
        // with a plausible number: the explanation then says "city level",
        // which is true, instead of a metre figure nobody measured.
      );
    } catch (e) {
      developer.log(
        '[Geolocation] IP-based location failed (${uri.host}): $e',
        name: 'GeolocationService',
        level: 900,
        error: e,
      );
    } finally {
      client.close();
    }
    return null;
  }

  /// Primary internet lookup, then the fallback when it refuses.
  static Future<PositioningResult?> _internetFix() async {
    final fix = await _fetchIp(ipPrimaryEndpoint);
    if (fix != null) return fix;
    return _fetchIp(ipFallbackEndpoint);
  }

  static (double, double, String?)? _tupleOf(PositioningResult? fix) =>
      fix == null ? null : (fix.latitude, fix.longitude, fix.locationName);

  /// ipinfo.io uses `loc` ("lat,lon"); ipwho.is / ipapi.co use
  /// `latitude`/`longitude`. Prefer `loc` when both exist — that is the
  /// ZIP-level fix. Round to four decimals so a seven-decimal city-centroid
  /// reply cannot look surveyed.
  static (double, double, String?)? _parseIpBody(String body) {
    final decoded = json.decode(body);
    if (decoded is! Map<String, dynamic>) return null;
    if (decoded['success'] == false || decoded['error'] == true) return null;
    if (decoded['error'] is Map) return null;

    double? lat;
    double? lon;
    final loc = decoded['loc'];
    if (loc is String) {
      final parts = loc.split(',');
      if (parts.length >= 2) {
        lat = double.tryParse(parts[0].trim());
        lon = double.tryParse(parts[1].trim());
      }
    }
    lat ??= _coord(decoded['latitude']);
    lon ??= _coord(decoded['longitude']);
    if (lat == null || lon == null) return null;

    return (
      double.parse(lat.toStringAsFixed(4)),
      double.parse(lon.toStringAsFixed(4)),
      _ipLocationName(decoded),
    );
  }

  /// City + region, plus a country name when the service sent one. Skip a
  /// two-letter ISO code so ipinfo's `"country":"US"` does not become the
  /// label "Broomall, Pennsylvania, US".
  static String? _ipLocationName(Map<String, dynamic> data) {
    final city = data['city'] as String?;
    final region = data['region'] as String?;
    final country =
        (data['country_name'] as String?) ?? data['country'] as String?;
    final parts = <String>[
      if (city != null && city.isNotEmpty) city,
      if (region != null && region.isNotEmpty) region,
      if (country != null && country.length > 2) country,
    ];
    return parts.isEmpty ? null : parts.join(', ');
  }

  /// Try to fetch location, using primary service first, then fallback
  static Future<(double latitude, double longitude, String? locationName)?>
  fetchLocation() async => _tupleOf(await _internetFix());

  /// Look up a town, observatory, or address by name.
  ///
  /// This is the accurate desktop path: a wired observatory PC has no GPS and
  /// its public IP geolocates to the ISP's city, often a town over. The
  /// operator types the place they actually observe from.
  static Future<List<PlaceSearchHit>> searchPlaces(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    final uri = placeSearchEndpoint.replace(
      queryParameters: <String, String>{
        'name': trimmed,
        'count': '6',
        'language': 'en',
        'format': 'json',
      },
    );
    final client = clientFactory();
    try {
      final response = await client
          .get(uri, headers: const {'User-Agent': 'Skotiq/observatory'})
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return const [];
      return parsePlaceSearchBody(response.body);
    } catch (e) {
      developer.log(
        '[Geolocation] Place search failed: $e',
        name: 'GeolocationService',
        level: 900,
        error: e,
      );
      return const [];
    } finally {
      client.close();
    }
  }

  /// Parse an Open-Meteo geocoding body. Public so a test can pin the
  /// coordinate + elevation extraction without a socket.
  @visibleForTesting
  static List<PlaceSearchHit> parsePlaceSearchBody(String body) {
    final decoded = json.decode(body);
    if (decoded is! Map<String, dynamic>) return const [];
    final results = decoded['results'];
    if (results is! List) return const [];

    final hits = <PlaceSearchHit>[];
    for (final raw in results) {
      if (raw is! Map) continue;
      final data = Map<String, dynamic>.from(raw);
      final lat = _coord(data['latitude']);
      final lon = _coord(data['longitude']);
      if (lat == null || lon == null) continue;
      final name = data['name'] as String?;
      if (name == null || name.isEmpty) continue;
      final admin1 = data['admin1'] as String?;
      final country = data['country'] as String?;
      final parts = <String>[
        name,
        if (admin1 != null && admin1.isNotEmpty) admin1,
        if (country != null && country.isNotEmpty) country,
      ];
      hits.add(
        PlaceSearchHit(
          latitude: double.parse(lat.toStringAsFixed(4)),
          longitude: double.parse(lon.toStringAsFixed(4)),
          elevation: _coord(data['elevation']),
          label: parts.join(', '),
        ),
      );
    }
    return hits;
  }

  /// Scanner used for the Wi-Fi tier. Injectable so the tier ordering, the
  /// radio-power flow and the honest-failure paths are all driven in tests
  /// without a wireless card.
  @visibleForTesting
  static WifiScanner Function() scannerFactory = WifiScanner.new;

  /// Resolve this machine's position as precisely as the machine allows.
  ///
  /// Three tiers, tried in order, stopping at the first fix inside
  /// [PositioningResult.preciseMetres]:
  ///
  ///  1. **The platform's own location service.** Free and offline where it
  ///     works: Windows Location Services fuses Wi-Fi and IP and reports a
  ///     radius in metres. It is also absent on most observatory desktops —
  ///     GeoClue is not installed on a typical Linux box — and when it does
  ///     answer it may answer with the same IP-derived kilometres as tier 3.
  ///  2. **A Wi-Fi scan resolved by a positioning service.** This is the tier
  ///     that puts the rig in its own yard: the BSSIDs of the radios within
  ///     earshot, with how loud each one is, trilaterate to tens of metres
  ///     where the service has coverage. Google first when the operator has
  ///     supplied a key (much larger map), then key-free beaconDB.
  ///  3. **The public-IP estimate.** Always available, never precise: it
  ///     resolves the internet provider's hand-off, which is a town over.
  ///
  /// A coarse answer from an earlier tier does not stop the search, and the
  /// smallest radius wins, so a 25 km platform answer can never beat a 40 m
  /// Wi-Fi one. Every tier's outcome is reported whether or not it answered,
  /// so a total failure names its causes.
  ///
  /// [mayEnableWifiRadio] is the only thing here that changes the machine's
  /// state: with it set, a switched-off radio is switched on for the scan and
  /// switched back off afterwards. It is false on the first attempt and set
  /// only by an explicit "Turn Wi-Fi on for a precise fix" click.
  static Future<PositioningAttempt> locate({
    required bool allowWifiScan,
    required bool allowIp,
    bool mayEnableWifiRadio = false,
    String? googleApiKey,
  }) async {
    final outcomes = <TierOutcome>[];
    PositioningResult? best;
    var wifiRadioOff = false;
    var wifiRadioCanBeEnabled = false;

    void consider(PositioningResult? candidate) {
      if (candidate == null) return;
      if (best == null || candidate.accuracyRank < best!.accuracyRank) {
        best = candidate;
      }
    }

    bool done() => best?.isPrecise ?? false;

    final platform = await _platformServiceFix();
    outcomes.add(platform.$2);
    consider(platform.$1);

    if (!done() && allowWifiScan) {
      final scanner = scannerFactory();
      var enabledHere = false;
      try {
        if (mayEnableWifiRadio && await scanner.radioIsOff()) {
          enabledHere = await scanner.enableRadio();
        }
        final outcome = await scanner.scan();
        switch (outcome) {
          case WifiScanOk(:final accessPoints):
            final fix = await _wifiFix(accessPoints, googleApiKey);
            consider(fix);
            outcomes.add(
              TierOutcome(
                tier: PositioningTier.wifiScan,
                succeeded: fix != null,
                detail: fix != null
                    ? outcome.detail
                    : '${outcome.detail} No positioning service has mapped '
                          'them, so they give no fix here.',
              ),
            );
          case WifiScanRadioOff():
            wifiRadioOff = true;
            wifiRadioCanBeEnabled = scanner.canToggleRadio;
            outcomes.add(
              TierOutcome(
                tier: PositioningTier.wifiScan,
                succeeded: false,
                detail: outcome.detail,
              ),
            );
          case WifiScanNoAdapter():
          case WifiScanNoNetworks():
          case WifiScanUnsupportedPlatform():
            outcomes.add(
              TierOutcome(
                tier: PositioningTier.wifiScan,
                succeeded: false,
                detail: outcome.detail,
              ),
            );
        }
      } finally {
        // Restore the radio the operator left off, whatever happened above.
        if (enabledHere) await scanner.disableRadio();
      }
    }

    if (!done() && allowIp) {
      final fix = await _internetFix();
      consider(fix);
      outcomes.add(
        TierOutcome(
          tier: PositioningTier.ipAddress,
          succeeded: fix != null,
          detail: fix != null
              ? 'Your internet provider places you near '
                    '${fix.locationName ?? 'the coordinates shown'}.'
              : 'Neither ${ipPrimaryEndpoint.host} nor '
                    '${ipFallbackEndpoint.host} answered.',
        ),
      );
    }

    return PositioningAttempt(
      fix: best,
      outcomes: outcomes,
      wifiRadioOff: wifiRadioOff,
      wifiRadioCanBeEnabled: wifiRadioCanBeEnabled,
    );
  }

  /// Google when the operator supplied a key, then beaconDB.
  ///
  /// Google first because coverage is the whole reason a key is worth
  /// entering: beaconDB is volunteer-mapped and has none in plenty of
  /// suburbs. beaconDB still runs after a Google refusal — a mistyped or
  /// expired key must not cost the tier entirely.
  static Future<PositioningResult?> _wifiFix(
    List<WifiAccessPoint> accessPoints,
    String? googleApiKey,
  ) async {
    final key = googleApiKey?.trim();
    if (key != null && key.isNotEmpty) {
      final google = await WifiPositioningProvider.locate(
        accessPoints: accessPoints,
        endpoint: WifiPositioningProvider.googleEndpoint(key),
        provider: WifiPositioningProvider.googleName,
        clientFactory: clientFactory,
      );
      if (google != null) return google;
    }
    return WifiPositioningProvider.locate(
      accessPoints: accessPoints,
      endpoint: WifiPositioningProvider.beaconDbEndpoint,
      provider: WifiPositioningProvider.beaconDbName,
      clientFactory: clientFactory,
    );
  }

  /// What the platform's location stack calls itself, so the confirmation can
  /// name it rather than saying "the device".
  static String get _platformServiceName => switch (Platform.operatingSystem) {
    'windows' => 'Windows Location Services',
    'macos' => 'macOS Location Services',
    'linux' => 'GeoClue',
    final other => other,
  };

  /// Tier 1: the operating system's own location service, via `geolocator`.
  ///
  /// Returns the fix and the line describing what happened, because "there is
  /// no location service on this machine" and "you denied it" are different
  /// things to tell the operator and neither is visible from a null.
  static Future<(PositioningResult?, TierOutcome)> _platformServiceFix() async {
    TierOutcome failed(String detail) => TierOutcome(
      tier: PositioningTier.platformService,
      succeeded: false,
      detail: detail,
    );

    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return (
          null,
          failed('This machine’s location service is switched off.'),
        );
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return (
          null,
          failed(
            'Skotiq is not permitted to use this machine’s '
            'location service.',
          ),
        );
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: Duration(seconds: 10),
        ),
      );

      // geolocator reports 0.0 when the platform measured no accuracy at all.
      // Carried through as a real radius it would claim a surveyed fix and
      // stop the search at tier 1; as null it ranks below every tier that
      // does report one.
      final accuracy = position.accuracy > 0 ? position.accuracy : null;
      final fix = PositioningResult(
        latitude: position.latitude,
        longitude: position.longitude,
        source: PositioningSource.platformService,
        provider: _platformServiceName,
        accuracyMetres: accuracy,
      );
      return (
        fix,
        TierOutcome(
          tier: PositioningTier.platformService,
          succeeded: true,
          detail: fix.explanation,
        ),
      );
    } catch (e) {
      developer.log(
        '[Geolocation] Platform location service failed: $e',
        name: 'GeolocationService',
        level: 900,
        error: e,
      );
      return (null, failed('This machine has no working location service.'));
    }
  }
}
