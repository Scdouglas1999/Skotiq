import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../models/errors/skotiq_error.dart';
import '../providers/settings_provider.dart' show LocationSettings;

/// Resolve an approximate observing site from the machine's public IP.
///
/// One owner for the "ask the internet where we are" request, because there
/// were two, and both of them used cleartext `http://ip-api.com/json`:
/// this one (the FfiBackend, which is what the headless appliance answers
/// `GET /api/location` with) and the desktop GUI's `GeolocationService`
/// fallback. ip-api.com's free tier answers 403 over HTTPS, so the request was
/// unencrypted by construction. The answer is not advisory — it is written into
/// `observer_latitude`/`observer_longitude`, which drive altitude/airmass,
/// meridian-flip timing and the horizon mask — so anyone on the path could
/// both read the observer's public IP and choose where the rig thinks it is.
///
/// City-centroid databases (ipwho.is, and ipapi.co when it answers) often pin
/// a metro ISP to the city hall. For a US residential IP that is the wrong
/// observatory: Weather, twilight and the horizon mask all follow the pin.
/// ipinfo.io's `loc` is typically ZIP-level, so it is the primary; ipwho.is
/// remains the TLS fallback when ipinfo refuses or rate-limits.
///
/// The second rule here is that an unusable answer is an error, never a
/// coordinate. Defaulting a missing `lat`/`lon` to `0.0` puts the rig on Null
/// Island — a real place in the Gulf of Guinea, where every target is up at
/// the wrong time.
class IpGeolocation {
  /// Primary lookup. Unauthenticated JSON; ZIP-level `loc` for US IPs.
  static final Uri endpoint = Uri.parse('https://ipinfo.io/json');

  /// TLS fallback when the primary is unreachable or has no coordinate.
  static final Uri fallbackEndpoint = Uri.parse('https://ipwho.is/');

  /// Client factory, injectable so a test can assert what goes on the wire.
  @visibleForTesting
  static http.Client Function() clientFactory = http.Client.new;

  /// Fetch the estimate. Throws a [SkotiqError] when both services are
  /// unreachable, refuse, or answer without a usable coordinate.
  static Future<LocationSettings> fetch() async {
    final client = clientFactory();
    SkotiqError? lastError;
    try {
      for (final uri in [endpoint, fallbackEndpoint]) {
        try {
          return await _fetchUri(client, uri);
        } on SkotiqError catch (e) {
          lastError = e;
        } catch (e) {
          lastError = SkotiqError(
            category: BackendErrorCategory.io,
            message: 'Error fetching location: $e',
            userMessage: 'Could not reach the location service at ${uri.host}.',
            isRecoverable: true,
          );
        }
      }
    } finally {
      client.close();
    }
    throw lastError!;
  }

  static Future<LocationSettings> _fetchUri(http.Client client, Uri uri) async {
    final response = await client.get(uri).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw SkotiqError(
        category: BackendErrorCategory.io,
        message: 'Failed to fetch location: HTTP ${response.statusCode}',
        userMessage:
            'The location service at ${uri.host} returned '
            'HTTP ${response.statusCode}.',
        isRecoverable: true,
      );
    }
    return parse(response.body);
  }

  /// Parse a response body into a site. Separate from [fetch] so the refusal
  /// rules are testable without a socket. Accepts ipinfo.io (`loc`) and
  /// ipwho.is / ipapi.co (`latitude` / `longitude`).
  @visibleForTesting
  static LocationSettings parse(String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (e) {
      throw SkotiqError(
        category: BackendErrorCategory.io,
        message: 'Location service returned a body that is not JSON: $e',
        userMessage: 'The location service returned an unreadable answer.',
        isRecoverable: true,
      );
    }
    final data = decoded is Map<String, dynamic> ? decoded : null;
    final coords = data == null ? null : _latLonFrom(data);
    if (coords == null) {
      throw SkotiqError(
        category: BackendErrorCategory.io,
        message:
            'Location service did not return a usable coordinate '
            '(${data?['message'] ?? body.trim()})',
        userMessage:
            'The location service could not estimate this machine\'s '
            'position. Enter the site coordinates manually.',
        isRecoverable: true,
      );
    }
    // Elevation is deliberately 0: neither IP service reports one, and
    // inventing the previous site's elevation is how a Pennsylvania fix ended
    // up 1234 m above sea level.
    //
    // Four decimals (~11 m) is finer than an IP estimate and stops a
    // seven-decimal city-centroid reply from looking like a surveyed pin.
    return LocationSettings(
      latitude: _roundIp(coords.$1),
      longitude: _roundIp(coords.$2),
      elevation: 0.0,
    );
  }

  /// Prefer `loc` ("lat,lon") when present: that is ipinfo's ZIP-level fix.
  /// `latitude`/`longitude` are the city-centroid fields the fallback uses.
  static (double, double)? _latLonFrom(Map<String, dynamic> data) {
    if (data['success'] == false || data['error'] == true) return null;
    if (data['error'] is Map) return null;

    double? lat;
    double? lon;
    final loc = data['loc'];
    if (loc is String) {
      final parts = loc.split(',');
      if (parts.length >= 2) {
        lat = double.tryParse(parts[0].trim());
        lon = double.tryParse(parts[1].trim());
      }
    }
    // Read as `num`: a whole-degree latitude serialises as `40`, not `40.0`,
    // and a `double` cast would throw on it.
    lat ??= (data['latitude'] as num?)?.toDouble();
    lon ??= (data['longitude'] as num?)?.toDouble();
    if (lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180) {
      return null;
    }
    return (lat, lon);
  }

  static double _roundIp(double value) =>
      double.parse(value.toStringAsFixed(4));
}
