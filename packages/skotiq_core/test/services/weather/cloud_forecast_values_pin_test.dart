// The same cloud cover reaches every reader of the hourly forecast, from each
// source: the night planner's fractions, the sky-now fallback, and the cloud
// providers' frames on the radar map.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/src/models/site/altitude_floor.dart';
import 'package:skotiq_core/src/services/planning/forecast_planning_service.dart';
import 'package:skotiq_core/src/services/weather/current_sky_service.dart';
import 'package:skotiq_core/src/services/weather/location_cloud_forecast_service.dart';
import 'package:skotiq_core/src/services/weather/providers/metno_cloud_provider.dart';
import 'package:skotiq_core/src/services/weather/providers/openmeteo_cloud_provider.dart';

const _lat = 39.95;
const _lon = -75.16;

/// Awkward percentages: out of range, fractional, and values whose /100 does
/// not round-trip through *100.
const _cover = <num>[
  33,
  57,
  0.1,
  99.9,
  100,
  -5,
  120,
  7.3,
  29,
  58,
  14.6,
  35,
  70.7,
  1,
  86.6,
  3,
];

/// The fraction each percentage arrives as, printed exactly.
const _fractions = <String>[
  '0.33',
  '0.57',
  '0.001',
  '0.9990000000000001',
  '1.0',
  '0.0',
  '1.0',
  '0.073',
  '0.29',
  '0.58',
  '0.146',
  '0.35',
  '0.7070000000000001',
  '0.01',
  '0.866',
  '0.03',
];

final _start = DateTime.utc(2099, 1, 10, 20);
List<DateTime> get _hours => [
  for (var i = 0; i < _cover.length; i++) _start.add(Duration(hours: i)),
];

String _naive(DateTime t) => t.toIso8601String().substring(0, 16);

http.Response _json(Object value) => http.Response(jsonEncode(value), 200);

Object _openMeteo() => {
  'hourly': {
    'time': [for (final t in _hours) _naive(t)],
    'cloud_cover': _cover,
  },
};

Object _metNorway() => {
  'properties': {
    'timeseries': [
      for (var i = 0; i < _cover.length; i++)
        {
          'time': _hours[i].toIso8601String(),
          'data': {
            'instant': {
              'details': {'cloud_area_fraction': _cover[i]},
            },
          },
        },
    ],
  },
};

Object _nwsGrid() => {
  'properties': {
    'updateTime': '2099-01-10T19:00:00+00:00',
    'skyCover': {
      'uom': 'wmoUnit:percent',
      'values': [
        for (var i = 0; i < _cover.length; i++)
          {
            'validTime': '${_hours[i].toIso8601String()}/PT1H',
            'value': _cover[i].clamp(0, 100),
          },
      ],
    },
  },
};

/// Answers for one source; every other source fails.
MockClient _only(String source) => MockClient((request) async {
  final host = request.url.host;
  if (source == 'open-meteo' && host == 'api.open-meteo.com') {
    return _json(_openMeteo());
  }
  if (source == 'nws' && host == 'api.weather.gov') {
    return request.url.path.startsWith('/points/')
        ? _json({
            'properties': {
              'forecastGridData': 'https://api.weather.gov/gridpoints/TST/1,1',
            },
          })
        : _json(_nwsGrid());
  }
  if (source == 'met-norway' && host == 'api.met.no') {
    return _json(_metNorway());
  }
  return http.Response('unavailable', 503);
});

/// The forecast feed as the planner and `/api/weather/forecast` read it:
/// source name, then (UTC time, cloud fraction) per hour.
Future<(String?, List<(String, String)>)> _feed(String source) async {
  final service = LocationCloudForecastService(httpClient: _only(source));
  addTearDown(service.dispose);
  final result = await service.fetchCloudCover(latitude: _lat, longitude: _lon);
  expect(result.isSuccess, isTrue, reason: result.errorMessage);
  return (
    result.providerName,
    [
      for (final s in result.samples)
        (s.time.toIso8601String(), s.fraction.toString()),
    ],
  );
}

Future<String> _night(String source) async {
  final service = LocationCloudForecastService(httpClient: _only(source));
  addTearDown(service.dispose);
  final result = await service.fetchCloudCover(latitude: _lat, longitude: _lon);
  final week =
      ForecastPlanningService(
        latitudeDegrees: _lat,
        longitudeDegrees: _lon,
        floor: const AltitudeFloor(horizon: null, minimumDeg: 30),
      ).buildWeek(
        cloudResult: result,
        targets: const [
          ProjectTargetCandidate(
            targetId: 1,
            name: 'M42',
            raHours: 5.59,
            decDegrees: -5.39,
          ),
        ],
        nowLocal: DateTime(2099, 1, 10, 13),
        nights: 1,
      );
  final n = week.nights.single;
  return '${n.darkHours} ${n.clearDarkHours} ${n.meanCloudCoverDuringDark}';
}

void main() {
  final expectedFeed = [
    for (var i = 0; i < _cover.length; i++)
      (_hours[i].toIso8601String(), _fractions[i]),
  ];

  test('the hourly forecast fractions per source', () async {
    for (final (source, name) in [
      ('open-meteo', 'Open-Meteo'),
      ('nws', 'National Weather Service'),
      ('met-norway', 'MET Norway'),
    ]) {
      final (provider, feed) = await _feed(source);
      expect(provider, name, reason: source);
      expect(feed, expectedFeed, reason: source);
      expect(
        await _night(source),
        '11.238611111111112 6.0 0.4565454545454545',
        reason: source,
      );
    }
  });

  test('the sky-now fallback reads MET Norway', () async {
    final service = CurrentSkyService(
      httpClient: _only('met-norway'),
      clock: () => DateTime.utc(2099, 1, 10, 23, 20),
    );
    addTearDown(service.dispose);
    final sky = await service.fetch(latitude: _lat, longitude: _lon);
    expect(sky?.model?.percent, 0.9990000000000001 * 100);
    expect(sky?.model?.validAt, DateTime.utc(2099, 1, 10, 23));
    expect(sky?.model?.source, 'MET Norway');
  });

  test('the cloud providers draw the same frames on the radar map', () async {
    final openMeteo = OpenMeteoCloudProvider(httpClient: _only('open-meteo'));
    final metNorway = MetNoCloudProvider(httpClient: _only('met-norway'));
    addTearDown(openMeteo.dispose);
    addTearDown(metNorway.dispose);
    final expected = [
      for (var i = 0; i < _cover.length; i++)
        {
          'timestamp': _hours[i].toIso8601String(),
          'tileUrlTemplate': '',
          'north': 40.45,
          'south': 39.45,
          'east': -74.66,
          'west': -75.66,
          'opacity': double.parse(_fractions[i]),
          'intensityGrid': null,
          'isNoData': false,
          'isForecast': true,
          'tileType': 'xyz',
          'wmsLayers': null,
          'wmsAdditionalOptions': null,
        },
    ];
    for (final provider in [openMeteo, metNorway]) {
      final result = await provider.fetchRadarFrames(
        latitude: _lat,
        longitude: _lon,
      );
      expect(result.providerName, isNull, reason: provider.name);
      expect(
        jsonDecode(jsonEncode([for (final f in result.frames) f.toJson()])),
        expected,
        reason: provider.name,
      );
    }
  });
}
