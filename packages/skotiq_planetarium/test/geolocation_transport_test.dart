// Nothing this service sends may go out in the clear.
//
// `GeolocationService` is what Settings → Location's "Detect Location" and the
// first-run site step both call. On a desktop the GPS attempt always fails, so
// the IP fallback is the path that actually runs, and a cleartext endpoint like
// `http://ip-api.com/json/` is tempting because that service answers 403 over
// HTTPS on its free tier. The reply becomes the operator's stored
// latitude/longitude, so a passer-by on the network would both see the public
// IP go out and get to pick where the rig thinks it is.
//
// The assertion is on the SCHEME of every request that leaves, not on a
// vendor name: swapping providers later must not be able to reintroduce
// cleartext. The primary is ipinfo.io (ZIP-level `loc`); the fallback is
// ipwho.is. City-centroid replies must not be stored as seven-decimal pins.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_planetarium/src/services/geolocation_service.dart';

/// Drives the device half of `fetchLocationFromGPS` without a GPS receiver:
/// `Geolocator` delegates straight to `GeolocatorPlatform.instance`, so a
/// fake that reports services disabled or answers a fix is the machine the
/// service sees.
class _FakeGeolocatorPlatform extends GeolocatorPlatform {
  _FakeGeolocatorPlatform({this.position, this.enabled = true});

  final Position? position;
  final bool enabled;

  @override
  Future<bool> isLocationServiceEnabled() async => enabled;

  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.whileInUse;

  @override
  Future<LocationPermission> requestPermission() async =>
      LocationPermission.whileInUse;

  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async {
    final fix = position;
    if (fix == null) throw StateError('no fix');
    return fix;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final saved = GeolocationService.clientFactory;
  final savedScanner = GeolocationService.scannerFactory;
  final savedGeolocator = GeolocatorPlatform.instance;
  tearDown(() {
    GeolocationService.clientFactory = saved;
    GeolocationService.scannerFactory = savedScanner;
    GeolocatorPlatform.instance = savedGeolocator;
  });

  test(
    'every IP-geolocation request is HTTPS, including the fallback',
    () async {
      final requests = <Uri>[];
      GeolocationService.clientFactory = () => MockClient((request) async {
        requests.add(request.url);
        // Answer the primary the way it answers a rate-limited caller: HTTP
        // 200 with no coordinate. That is what pushes the service onto the
        // fallback leg, which must also be HTTPS.
        if (request.url.host.contains('ipinfo.io')) {
          return http.Response('{"error":{"title":"RateLimit"}}', 200);
        }
        return http.Response(
          '{"success":true,"latitude":39.9527,"longitude":-75.1635,'
          '"city":"Philadelphia","region":"Pennsylvania",'
          '"country":"United States"}',
          200,
        );
      });

      final result = await GeolocationService.fetchLocation();

      expect(
        requests.length,
        greaterThanOrEqualTo(2),
        reason:
            'the fallback leg has to have run for this test to mean '
            'anything',
      );
      for (final uri in requests) {
        expect(
          uri.scheme,
          'https',
          reason: '$uri left the machine in the clear',
        );
      }
      expect(result, isNotNull);
      expect(result!.$1, closeTo(39.9527, 1e-6));
      expect(result.$2, closeTo(-75.1635, 1e-6));
      expect(result.$3, 'Philadelphia, Pennsylvania, United States');
    },
  );

  test('ipinfo loc is the coordinate, not a city-hall centroid', () async {
    GeolocationService.clientFactory = () => MockClient((request) async {
      return http.Response(
        '{"city":"Broomall","region":"Pennsylvania","country":"US",'
        '"loc":"39.9815,-75.3566"}',
        200,
      );
    });

    final result = await GeolocationService.fetchLocationFromIP();

    expect(result, isNotNull);
    expect(result!.$1, closeTo(39.9815, 1e-6));
    expect(result.$2, closeTo(-75.3566, 1e-6));
    expect(result.$3, 'Broomall, Pennsylvania');
  });

  test('a seven-decimal city-centroid is rounded to four decimals', () async {
    GeolocationService.clientFactory = () => MockClient((request) async {
      return http.Response(
        '{"success":true,"latitude":39.9523835,'
        '"longitude":-75.1636197,"city":"Philadelphia"}',
        200,
      );
    });

    final result = await GeolocationService.fetchLocationFromIPAlternative();

    expect(result, isNotNull);
    expect(result!.$1, 39.9524);
    expect(result.$2, -75.1636);
  });

  test('a whole-degree coordinate is not silently dropped', () async {
    // `latitude: 40` decodes as an int, so an `as double?` cast throws — and
    // every catch here swallows the throw, which would tell an operator on a
    // round degree that no location could be found.
    GeolocationService.clientFactory = () => MockClient((request) async {
      return http.Response(
        '{"latitude":40,"longitude":-75,"city":"Somewhere"}',
        200,
      );
    });

    final result = await GeolocationService.fetchLocationFromIP();

    expect(result, isNotNull);
    expect(result!.$1, 40.0);
    expect(result.$2, -75.0);
  });

  test(
    'place search is HTTPS and returns the named town plus elevation',
    () async {
      final requests = <Uri>[];
      GeolocationService.clientFactory = () => MockClient((request) async {
        requests.add(request.url);
        return http.Response(
          '{"results":[{"name":"Newtown Square","latitude":39.98678,'
          '"longitude":-75.40103,"elevation":127,"admin1":"Pennsylvania",'
          '"country":"United States"}]}',
          200,
        );
      });

      final hits = await GeolocationService.searchPlaces('Newtown Square');

      expect(requests, hasLength(1));
      expect(requests.single.scheme, 'https');
      expect(requests.single.host, 'geocoding-api.open-meteo.com');
      expect(hits, hasLength(1));
      expect(hits.single.latitude, 39.9868);
      expect(hits.single.longitude, -75.4010);
      expect(hits.single.elevation, 127);
      expect(hits.single.label, 'Newtown Square, Pennsylvania, United States');
    },
  );

  test('an empty place query does not leave the machine', () async {
    var calls = 0;
    GeolocationService.clientFactory = () => MockClient((request) async {
      calls++;
      return http.Response('{}', 200);
    });

    expect(await GeolocationService.searchPlaces('  '), isEmpty);
    expect(calls, 0);
  });

  // The click behind Detect location walks three tiers. What is pinned here is
  // the ORDER and the ARBITRATION: the smallest radius wins, a coarse answer
  // never stops the search, and a positioning service's own IP fallback is
  // never allowed to pass as a Wi-Fi fix.

  test('a precise Wi-Fi fix beats a coarse platform fix', () async {
    GeolocatorPlatform.instance = _FakeGeolocatorPlatform(
      position: _positionAt(39.90, -75.30, accuracy: 24000),
    );
    GeolocationService.scannerFactory = () => WifiScanner(
      runner: _nmcliRunner(_twoNetworks),
      operatingSystem: 'linux',
    );
    GeolocationService.clientFactory = () => MockClient((request) async {
      expect(request.url, WifiPositioningProvider.beaconDbEndpoint);
      return http.Response(
        '{"location":{"lat":39.9817,"lng":-75.4072},"accuracy":40}',
        200,
      );
    });

    final attempt = await GeolocationService.locate(
      allowWifiScan: true,
      allowIp: true,
    );

    final fix = attempt.fix;
    expect(fix, isNotNull);
    expect(fix!.source, PositioningSource.wifiScan);
    expect(fix.accuracyMetres, 40);
    expect(fix.accessPointsUsed, 2);
    expect(
      fix.explanation,
      'Located to within 40 m using 2 nearby Wi-Fi networks (beaconDB).',
    );
    expect(
      attempt.outcomes.map((o) => o.tier),
      [PositioningTier.platformService, PositioningTier.wifiScan],
      reason: 'a precise Wi-Fi fix must stop the search before the IP tier',
    );
  });

  test(
    'a precise platform fix stops before anything leaves the machine',
    () async {
      GeolocatorPlatform.instance = _FakeGeolocatorPlatform(
        position: _positionAt(47.6062, -122.3321, accuracy: 12.4),
      );
      var scans = 0;
      GeolocationService.scannerFactory = () {
        scans++;
        return WifiScanner(
          runner: _nmcliRunner(_twoNetworks),
          operatingSystem: 'linux',
        );
      };
      var requests = 0;
      GeolocationService.clientFactory = () => MockClient((request) async {
        requests++;
        return http.Response('{}', 200);
      });

      final attempt = await GeolocationService.locate(
        allowWifiScan: true,
        allowIp: true,
      );

      expect(attempt.fix!.source, PositioningSource.platformService);
      expect(attempt.fix!.accuracyMetres, 12.4);
      expect(scans, 0, reason: 'a 12 m fix still scanned for Wi-Fi networks');
      expect(requests, 0, reason: 'a 12 m fix still made a network request');
    },
  );

  test('a beaconDB IP fallback never counts as a Wi-Fi fix', () async {
    // The real reply from this machine with `considerIp` left at its default:
    // HTTP 200, 25 km, and a `fallback` key saying it guessed from the IP.
    GeolocatorPlatform.instance = _FakeGeolocatorPlatform(enabled: false);
    GeolocationService.scannerFactory = () => WifiScanner(
      runner: _nmcliRunner(_twoNetworks),
      operatingSystem: 'linux',
    );
    GeolocationService.clientFactory = () => MockClient((request) async {
      if (request.url.host == 'api.beacondb.net') {
        return http.Response(
          '{"location":{"lat":39.95,"lng":-75.17},"accuracy":25000,'
          '"fallback":"ipf"}',
          200,
        );
      }
      return http.Response(
        '{"city":"Broomall","region":"Pennsylvania","loc":"39.9815,-75.3566"}',
        200,
      );
    });

    final attempt = await GeolocationService.locate(
      allowWifiScan: true,
      allowIp: true,
    );

    expect(attempt.fix!.source, PositioningSource.ipAddress);
    expect(attempt.fix!.provider, 'ipinfo.io');
    final wifi = attempt.outcomes.firstWhere(
      (o) => o.tier == PositioningTier.wifiScan,
    );
    expect(wifi.succeeded, isFalse);
    expect(wifi.detail, contains('No positioning service has mapped them'));
  });

  test('beaconDB answering 404 leaves the Wi-Fi tier honestly empty', () async {
    // What beaconDB actually returns for an unmapped area with
    // `considerIp: false` — the request Skotiq sends.
    GeolocatorPlatform.instance = _FakeGeolocatorPlatform(enabled: false);
    GeolocationService.scannerFactory = () => WifiScanner(
      runner: _nmcliRunner(_twoNetworks),
      operatingSystem: 'linux',
    );
    late String sentBody;
    GeolocationService.clientFactory = () => MockClient((request) async {
      if (request.url.host == 'api.beacondb.net') {
        sentBody = request.body;
        return http.Response(
          '{"error":{"code":404,"errors":[{"reason":"notFound"}]}}',
          404,
        );
      }
      return http.Response('{"loc":"39.9815,-75.3566"}', 200);
    });

    final attempt = await GeolocationService.locate(
      allowWifiScan: true,
      allowIp: true,
    );

    expect(json.decode(sentBody)['considerIp'], isFalse);
    expect(attempt.fix!.source, PositioningSource.ipAddress);
  });

  test(
    'a Google key is asked first and beaconDB still covers its refusal',
    () async {
      GeolocatorPlatform.instance = _FakeGeolocatorPlatform(enabled: false);
      GeolocationService.scannerFactory = () => WifiScanner(
        runner: _nmcliRunner(_twoNetworks),
        operatingSystem: 'linux',
      );
      final hosts = <String>[];
      GeolocationService.clientFactory = () => MockClient((request) async {
        hosts.add(request.url.host);
        if (request.url.host == 'www.googleapis.com') {
          expect(request.url.queryParameters['key'], 'test-key');
          return http.Response('{"error":{"code":403}}', 403);
        }
        return http.Response(
          '{"location":{"lat":39.9817,"lng":-75.4072},"accuracy":55}',
          200,
        );
      });

      final attempt = await GeolocationService.locate(
        allowWifiScan: true,
        allowIp: true,
        googleApiKey: 'test-key',
      );

      expect(hosts, ['www.googleapis.com', 'api.beacondb.net']);
      expect(attempt.fix!.provider, WifiPositioningProvider.beaconDbName);
      expect(attempt.fix!.accuracyMetres, 55);
    },
  );

  test('a switched-off radio is reported, not switched on unasked', () async {
    GeolocatorPlatform.instance = _FakeGeolocatorPlatform(enabled: false);
    final commands = <String>[];
    GeolocationService.scannerFactory = () => WifiScanner(
      runner: (exe, args) async {
        commands.add('$exe ${args.join(' ')}');
        return switch (args) {
          ['-t', '-f', 'TYPE', 'dev'] => _ok('ethernet\nwifi\n'),
          ['radio', 'wifi'] => _ok('disabled\n'),
          _ => _ok(''),
        };
      },
      operatingSystem: 'linux',
    );
    GeolocationService.clientFactory = () => MockClient((request) async {
      return http.Response('{"loc":"39.9815,-75.3566"}', 200);
    });

    final attempt = await GeolocationService.locate(
      allowWifiScan: true,
      allowIp: true,
    );

    expect(attempt.wifiRadioOff, isTrue);
    expect(attempt.canRetryWithWifi, isTrue);
    expect(
      commands,
      isNot(contains('nmcli radio wifi on')),
      reason: 'the radio was switched on without the operator asking',
    );
    expect(attempt.fix!.source, PositioningSource.ipAddress);
  });

  test('the explicit retry switches the radio on, scans, and switches it back '
      'off', () async {
    GeolocatorPlatform.instance = _FakeGeolocatorPlatform(enabled: false);
    final commands = <String>[];
    var radioOn = false;
    GeolocationService.scannerFactory = () => WifiScanner(
      runner: (exe, args) async {
        commands.add('$exe ${args.join(' ')}');
        return switch (args) {
          ['-t', '-f', 'TYPE', 'dev'] => _ok('ethernet\nwifi\n'),
          ['radio', 'wifi'] => _ok(radioOn ? 'enabled\n' : 'disabled\n'),
          ['radio', 'wifi', 'on'] => () {
            radioOn = true;
            return _ok('');
          }(),
          ['radio', 'wifi', 'off'] => () {
            radioOn = false;
            return _ok('');
          }(),
          _ => _ok(radioOn ? _twoNetworks : ''),
        };
      },
      operatingSystem: 'linux',
    );
    GeolocationService.clientFactory = () => MockClient((request) async {
      return http.Response(
        '{"location":{"lat":39.9817,"lng":-75.4072},"accuracy":38}',
        200,
      );
    });

    final attempt = await GeolocationService.locate(
      allowWifiScan: true,
      allowIp: true,
      mayEnableWifiRadio: true,
    );

    expect(attempt.fix!.source, PositioningSource.wifiScan);
    expect(commands, contains('nmcli radio wifi on'));
    expect(
      commands.last,
      'nmcli radio wifi off',
      reason: 'the radio was left on after a scan that found it off',
    );
    expect(radioOn, isFalse);
  });

  test(
    'a Wi-Fi failure still restores a radio this call switched on',
    () async {
      GeolocatorPlatform.instance = _FakeGeolocatorPlatform(enabled: false);
      final commands = <String>[];
      var radioOn = false;
      GeolocationService.scannerFactory = () => WifiScanner(
        runner: (exe, args) async {
          commands.add('$exe ${args.join(' ')}');
          return switch (args) {
            ['-t', '-f', 'TYPE', 'dev'] => _ok('wifi\n'),
            ['radio', 'wifi'] => _ok(radioOn ? 'enabled\n' : 'disabled\n'),
            ['radio', 'wifi', 'on'] => () {
              radioOn = true;
              return _ok('');
            }(),
            ['radio', 'wifi', 'off'] => () {
              radioOn = false;
              return _ok('');
            }(),
            // The radio came up but heard nothing at all.
            _ => _ok(''),
          };
        },
        operatingSystem: 'linux',
      );
      GeolocationService.clientFactory = () => MockClient((request) async {
        return http.Response('{}', 404);
      });

      final attempt = await GeolocationService.locate(
        allowWifiScan: true,
        allowIp: true,
        mayEnableWifiRadio: true,
      );

      expect(attempt.fix, isNull);
      expect(commands.last, 'nmcli radio wifi off');
      expect(radioOn, isFalse);
    },
  );

  test('every tier failing returns null with each reason named', () async {
    GeolocatorPlatform.instance = _FakeGeolocatorPlatform(enabled: false);
    GeolocationService.scannerFactory = () => WifiScanner(
      runner: (exe, args) async => _ok('ethernet\n'),
      operatingSystem: 'linux',
    );
    GeolocationService.clientFactory = () =>
        MockClient((request) async => http.Response('{}', 503));

    final attempt = await GeolocationService.locate(
      allowWifiScan: true,
      allowIp: true,
    );

    expect(attempt.fix, isNull);
    expect(attempt.outcomes.every((o) => !o.succeeded), isTrue);
    expect(
      attempt.failureDetail,
      'This machine’s location service is switched off. This machine has no '
      'Wi-Fi adapter. Neither ipinfo.io nor ipwho.is answered.',
    );
  });

  test('a refused tier never reaches the network', () async {
    GeolocatorPlatform.instance = _FakeGeolocatorPlatform(enabled: false);
    var scannerBuilds = 0;
    GeolocationService.scannerFactory = () {
      scannerBuilds++;
      return const WifiScanner(operatingSystem: 'linux');
    };
    var requests = 0;
    GeolocationService.clientFactory = () => MockClient((request) async {
      requests++;
      return http.Response('{}', 200);
    });

    final attempt = await GeolocationService.locate(
      allowWifiScan: false,
      allowIp: false,
    );

    expect(attempt.fix, isNull);
    expect(scannerBuilds, 0);
    expect(requests, 0);
    expect(attempt.outcomes.single.tier, PositioningTier.platformService);
  });

  test('a platform service reporting 0 m accuracy does not claim a perfect '
      'fix, or stop the search', () async {
    // geolocator hands back 0.0 when the platform measured nothing. Taken at
    // face value that is the smallest radius there is, and it would both win
    // the arbitration and end the search at tier 1.
    GeolocatorPlatform.instance = _FakeGeolocatorPlatform(
      position: _positionAt(39.90, -75.30, accuracy: 0),
    );
    GeolocationService.scannerFactory = () => WifiScanner(
      runner: _nmcliRunner(_twoNetworks),
      operatingSystem: 'linux',
    );
    GeolocationService.clientFactory = () => MockClient((request) async {
      return http.Response(
        '{"location":{"lat":39.9817,"lng":-75.4072},"accuracy":60}',
        200,
      );
    });

    final attempt = await GeolocationService.locate(
      allowWifiScan: true,
      allowIp: true,
    );

    expect(attempt.fix!.source, PositioningSource.wifiScan);
    expect(attempt.fix!.accuracyMetres, 60);
  });

  test('an IP fix states the mechanism instead of inventing a radius', () async {
    GeolocatorPlatform.instance = _FakeGeolocatorPlatform(enabled: false);
    GeolocationService.scannerFactory = () => WifiScanner(
      runner: (exe, args) async => _ok('ethernet\n'),
      operatingSystem: 'linux',
    );
    GeolocationService.clientFactory = () => MockClient((request) async {
      return http.Response(
        '{"city":"Broomall","region":"Pennsylvania","loc":"39.9815,-75.3566"}',
        200,
      );
    });

    final attempt = await GeolocationService.locate(
      allowWifiScan: true,
      allowIp: true,
    );

    expect(attempt.fix!.accuracyMetres, isNull);
    expect(
      attempt.fix!.explanation,
      'Approximate only: from your internet address (ipinfo.io). City level '
      '— typically tens of kilometres.',
    );
  });
}

/// A `nmcli` runner that reports one wireless device, an enabled radio, and
/// [listOutput] from the scan.
ProcessRunner _nmcliRunner(String listOutput) => (exe, args) async {
  return switch (args) {
    ['-t', '-f', 'TYPE', 'dev'] => _ok('ethernet\nwifi\n'),
    ['radio', 'wifi'] => _ok('enabled\n'),
    _ => _ok(listOutput),
  };
};

CommandResult _ok(String stdout) =>
    CommandResult(exitCode: 0, stdout: stdout, stderr: '');

/// Two rows in the exact shape `nmcli -t` emits: the BSSID's own colons
/// escaped, the field separator not.
const String _twoNetworks =
    r'AA\:DA\:C4\:1E\:F5\:8A:100:2:TP-Link_F58A'
    '\n'
    r'9C\:C9\:EB\:28\:D2\:F8:85:36:Fios-Guest'
    '\n';

Position _positionAt(
  double latitude,
  double longitude, {
  required double accuracy,
}) => Position(
  latitude: latitude,
  longitude: longitude,
  timestamp: DateTime(2026, 9, 13),
  accuracy: accuracy,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);
