// Tests for MetNoCloudProvider — the independent numerical cloud-cover fallback
// for Open-Meteo. These guard that MET Norway's compact Locationforecast JSON
// is parsed into RadarFrames that match Open-Meteo's conventions exactly (UTC
// timestamps, opacity = cloud_area_fraction / 100, forecast flag), that
// malformed entries are skipped rather than thrown on, that non-200s surface as
// error results, and that the static fetchCurrentCloudCover picks the entry
// nearest to "now" (within tolerance) and returns null on garbage.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:skotiq_core/src/services/weather/providers/metno_cloud_provider.dart';

void main() {
  /// Builds a compact-forecast body: [entries] is a list of (ISO-8601 UTC time
  /// string, cloud_area_fraction). Pass a raw map for [extra] entries to inject
  /// malformed shapes.
  String forecastBody(
    List<(String, double)> entries, {
    List<dynamic> extraRaw = const [],
  }) {
    final timeseries = <dynamic>[
      for (final (time, cover) in entries)
        {
          'time': time,
          'data': {
            'instant': {
              'details': {'cloud_area_fraction': cover},
            },
          },
        },
      ...extraRaw,
    ];
    return jsonEncode({
      'properties': {
        'meta': {
          'units': {'cloud_area_fraction': '%'},
        },
        'timeseries': timeseries,
      },
    });
  }

  test('requests api.met.no with an identifying User-Agent', () async {
    Map<String, String>? capturedHeaders;
    Uri? capturedUri;
    final provider = MetNoCloudProvider(
      httpClient: MockClient((request) async {
        capturedUri = request.url;
        capturedHeaders = request.headers;
        return http.Response(
          forecastBody([('2026-06-11T10:00:00Z', 50.0)]),
          200,
        );
      }),
    );
    addTearDown(provider.dispose);

    final result = await provider.fetchRadarFrames(
      latitude: 40.0,
      longitude: -105.0,
    );

    expect(result.isSuccess, isTrue);
    expect(capturedUri!.host, 'api.met.no');
    expect(capturedUri!.queryParameters['lat'], '40.0');
    expect(capturedUri!.queryParameters['lon'], '-105.0');
    // MET Norway 403s without an identifying UA; it must be present.
    expect(capturedHeaders!['user-agent'], contains('Skotiq'));
  });

  test('parses timestamps as genuine UTC instants', () async {
    final provider = MetNoCloudProvider(
      httpClient: MockClient((_) async {
        return http.Response(
          forecastBody([
            ('2026-06-11T10:00:00Z', 0.0),
            ('2026-06-11T11:00:00Z', 0.0),
          ]),
          200,
        );
      }),
    );
    addTearDown(provider.dispose);

    final result = await provider.fetchRadarFrames(
      latitude: 40.0,
      longitude: -105.0,
    );

    expect(result.isSuccess, isTrue);
    expect(result.frames, hasLength(2));
    for (final frame in result.frames) {
      expect(frame.timestamp.isUtc, isTrue);
    }
    expect(result.frames.first.timestamp, DateTime.utc(2026, 6, 11, 10));
    expect(result.frames[1].timestamp, DateTime.utc(2026, 6, 11, 11));
  });

  test('opacity is cloud_area_fraction / 100, clamped to [0, 1]', () async {
    final provider = MetNoCloudProvider(
      httpClient: MockClient((_) async {
        return http.Response(
          forecastBody([
            ('2026-06-11T10:00:00Z', 80.0),
            // Out-of-range value is clamped, never throws.
            ('2026-06-11T11:00:00Z', 150.0),
          ]),
          200,
        );
      }),
    );
    addTearDown(provider.dispose);

    final result = await provider.fetchRadarFrames(
      latitude: 0.0,
      longitude: 0.0,
    );
    expect(result.isSuccess, isTrue);
    expect(result.frames[0].opacity, closeTo(0.8, 1e-9));
    expect(result.frames[1].opacity, closeTo(1.0, 1e-9));
  });

  test('flags entries after now as forecast', () async {
    final past = DateTime.now().toUtc().subtract(const Duration(hours: 2));
    final future = DateTime.now().toUtc().add(const Duration(hours: 2));
    final provider = MetNoCloudProvider(
      httpClient: MockClient((_) async {
        return http.Response(
          forecastBody([
            (past.toIso8601String(), 10.0),
            (future.toIso8601String(), 10.0),
          ]),
          200,
        );
      }),
    );
    addTearDown(provider.dispose);

    final result = await provider.fetchRadarFrames(
      latitude: 40.0,
      longitude: -105.0,
    );
    expect(result.isSuccess, isTrue);
    expect(result.frames[0].isForecast, isFalse);
    expect(result.frames[1].isForecast, isTrue);
  });

  test('uses ±0.5° point bounds around the request', () async {
    final provider = MetNoCloudProvider(
      httpClient: MockClient((_) async {
        return http.Response(
          forecastBody([('2026-06-11T10:00:00Z', 0.0)]),
          200,
        );
      }),
    );
    addTearDown(provider.dispose);

    final result = await provider.fetchRadarFrames(
      latitude: 40.0,
      longitude: -105.0,
    );
    final frame = result.frames.single;
    expect(frame.north, closeTo(40.5, 1e-9));
    expect(frame.south, closeTo(39.5, 1e-9));
    expect(frame.east, closeTo(-104.5, 1e-9));
    expect(frame.west, closeTo(-105.5, 1e-9));
  });

  test('skips malformed entries defensively without throwing', () async {
    final provider = MetNoCloudProvider(
      httpClient: MockClient((_) async {
        final body = forecastBody(
          [('2026-06-11T10:00:00Z', 25.0)],
          extraRaw: [
            {
              'time': 'not-a-date',
              'data': {
                'instant': {
                  'details': {'cloud_area_fraction': 50.0},
                },
              },
            },
            {'time': '2026-06-11T12:00:00Z'}, // no data
            {
              'time': '2026-06-11T13:00:00Z',
              'data': {
                'instant': {
                  'details': {'cloud_area_fraction': 'nope'},
                },
              },
            },
            {
              'data': {
                'instant': {
                  'details': {'cloud_area_fraction': 50.0},
                },
              },
            }, // no time
            'garbage-string-entry',
          ],
        );
        return http.Response(body, 200);
      }),
    );
    addTearDown(provider.dispose);

    final result = await provider.fetchRadarFrames(
      latitude: 40.0,
      longitude: -105.0,
    );
    // Only the one well-formed entry survives.
    expect(result.isSuccess, isTrue);
    expect(result.frames, hasLength(1));
    expect(result.frames.single.opacity, closeTo(0.25, 1e-9));
  });

  test('surfaces an error result on a 403 (missing/blocked UA)', () async {
    final provider = MetNoCloudProvider(
      httpClient: MockClient((_) async => http.Response('forbidden', 403)),
    );
    addTearDown(provider.dispose);

    final result = await provider.fetchRadarFrames(
      latitude: 40.0,
      longitude: -105.0,
    );
    expect(result.isSuccess, isFalse);
    expect(result.errorMessage, contains('403'));
  });

  test('surfaces an error result on a 500', () async {
    final provider = MetNoCloudProvider(
      httpClient: MockClient((_) async => http.Response('boom', 500)),
    );
    addTearDown(provider.dispose);

    final result = await provider.fetchRadarFrames(
      latitude: 40.0,
      longitude: -105.0,
    );
    expect(result.isSuccess, isFalse);
    expect(result.errorMessage, isNotNull);
  });

  test('getAvailableTimeRange reports zero history (no past data)', () {
    final provider = MetNoCloudProvider(
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    );
    addTearDown(provider.dispose);
    final (history, forecast) = provider.getAvailableTimeRange();
    expect(history, Duration.zero);
    expect(forecast.inDays, greaterThanOrEqualTo(7));
  });

  group('fetchCurrentCloudCover', () {
    test('returns the entry nearest to now within tolerance', () async {
      final now = DateTime.now().toUtc();
      final client = MockClient((_) async {
        return http.Response(
          forecastBody([
            (now.subtract(const Duration(minutes: 20)).toIso8601String(), 30.0),
            (now.add(const Duration(minutes: 10)).toIso8601String(), 70.0),
            (now.add(const Duration(hours: 3)).toIso8601String(), 90.0),
          ]),
          200,
        );
      });
      addTearDown(client.close);

      final cover = await MetNoCloudProvider.fetchCurrentCloudCover(
        client,
        40.0,
        -105.0,
      );
      // +10min entry is closest to now → 70%.
      expect(cover, closeTo(70.0, 1e-9));
    });

    test('returns null when the nearest entry is beyond ±90 min', () async {
      final now = DateTime.now().toUtc();
      final client = MockClient((_) async {
        return http.Response(
          forecastBody([
            (now.add(const Duration(hours: 5)).toIso8601String(), 40.0),
          ]),
          200,
        );
      });
      addTearDown(client.close);

      final cover = await MetNoCloudProvider.fetchCurrentCloudCover(
        client,
        40.0,
        -105.0,
      );
      expect(cover, isNull);
    });

    test('returns null on a non-200', () async {
      final client = MockClient((_) async => http.Response('nope', 500));
      addTearDown(client.close);
      final cover = await MetNoCloudProvider.fetchCurrentCloudCover(
        client,
        40.0,
        -105.0,
      );
      expect(cover, isNull);
    });

    test('returns null on garbage JSON', () async {
      final client = MockClient(
        (_) async => http.Response('not json at all', 200),
      );
      addTearDown(client.close);
      final cover = await MetNoCloudProvider.fetchCurrentCloudCover(
        client,
        40.0,
        -105.0,
      );
      expect(cover, isNull);
    });
  });
}
