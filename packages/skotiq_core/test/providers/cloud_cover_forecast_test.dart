import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/models.dart';

void main() {
  test(
    'cloud cover now comes from a nearby station, not the NWS forecast grid',
    () async {
      final now = DateTime.now().toUtc();
      final hour = DateTime.utc(now.year, now.month, now.day, now.hour);
      final client = MockClient((request) async {
        switch (request.url.host) {
          case 'aviationweather.gov':
            return http.Response(
              jsonEncode([
                {
                  'icaoId': 'KOQN',
                  'obsTime': now.millisecondsSinceEpoch ~/ 1000 - 300,
                  'lat': 39.99,
                  'lon': -75.58,
                  'name': 'West Chester',
                  'cover': 'CLR',
                  'clouds': <Object>[],
                  'rawOb': 'METAR KOQN 161715Z AUTO 34005KT 10SM CLR',
                },
              ]),
              200,
            );
          case 'api.weather.gov':
            if (request.url.path.startsWith('/points/')) {
              return http.Response(
                jsonEncode({
                  'properties': {
                    'forecastGridData':
                        'https://api.weather.gov/gridpoints/PHI/41,80',
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
                      {
                        'validTime': '${hour.toIso8601String()}/PT12H',
                        'value': 62,
                      },
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
              'time': hour.toIso8601String().substring(0, 16),
              'interval': 900,
              'cloud_cover': 8,
              'cloud_cover_high': 0,
            },
            'hourly': {
              'time': [hour.toIso8601String().substring(0, 16)],
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
              const LocationSettings(latitude: 40, longitude: -75.4),
            ),
          ],
        );
        addTearDown(container.dispose);
        expect(await container.read(cloudCoverPercentageProvider.future), 0);
        final sky = await container.read(currentSkyProvider.future);
        expect(sky!.source, 'KOQN station');
        expect(sky.model!.percent, 8);
      }, () => client);
    },
  );

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
    'numeric consumers share the metadata sample and refresh with it',
    () async {
      var percent = 6.0;
      final container = ProviderContainer(
        overrides: [
          currentSkyProvider.overrideWith(
            (ref) async => CurrentSky(
              model: CloudCoverForecast(
                percent: percent,
                source: 'Open-Meteo',
                validAt: DateTime.utc(2026, 11, 14, 2, 45),
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(await container.read(cloudCoverPercentageProvider.future), 6);
      percent = 100;
      container.invalidate(currentSkyProvider);
      expect(await container.read(cloudCoverPercentageProvider.future), 100);
    },
  );
}
