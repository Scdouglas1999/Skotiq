import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/src/services/weather/current_sky_service.dart';

// 2026-11-16 17:20 UTC near Philadelphia: the NWS grid issued at 09:07 gave
// 62 % for the hour, HRRR 8 %, and every airport within 40 km reported clear.
final _now = DateTime.utc(2026, 11, 16, 17, 20);
const _site = (latitude: 40.0, longitude: -75.4);

http.Response _json(Object value) => http.Response(jsonEncode(value), 200);

Map<String, Object?> _metar(
  String id, {
  required double lat,
  required double lon,
  required DateTime at,
  String? cover,
  List<Map<String, Object?>> clouds = const [],
  bool automated = true,
}) => {
  'icaoId': id,
  'obsTime': at.millisecondsSinceEpoch ~/ 1000,
  'lat': lat,
  'lon': lon,
  'name': '$id airport',
  'cover': cover,
  'clouds': clouds,
  'rawOb': 'METAR $id 161715Z ${automated ? 'AUTO ' : ''}34005KT 10SM',
};

Object _openMeteoNow({num cover = 8, num high = 0}) => {
  'current': {
    'time': '2026-11-16T17:15',
    'interval': 900,
    'cloud_cover': cover,
    'cloud_cover_high': high,
  },
};

Object _nwsGrid() => {
  'properties': {
    'skyCover': {
      'uom': 'wmoUnit:percent',
      'values': [
        {'validTime': '2026-11-16T17:00:00+00:00/PT1H', 'value': 62},
      ],
    },
  },
};

Future<CurrentSky?> _fetch(
  Future<http.Response> Function(http.Request) answer, {
  List<Uri>? requests,
}) async {
  final service = CurrentSkyService(
    httpClient: MockClient((request) {
      requests?.add(request.url);
      return answer(request);
    }),
    clock: () => _now,
  );
  addTearDown(service.dispose);
  return service.fetch(latitude: _site.latitude, longitude: _site.longitude);
}

void main() {
  test('a clear airport report is the sky now, not a forecast grid', () async {
    final requests = <Uri>[];
    final sky = await _fetch((request) async {
      switch (request.url.host) {
        case 'aviationweather.gov':
          return _json([
            _metar(
              'KPHL',
              lat: 39.87,
              lon: -75.24,
              at: DateTime.utc(2026, 11, 16, 16, 54),
              cover: 'SCT',
              automated: false,
            ),
            _metar(
              'KOQN',
              lat: 39.99,
              lon: -75.58,
              at: DateTime.utc(2026, 11, 16, 17, 15),
              cover: 'CLR',
            ),
          ]);
        case 'api.open-meteo.com':
          return _json(_openMeteoNow());
        case 'api.weather.gov':
          return request.url.path.startsWith('/points/')
              ? _json({
                  'properties': {
                    'forecastGridData':
                        'https://api.weather.gov/gridpoints/PHI/41,80',
                  },
                })
              : _json(_nwsGrid());
      }
      return http.Response('unavailable', 404);
    }, requests: requests);

    expect(sky!.percent, 0);
    expect(sky.station!.stationId, 'KOQN');
    expect(sky.station!.distanceKm, closeTo(15.5, 1));
    expect(sky.station!.seesUpToFeet, 12000);
    expect(sky.validAt, DateTime.utc(2026, 11, 16, 17, 15));
    expect(sky.model!.percent, 8);
    expect(sky.sourcesDisagree, isFalse);
    expect(requests.map((uri) => uri.host), isNot(contains('api.weather.gov')));
  });

  test('the station request carries the site to a tenth of a degree', () async {
    final requests = <Uri>[];
    await _fetch(
      (request) async => request.url.host == 'aviationweather.gov'
          ? http.Response('', 204)
          : _json(_openMeteoNow()),
      requests: requests,
    );
    final metar = requests.singleWhere(
      (uri) => uri.host == 'aviationweather.gov',
    );
    expect(metar.queryParameters['bbox'], '39.5,-76.1,40.5,-74.7');
  });

  test(
    'high cloud an automated station cannot see raises the figure',
    () async {
      final sky = await _fetch(
        (request) async => request.url.host == 'aviationweather.gov'
            ? _json([
                _metar(
                  'KOQN',
                  lat: 39.99,
                  lon: -75.58,
                  at: DateTime.utc(2026, 11, 16, 17, 15),
                  cover: 'CLR',
                ),
              ])
            : _json(_openMeteoNow(cover: 70, high: 70)),
      );
      expect(sky!.percent, 70);
      expect(sky.sourcesDisagree, isTrue);
    },
  );

  test('an observer report covers the whole sky', () async {
    final sky = await _fetch(
      (request) async => request.url.host == 'aviationweather.gov'
          ? _json([
              _metar(
                'KPHL',
                lat: 39.87,
                lon: -75.24,
                at: DateTime.utc(2026, 11, 16, 16, 54),
                cover: null,
                clouds: [
                  {'cover': 'FEW', 'base': 3300},
                  {'cover': 'BKN', 'base': 25000},
                ],
                automated: false,
              ),
            ])
          : _json(_openMeteoNow(cover: 8, high: 0)),
    );
    expect(sky!.station!.amount, CloudAmount.broken);
    expect(sky.station!.seesUpToFeet, isNull);
    expect(sky.percent, 75);
    expect(sky.sourcesDisagree, isTrue);
  });

  test(
    'old, far or cloudless-unknown reports fall back to the model',
    () async {
      final sky = await _fetch(
        (request) async => request.url.host == 'aviationweather.gov'
            ? _json([
                _metar(
                  'KOLD',
                  lat: 40.0,
                  lon: -75.4,
                  at: DateTime.utc(2026, 11, 16, 15, 30),
                  cover: 'CLR',
                ),
                _metar(
                  'KFAR',
                  lat: 40.5,
                  lon: -74.8,
                  at: DateTime.utc(2026, 11, 16, 17, 15),
                  cover: 'CLR',
                ),
                _metar(
                  'KMQS',
                  lat: 40.0,
                  lon: -75.4,
                  at: DateTime.utc(2026, 11, 16, 17, 15),
                ),
              ])
            : _json(_openMeteoNow(cover: 9)),
      );
      expect(sky!.station, isNull);
      expect(sky.percent, 9);
      expect(sky.source, 'Open-Meteo');
      expect(sky.validAt, DateTime.utc(2026, 11, 16, 17, 15));
    },
  );

  test('no station and no model is unknown, never clear', () async {
    final sky = await _fetch((_) async => http.Response('unavailable', 503));
    expect(sky, isNull);
  });
}
