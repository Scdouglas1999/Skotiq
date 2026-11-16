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

Object _openMeteo() => {
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
  http.Response nwsAnswer(http.Request request) =>
      request.url.path.startsWith('/points/')
      ? _json({
          'properties': {
            'forecastGridData': 'https://api.weather.gov/gridpoints/TST/1,1',
          },
        })
      : _json(_nwsGrid());

  test(
    'the hourly model comes before the NWS grid where both answer',
    () async {
      final hosts = <String>[];
      final client = _TrackedClient((request) async {
        hosts.add(request.url.host);
        return request.url.host == 'api.weather.gov'
            ? nwsAnswer(request)
            : _json(_openMeteo());
      });
      final service = LocationCloudForecastService(
        httpClient: client,
        clock: () => _now,
      );
      final hours = await service.fetchRadarFrames(
        latitude: 40,
        longitude: -75,
      );
      expect(hours.providerName, 'Open-Meteo');
      expect(hours.frames.first.opacity, .08);
      expect(hosts, ['api.open-meteo.com']);
      expect(client.closeCount, 0);
      service.dispose();
      expect(client.closeCount, 1);
    },
  );

  test('the NWS grid answers when the model has no future hours', () async {
    final client = MockClient(
      (request) async => request.url.host == 'api.weather.gov'
          ? nwsAnswer(request)
          : http.Response('unavailable', 503),
    );
    final service = LocationCloudForecastService(
      httpClient: client,
      clock: () => _now,
    );
    addTearDown(service.dispose);
    final hours = await service.fetchRadarFrames(latitude: 40, longitude: -75);
    expect(hours.providerName, 'National Weather Service');
    expect(hours.frames.first.opacity, .87);
  });

  test('outside the NWS region its endpoints are never asked', () async {
    final hosts = <String>[];
    final client = MockClient((request) async {
      hosts.add(request.url.host);
      return request.url.host == 'api.met.no'
          ? _json(_metNorway())
          : http.Response('unavailable', 404);
    });
    final service = LocationCloudForecastService(
      httpClient: client,
      clock: () => _now,
    );
    addTearDown(service.dispose);
    final hours = await service.fetchRadarFrames(latitude: 48, longitude: 2);
    expect(hours.providerName, 'MET Norway');
    expect(hosts, isNot(contains('api.weather.gov')));
  });

  test('MET Norway is the last fallback', () async {
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
    final hours = await service.fetchRadarFrames(latitude: 40, longitude: -75);
    expect(hours.providerName, 'MET Norway');
    expect(hours.frames.first.opacity, closeTo(.961, 1e-9));
  });

  test('all sources unavailable return a failed result', () async {
    final client = MockClient((_) async => http.Response('unavailable', 404));
    final service = LocationCloudForecastService(
      httpClient: client,
      clock: () => _now,
    );
    addTearDown(service.dispose);
    expect(
      (await service.fetchRadarFrames(latitude: 40, longitude: -75)).isSuccess,
      isFalse,
    );
  });
}
