// The site detection's internet tier is the backend's IP lookup: one parse
// with its range check, one timeout per host. Only the place name is read on
// top of it.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/src/backend/ip_geolocation.dart';
import 'package:skotiq_core/src/services/site_positioning/geolocation_service.dart';

void main() {
  final saved = GeolocationService.clientFactory;
  tearDown(() => GeolocationService.clientFactory = saved);

  test('a latitude beyond 90 is no site', () async {
    GeolocationService.clientFactory = () => MockClient(
      (request) async =>
          http.Response('{"loc":"95.0,10.0","city":"Nowhere"}', 200),
    );
    expect(await GeolocationService.fetchLocation(), isNull);
  });

  test('a host that does not answer within the shared timeout is skipped', () {
    expect(IpGeolocation.perHostTimeout, const Duration(seconds: 5));
  });

  test('the place name is still read from the answer', () async {
    GeolocationService.clientFactory = () => MockClient(
      (request) async => http.Response(
        '{"city":"Broomall","region":"Pennsylvania","country":"US",'
        '"loc":"39.9815,-75.3566"}',
        200,
      ),
    );
    final result = await GeolocationService.fetchLocation();
    expect(result, (39.9815, -75.3566, 'Broomall, Pennsylvania'));
  });
}
