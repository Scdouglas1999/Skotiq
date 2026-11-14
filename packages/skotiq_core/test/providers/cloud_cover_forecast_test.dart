import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/src/services/weather/providers/metno_cloud_provider.dart';

void main() {
  test('local NWS forecast supplies current and planning clouds', () async {
    final now = DateTime.now().toUtc();
    final hour = DateTime.utc(now.year, now.month, now.day, now.hour);
    final client = MockClient((request) async {
      if (request.url.host == 'api.weather.gov') {
        if (request.url.path.startsWith('/points/')) {
          return http.Response(
            jsonEncode({
              'properties': {
                'forecastGridData':
                    'https://api.weather.gov/gridpoints/PHI/41,79',
              },
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'properties': {
              'skyCover': {
                'uom': 'wmoUnit:percent',
                'values': [
                  {'validTime': '${hour.toIso8601String()}/PT12H', 'value': 87},
                ],
              },
            },
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'current': {
            'time': hour.toIso8601String(),
            'interval': 900,
            'cloud_cover': 8,
          },
          'hourly': {
            'time': [hour.toIso8601String()],
            'cloud_cover': [8],
          },
        }),
        200,
      );
    });
    await http.runWithClient(() async {
      final container = ProviderContainer(
        overrides: [
          appObserverLocationProvider.overrideWithValue(
            const LocationSettings(latitude: 40, longitude: -75),
          ),
        ],
      );
      addTearDown(container.dispose);
      final forecast = await container.read(cloudCoverForecastProvider.future);
      expect(forecast?.percent, 87);
      expect(forecast?.source, 'National Weather Service');
      expect(await container.read(cloudCoverPercentageProvider.future), 87);
      final hours = await container.read(
        weekForecastCloudProvider(const ForecastSite(40, -75)).future,
      );
      expect(hours.isSuccess, isTrue);
      expect(hours.providerName, 'National Weather Service');
      expect(hours.frames.first.opacity, 0.87);
    }, () => client);
  });

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
