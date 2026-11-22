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
  test('a site is sent to NWS to four decimals', () async {
    final urls = <String>[];
    final provider = NwsCloudProvider(
      clock: () => DateTime.utc(2026, 11, 14, 3, 30),
      httpClient: MockClient((request) async {
        urls.add(request.url.toString());
        return request.url.path.startsWith('/points/')
            ? _points()
            : http.Response(_grid([]), 200);
      }),
    );
    addTearDown(provider.dispose);

    await provider.fetchCloudCover(
      latitude: 40.0123456789,
      longitude: -75.4567891234,
    );

    expect(urls.first, 'https://api.weather.gov/points/40.0123,-75.4568');
  });

  test(
    'hourly sky cover keeps each NWS interval value and identifies the app',
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

      final result = await provider.fetchCloudCover(
        latitude: _point.latitude,
        longitude: _point.longitude,
      );
      expect(result.providerName, 'National Weather Service');
      expect(result.samples.first.time, DateTime.utc(2026, 11, 14, 3));
      expect(result.samples.first.fraction, .87);
      expect(result.samples[1].fraction, .92);
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
    'planning expands multi-hour and day intervals into UTC hourly samples',
    () async {
      final provider = _provider(
        _grid([
          _value('2026-11-14T03:00:00+00:00/PT2H', 87),
          _value('2026-11-14T05:00:00+00:00/P1DT2H', 92),
        ]),
      );
      addTearDown(provider.dispose);
      final result = await provider.fetchCloudCover(
        latitude: _point.latitude,
        longitude: _point.longitude,
      );
      expect(result.isSuccess, isTrue);
      expect(result.providerName, 'National Weather Service');
      expect(result.samples, hasLength(28));
      expect(result.samples.first.time, DateTime.utc(2026, 11, 14, 3));
      expect(result.samples.last.time, DateTime.utc(2026, 11, 15, 6));
      expect(result.samples[1].fraction, .87);
      expect(result.samples[2].fraction, .92);
      expect(result.samples.every((sample) => sample.time.isUtc), isTrue);
    },
  );

  test('offset times crossing DST retain elapsed-hour coverage', () async {
    final provider = _provider(
      _grid([_value('2026-11-01T01:00:00-04:00/PT3H', 80)]),
      now: DateTime.utc(2026, 11, 1, 7, 30),
    );
    addTearDown(provider.dispose);
    final result = await provider.fetchCloudCover(latitude: 40, longitude: -75);
    expect(result.samples.map((sample) => sample.time), [
      DateTime.utc(2026, 11, 1, 5),
      DateTime.utc(2026, 11, 1, 6),
      DateTime.utc(2026, 11, 1, 7),
    ]);
  });

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
      final result = await provider.fetchCloudCover(
        latitude: 40,
        longitude: -75,
      );
      expect(result.isSuccess, isTrue);
      expect(result.samples, hasLength(1));
      expect(result.samples.single.fraction, 0);
    },
  );

  test('missing or wrong units never invent cloud cover', () async {
    final provider = _provider(
      _grid([_value('2026-11-14T03:00:00Z/PT1H', 87)], unit: 'wmoUnit:K'),
    );
    addTearDown(provider.dispose);
    final result = await provider.fetchCloudCover(latitude: 40, longitude: -75);
    expect(result.isSuccess, isFalse);
    expect(result.samples, isEmpty);
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
      final result = await provider.fetchCloudCover(latitude: 50, longitude: 1);
      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, contains('404'));
      expect(calls, 1);
    },
  );

  test('concurrent reads share one points/grid request', () async {
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
    final first = provider.fetchCloudCover(latitude: 40, longitude: -75);
    final samples = provider.fetchCloudCover(latitude: 40, longitude: -75);
    grid.complete(
      http.Response(_grid([_value('2026-11-14T03:00:00Z/PT2H', 87)]), 200),
    );
    expect((await first).samples.first.fraction, .87);
    expect((await samples).samples, hasLength(2));
    expect(calls, 2);
  });

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
        (await provider.fetchCloudCover(
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
      final result = await provider.fetchCloudCover(
        latitude: 40,
        longitude: -75,
      );
      expect(result.isSuccess, isFalse);
      expect(result.samples, isEmpty);
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
      (await provider.fetchCloudCover(latitude: 40, longitude: -75)).isSuccess,
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
      final result = await provider.fetchCloudCover(
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
      await provider.fetchCloudCover(latitude: 40, longitude: -75);
      await provider.fetchCloudCover(latitude: 40, longitude: -75);
      expect(points, hasLength(1));
      now = now.add(const Duration(minutes: 5));
      await provider.fetchCloudCover(latitude: 40, longitude: -75);
      await provider.fetchCloudCover(latitude: 41, longitude: -76);
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
        (await provider.fetchCloudCover(
          latitude: 40,
          longitude: -75,
        )).isSuccess,
        isFalse,
      );
    });
  }
}
