import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/src/services/weather/location_cloud_forecast_service.dart';

final _now = DateTime.utc(2026, 11, 14, 3, 10);

http.Response _json(Object value) => http.Response(jsonEncode(value), 200);

Object _nwsGrid() => {
  'properties': {
    'updateTime': '2026-11-14T02:00:00+00:00',
    'skyCover': {
      'uom': 'wmoUnit:percent',
      'values': [
        {'validTime': '2026-11-14T03:00:00+00:00/PT1H', 'value': 87},
        {'validTime': '2026-11-14T04:00:00+00:00/PT2H', 'value': 79},
      ],
    },
  },
};

Object _openMeteo({String time = '2026-11-14T03:00'}) => {
  'current': {'time': time, 'cloud_cover': 8},
  'hourly': {
    'time': ['2026-11-14T03:00', '2026-11-14T04:00'],
    'cloud_cover': [8, 7],
  },
};

Object _metNorway() => {
  'properties': {
    'timeseries': [
      {
        'time': '2026-11-14T03:00:00Z',
        'data': {
          'instant': {
            'details': {'cloud_area_fraction': 96.1},
          },
        },
      },
      {
        'time': '2026-11-14T04:00:00Z',
        'data': {
          'instant': {
            'details': {'cloud_area_fraction': 93.0},
          },
        },
      },
    ],
  },
};

class _TrackedClient extends MockClient {
  _TrackedClient(super.fn);
  int closeCount = 0;
  @override
  void close() {
    closeCount++;
    super.close();
  }
}

void main() {
  test(
    'expired NWS data falls back for both current and future hours',
    () async {
      final client = MockClient((request) async {
        if (request.url.host == 'api.weather.gov') {
          if (request.url.path.startsWith('/points/')) {
            return _json({
              'properties': {
                'forecastGridData':
                    'https://api.weather.gov/gridpoints/TST/1,1',
              },
            });
          }
          return _json({
            'properties': {
              'skyCover': {
                'uom': 'wmoUnit:percent',
                'values': [
                  {'validTime': '2026-11-12T03:00:00+00:00/PT1H', 'value': 87},
                ],
              },
            },
          });
        }
        return _json(_openMeteo());
      });
      final service = LocationCloudForecastService(
        httpClient: client,
        clock: () => _now,
      );
      addTearDown(service.dispose);
      final current = await service.fetchCurrentCloudForecast(
        latitude: 40,
        longitude: -75,
      );
      final hours = await service.fetchRadarFrames(
        latitude: 40,
        longitude: -75,
      );
      expect(current!.source, 'Open-Meteo');
      expect(hours.providerName, current.source);
      expect(
        hours.frames.any((frame) => frame.timestamp.isAfter(_now)),
        isTrue,
      );
    },
  );

  test(
    'NWS87 beats Open-Meteo8 by coverage policy for current and hours',
    () async {
      final hosts = <String>[];
      final client = _TrackedClient((request) async {
        hosts.add(request.url.host);
        if (request.url.host == 'api.weather.gov') {
          if (request.url.path.startsWith('/points/')) {
            return _json({
              'properties': {
                'forecastGridData':
                    'https://api.weather.gov/gridpoints/TST/1,1',
              },
            });
          }
          return _json(_nwsGrid());
        }
        return _json(_openMeteo());
      });
      final service = LocationCloudForecastService(
        httpClient: client,
        clock: () => _now,
      );
      final current = await service.fetchCurrentCloudForecast(
        latitude: 40,
        longitude: -75,
      );
      final hours = await service.fetchRadarFrames(
        latitude: 40,
        longitude: -75,
      );
      expect(current!.percent, 87);
      expect(current.source, 'National Weather Service');
      expect(current.validAt, DateTime.utc(2026, 11, 14, 3));
      expect(hours.isSuccess, isTrue);
      expect(hours.providerName, current.source);
      expect(hours.frames.first.opacity, .87);
      expect(hosts, everyElement('api.weather.gov'));
      expect(client.closeCount, 0);
      service.dispose();
      expect(client.closeCount, 1);
    },
  );

  test(
    'unsupported NWS point falls back to the existing global model',
    () async {
      final client = MockClient(
        (request) async => request.url.host == 'api.weather.gov'
            ? http.Response('not covered', 404)
            : _json(_openMeteo()),
      );
      final service = LocationCloudForecastService(
        httpClient: client,
        clock: () => _now,
      );
      addTearDown(service.dispose);
      final current = await service.fetchCurrentCloudForecast(
        latitude: 40,
        longitude: -75,
      );
      final hours = await service.fetchRadarFrames(
        latitude: 40,
        longitude: -75,
      );
      expect(current!.source, 'Open-Meteo');
      expect(current.percent, 8);
      expect(hours.providerName, current.source);
      expect(hours.frames.first.opacity, .08);
    },
  );

  test('clearly outside NWS region skips its endpoints', () async {
    final client = MockClient((request) async {
      expect(request.url.host, 'api.open-meteo.com');
      return _json(_openMeteo());
    });
    final service = LocationCloudForecastService(
      httpClient: client,
      clock: () => _now,
    );
    addTearDown(service.dispose);
    expect(
      (await service.fetchCurrentCloudForecast(
        latitude: 48,
        longitude: 2,
      ))!.source,
      'Open-Meteo',
    );
    expect(
      (await service.fetchRadarFrames(latitude: 48, longitude: 2)).providerName,
      'Open-Meteo',
    );
  });

  test(
    'MET Norway remains the fallback when NWS and Open-Meteo fail',
    () async {
      final client = MockClient(
        (request) async => request.url.host == 'api.met.no'
            ? _json(_metNorway())
            : http.Response('unavailable', 404),
      );
      final service = LocationCloudForecastService(
        httpClient: client,
        clock: () => _now,
      );
      addTearDown(service.dispose);
      final current = await service.fetchCurrentCloudForecast(
        latitude: 40,
        longitude: -75,
      );
      final hours = await service.fetchRadarFrames(
        latitude: 40,
        longitude: -75,
      );
      expect(current!.source, 'MET Norway');
      expect(current.percent, 96.1);
      expect(current.validAt, DateTime.utc(2026, 11, 14, 3));
      expect(hours.providerName, current.source);
    },
  );

  test('missing or stale current samples do not become a clear zero', () async {
    final client = MockClient(
      (request) async => request.url.host == 'api.open-meteo.com'
          ? _json(_openMeteo(time: '2026-11-12T03:00'))
          : http.Response('unavailable', 404),
    );
    final service = LocationCloudForecastService(
      httpClient: client,
      clock: () => _now,
    );
    addTearDown(service.dispose);
    expect(
      await service.fetchCurrentCloudForecast(latitude: 40, longitude: -75),
      isNull,
    );
  });

  test('all sources unavailable return unknown and failed frames', () async {
    final client = MockClient((_) async => http.Response('unavailable', 404));
    final service = LocationCloudForecastService(
      httpClient: client,
      clock: () => _now,
    );
    addTearDown(service.dispose);
    expect(
      await service.fetchCurrentCloudForecast(latitude: 40, longitude: -75),
      isNull,
    );
    expect(
      (await service.fetchRadarFrames(latitude: 40, longitude: -75)).isSuccess,
      isFalse,
    );
  });
}
