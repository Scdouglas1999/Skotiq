import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/src/services/weather/providers/nws_cloud_provider.dart';

const _gridUrl = 'https://api.weather.gov/gridpoints/PHI/40,75';
const _point = (latitude: 40.0, longitude: -75.4);

String _grid(List<Object?> values, {String unit = 'wmoUnit:percent'}) =>
    jsonEncode({
      'properties': {
        'skyCover': {'uom': unit, 'values': values},
      },
    });

Map<String, Object?> _value(String validTime, Object? value) => {
  'validTime': validTime,
  'value': value,
};

http.Response _points() => http.Response(
  jsonEncode({
    'properties': {'forecastGridData': _gridUrl},
  }),
  200,
);

NwsCloudProvider _provider(String body, {DateTime? now}) => NwsCloudProvider(
  clock: () => now ?? DateTime.utc(2026, 11, 14, 3, 30),
  httpClient: MockClient(
    (request) async => request.url.path.startsWith('/points/')
        ? _points()
        : http.Response(body, 200),
  ),
);

void main() {
  test(
    'current sky cover uses the containing NWS interval with its source',
    () async {
      final requests = <http.Request>[];
      final provider = NwsCloudProvider(
        clock: () => DateTime.utc(2026, 11, 14, 3, 30),
        httpClient: MockClient((request) async {
          requests.add(request);
          return request.url.path.startsWith('/points/')
              ? _points()
              : http.Response(
                  _grid([
                    _value('2026-11-14T03:00:00+00:00/PT1H', 87),
                    _value('2026-11-14T04:00:00+00:00/PT2H', 92),
                  ]),
                  200,
                );
        }),
      );
      addTearDown(provider.dispose);

      final forecast = await provider.fetchCurrentCloudForecast(
        latitude: _point.latitude,
        longitude: _point.longitude,
      );
      expect(forecast, isNotNull);
      expect(forecast!.percent, 87);
      expect(forecast.source, 'National Weather Service');
      expect(forecast.validAt, DateTime.utc(2026, 11, 14, 3));
      expect(requests.map((r) => r.url.toString()), [
        'https://api.weather.gov/points/40.0,-75.4',
        _gridUrl,
      ]);
      for (final request in requests) {
        expect(request.headers['user-agent'], contains('Skotiq'));
        expect(request.headers['user-agent'], contains('https://'));
      }
    },
  );

  test(
    'planning expands multi-hour and day intervals into UTC hourly frames',
    () async {
      final provider = _provider(
        _grid([
          _value('2026-11-14T03:00:00+00:00/PT2H', 87),
          _value('2026-11-14T05:00:00+00:00/P1DT2H', 92),
        ]),
      );
      addTearDown(provider.dispose);
      final result = await provider.fetchRadarFrames(
        latitude: _point.latitude,
        longitude: _point.longitude,
      );
      expect(result.isSuccess, isTrue);
      expect(result.providerName, 'National Weather Service');
      expect(result.frames, hasLength(28));
      expect(result.frames.first.timestamp, DateTime.utc(2026, 11, 14, 3));
      expect(result.frames.last.timestamp, DateTime.utc(2026, 11, 15, 6));
      expect(result.frames[1].opacity, .87);
      expect(result.frames[2].opacity, .92);
      expect(result.frames.every((frame) => frame.timestamp.isUtc), isTrue);
      expect(
        result.frames.every((frame) => frame.tileUrlTemplate.isEmpty),
        isTrue,
      );
    },
  );

  test('offset times crossing DST retain elapsed-hour coverage', () async {
    final provider = _provider(
      _grid([_value('2026-11-01T01:00:00-04:00/PT3H', 80)]),
      now: DateTime.utc(2026, 11, 1, 7, 30),
    );
    addTearDown(provider.dispose);
    final result = await provider.fetchRadarFrames(
      latitude: 40,
      longitude: -75,
    );
    expect(result.frames.map((frame) => frame.timestamp), [
      DateTime.utc(2026, 11, 1, 5),
      DateTime.utc(2026, 11, 1, 6),
      DateTime.utc(2026, 11, 1, 7),
    ]);
    final current = await provider.fetchCurrentCloudForecast(
      latitude: 40,
      longitude: -75,
    );
    expect(current!.percent, 80);
    expect(current.validAt, DateTime.utc(2026, 11, 1, 5));
  });

  for (final now in [
    DateTime.utc(2026, 11, 14, 2, 59),
    DateTime.utc(2026, 11, 14, 5),
    DateTime.utc(2026, 11, 14, 6),
  ]) {
    test('no nearest-neighbor answer outside valid interval at $now', () async {
      final provider = _provider(
        _grid([_value('2026-11-14T03:00:00Z/PT2H', 87)]),
        now: now,
      );
      addTearDown(provider.dispose);
      expect(
        await provider.fetchCurrentCloudForecast(latitude: 40, longitude: -75),
        isNull,
      );
    });
  }

  test(
    'nulls, out-of-range cover, malformed times and huge durations are not forecasts',
    () async {
      final provider = _provider(
        _grid([
          _value('2026-11-14T03:00:00Z/PT1H', null),
          _value('2026-11-14T04:00:00Z/PT1H', -1),
          _value('2026-11-14T05:00:00Z/PT1H', 101),
          _value('2026-11-14T06:00:00Z/PT1H', '87'),
          _value('bad/PT1H', 80),
          _value('2026-11-14T07:00:00/PT1H', 80),
          _value('2026-11-14T08:00:00Z/PT0H', 80),
          _value('2026-11-14T09:00:00Z/P999999999D', 80),
          _value('2026-11-14T10:00:00Z/P1M', 80),
          _value('2026-11-14T11:00:00Z/PT1H', 0),
        ]),
      );
      addTearDown(provider.dispose);
      final result = await provider.fetchRadarFrames(
        latitude: 40,
        longitude: -75,
      );
      expect(result.isSuccess, isTrue);
      expect(result.frames, hasLength(1));
      expect(result.frames.single.opacity, 0);
      expect(
        await provider.fetchCurrentCloudForecast(latitude: 40, longitude: -75),
        isNull,
      );
    },
  );

  test('missing or wrong units never invent cloud cover', () async {
    final provider = _provider(
      _grid([_value('2026-11-14T03:00:00Z/PT1H', 87)], unit: 'wmoUnit:K'),
    );
    addTearDown(provider.dispose);
    final result = await provider.fetchRadarFrames(
      latitude: 40,
      longitude: -75,
    );
    expect(result.isSuccess, isFalse);
    expect(result.frames, isEmpty);
    expect(
      await provider.fetchCurrentCloudForecast(latitude: 40, longitude: -75),
      isNull,
    );
  });

  test(
    'NWS-uncovered coordinates return unavailable after points 404',
    () async {
      var calls = 0;
      final provider = NwsCloudProvider(
        httpClient: MockClient((_) async {
          calls++;
          return http.Response('{}', 404);
        }),
      );
      addTearDown(provider.dispose);
      final result = await provider.fetchRadarFrames(
        latitude: 50,
        longitude: 1,
      );
      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, contains('404'));
      expect(calls, 1);
    },
  );

  test(
    'concurrent current and planning reads share one points/grid request',
    () async {
      final grid = Completer<http.Response>();
      var calls = 0;
      final provider = NwsCloudProvider(
        clock: () => DateTime.utc(2026, 11, 14, 3, 30),
        httpClient: MockClient((request) async {
          calls++;
          return request.url.path.startsWith('/points/')
              ? _points()
              : grid.future;
        }),
      );
      addTearDown(provider.dispose);
      final current = provider.fetchCurrentCloudForecast(
        latitude: 40,
        longitude: -75,
      );
      final frames = provider.fetchRadarFrames(latitude: 40, longitude: -75);
      grid.complete(
        http.Response(_grid([_value('2026-11-14T03:00:00Z/PT2H', 87)]), 200),
      );
      expect((await current)!.percent, 87);
      expect((await frames).frames, hasLength(2));
      expect(calls, 2);
    },
  );

  test(
    'calendar overflow is rejected instead of moving the forecast to another day',
    () async {
      final provider = _provider(
        _grid([
          _value('2026-02-30T03:00:00Z/PT1H', 87),
          _value('2026-11-14T25:00:00Z/PT1H', 87),
        ]),
      );
      addTearDown(provider.dispose);
      expect(
        (await provider.fetchRadarFrames(
          latitude: 40,
          longitude: -75,
        )).isSuccess,
        isFalse,
      );
    },
  );

  test(
    'hourly expansion has an overall bound even for many valid intervals',
    () async {
      final provider = _provider(
        _grid([
          _value('2026-11-14T03:00:00Z/P14D', 87),
          _value('2026-11-28T03:00:00Z/P14D', 87),
        ]),
      );
      addTearDown(provider.dispose);
      final result = await provider.fetchRadarFrames(
        latitude: 40,
        longitude: -75,
      );
      expect(result.isSuccess, isFalse);
      expect(result.frames, isEmpty);
    },
  );

  test('transient NWS errors retry with identification intact', () async {
    final requests = <http.Request>[];
    final provider = NwsCloudProvider(
      httpClient: MockClient((request) async {
        requests.add(request);
        if (requests.length == 1) return http.Response('{}', 503);
        return request.url.path.startsWith('/points/')
            ? _points()
            : http.Response(
                _grid([_value('2026-11-14T03:00:00Z/PT1H', 87)]),
                200,
              );
      }),
    );
    addTearDown(provider.dispose);
    expect(
      (await provider.fetchRadarFrames(latitude: 40, longitude: -75)).isSuccess,
      isTrue,
    );
    expect(requests, hasLength(3));
    expect(
      requests.every(
        (request) => request.headers['user-agent']!.contains('Skotiq'),
      ),
      isTrue,
    );
  });

  test(
    'malformed grid URLs are rejected without following another host',
    () async {
      var calls = 0;
      final provider = NwsCloudProvider(
        httpClient: MockClient((_) async {
          calls++;
          return http.Response(
            jsonEncode({
              'properties': {
                'forecastGridData': 'http://example.com/gridpoints/data',
              },
            }),
            200,
          );
        }),
      );
      addTearDown(provider.dispose);
      final result = await provider.fetchRadarFrames(
        latitude: 40,
        longitude: -75,
      );
      expect(result.isSuccess, isFalse);
      expect(calls, 1);
    },
  );

  test(
    'cache is coordinate-specific and refreshes after five minutes',
    () async {
      var now = DateTime.utc(2026, 11, 14, 3, 30);
      final points = <String>[];
      final provider = NwsCloudProvider(
        clock: () => now,
        httpClient: MockClient((request) async {
          if (request.url.path.startsWith('/points/')) {
            points.add(request.url.path);
            return _points();
          }
          return http.Response(
            _grid([_value('2026-11-14T03:00:00Z/PT2H', 87)]),
            200,
          );
        }),
      );
      addTearDown(provider.dispose);
      await provider.fetchCurrentCloudForecast(latitude: 40, longitude: -75);
      await provider.fetchRadarFrames(latitude: 40, longitude: -75);
      expect(points, hasLength(1));
      now = now.add(const Duration(minutes: 5));
      await provider.fetchRadarFrames(latitude: 40, longitude: -75);
      await provider.fetchRadarFrames(latitude: 41, longitude: -76);
      expect(points, [
        '/points/40.0,-75.0',
        '/points/40.0,-75.0',
        '/points/41.0,-76.0',
      ]);
    },
  );

  for (final body in [
    'not-json',
    '{}',
    '{"properties":{"skyCover":{"uom":"wmoUnit:percent","values":[{"validTime":"2026-11-14T03:00:00Z/PT1H","value":1e999}]}}}',
  ]) {
    test('unusable grid body produces unavailable: $body', () async {
      final provider = _provider(body);
      addTearDown(provider.dispose);
      expect(
        (await provider.fetchRadarFrames(
          latitude: 40,
          longitude: -75,
        )).isSuccess,
        isFalse,
      );
      expect(
        await provider.fetchCurrentCloudForecast(latitude: 40, longitude: -75),
        isNull,
      );
    });
  }
}
