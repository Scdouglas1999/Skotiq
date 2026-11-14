import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/src/services/weather/providers/goes_satellite_provider.dart';

void main() {
  // ux walk-2 F37: offline, the Weather map said "GOES Satellite, updated just
  // now" over an empty map. The provider turned the failed image request into
  // a no-data frame and reported success.
  test('an unreachable satellite server is a failed fetch', () async {
    final provider = GoesSatelliteProvider(
      client: MockClient(
        (_) async => throw http.ClientException('Connection failed'),
      ),
    );
    addTearDown(provider.dispose);

    final result = await provider.fetchRadarFrames(
      latitude: 40,
      longitude: -75,
    );

    expect(result.isSuccess, isFalse);
    expect(result.frames, isEmpty);
  });

  test(
    'a server that answers without an image still gives a no-data frame',
    () async {
      final provider = GoesSatelliteProvider(
        client: MockClient((_) async => http.Response('busy', 503)),
      );
      addTearDown(provider.dispose);

      final result = await provider.fetchRadarFrames(
        latitude: 40,
        longitude: -75,
      );

      expect(result.isSuccess, isTrue);
      expect(result.frames.single.isNoData, isTrue);
    },
  );
}
