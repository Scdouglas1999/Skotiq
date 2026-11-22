import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_desktop/headless_api/handlers/weather_handlers.dart';

/// `/api/weather/forecast` is the hourly cloud forecast the planner uses, as
/// percentages from now on.
void main() {
  test('the forecast body carries each future hour as a percentage', () async {
    const cover = <num>[33, 99.9, -5, 120, 70.7, 3];
    final start = DateTime.utc(2099, 1, 10, 20);
    final hours = [
      for (var i = 0; i < cover.length; i++) start.add(Duration(hours: i)),
    ];
    final client = MockClient((request) async {
      if (request.url.host != 'api.open-meteo.com') {
        return http.Response('unavailable', 503);
      }
      return http.Response(
        jsonEncode({
          'hourly': {
            'time': [
              for (final t in hours) t.toIso8601String().substring(0, 16),
            ],
            'cloud_cover': cover,
          },
        }),
        200,
      );
    });
    final container = ProviderContainer(
      overrides: [
        planningCloudProviderFactoryProvider.overrideWithValue(
          () => LocationCloudForecastService(httpClient: client),
        ),
      ],
    );
    addTearDown(container.dispose);

    final response = await WeatherHandlers(container).handleGetForecast(
      Request(
        'GET',
        Uri.parse('http://localhost/api/weather/forecast?lat=39.95&lon=-75.16'),
      ),
    );
    expect(response.statusCode, 200);
    final body = jsonDecode(await response.readAsString()) as Map;
    expect(body['hasData'], isTrue);
    expect(body['source'], 'Open-Meteo');
    expect(body['latitude'], 39.95);
    expect(body['longitude'], -75.16);
    expect(body['hourly'], [
      for (final (i, percent) in [
        33.0,
        0.9990000000000001 * 100,
        0.0,
        100.0,
        0.7070000000000001 * 100,
        3.0,
      ].indexed)
        {
          'timestamp': hours[i].millisecondsSinceEpoch,
          'time': hours[i].toIso8601String(),
          'cloudCoverPercent': percent,
        },
    ]);
  });
}
