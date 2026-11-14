import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/src/services/weather/providers/metno_cloud_provider.dart';

void main() {
  test('Open-Meteo 6% retains the model sample time in UTC', () {
    final forecast = CloudCoverForecast.fromOpenMeteo({
      'current': {
        'time': '2026-11-14T02:45',
        'interval': 900,
        'cloud_cover': 6,
      },
    })!;
    expect(forecast.percent, 6);
    expect(forecast.source, 'Open-Meteo');
    expect(forecast.validAt, DateTime.utc(2026, 11, 14, 2, 45));
    expect(forecast.validAt!.isUtc, isTrue);
  });

  test('missing sample time remains unknown, never becomes fetch time', () {
    final forecast = CloudCoverForecast.fromOpenMeteo({
      'current': {'cloud_cover': 6},
    })!;
    expect(forecast.validAt, isNull);
  });

  test(
    'MET Norway fallback retains its own name and nearest sample time',
    () async {
      final validAt = DateTime.now().toUtc();
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'properties': {
              'timeseries': [
                {
                  'time': validAt.toIso8601String(),
                  'data': {
                    'instant': {
                      'details': {'cloud_area_fraction': 6},
                    },
                  },
                },
              ],
            },
          }),
          200,
        ),
      );
      addTearDown(client.close);
      final forecast = await MetNoCloudProvider.fetchCurrentCloudForecast(
        client,
        40,
        -75,
      );
      expect(forecast!.percent, 6);
      expect(forecast.source, 'MET Norway');
      expect(forecast.validAt, validAt);
    },
  );

  test(
    'numeric consumers share the metadata sample and refresh with it',
    () async {
      var percent = 6.0;
      final container = ProviderContainer(
        overrides: [
          cloudCoverForecastProvider.overrideWith(
            (ref) async => CloudCoverForecast(
              percent: percent,
              source: 'Open-Meteo',
              validAt: DateTime.utc(2026, 11, 14, 2, 45),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(await container.read(cloudCoverPercentageProvider.future), 6);
      percent = 100;
      container.invalidate(cloudCoverForecastProvider);
      expect(await container.read(cloudCoverPercentageProvider.future), 100);
    },
  );
}
