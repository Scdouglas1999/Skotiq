import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/weather_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

void main() {
  group('WeatherHandlers', () {
    late ProviderContainer container;
    late WeatherHandlers handlers;

    setUp(() {
      container = ProviderContainer();
      handlers = WeatherHandlers(container);
    });

    tearDown(() {
      container.dispose();
    });

    test('radar data missing lat/lon returns JSON bad request', () async {
      final response = await translateHandlerErrors(
        handlers.handleGetRadarData(
          Request('GET', Uri.parse('http://localhost/api/weather/radar')),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], 'Missing lat/lon query parameters');
    });

    test('cloud cover missing lat/lon returns JSON bad request', () async {
      final response = await translateHandlerErrors(
        handlers.handleGetCloudCover(
          Request('GET', Uri.parse('http://localhost/api/weather/cloud-cover')),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], 'Missing lat/lon query parameters');
    });

    test(
      'weather coordinates and refresh flag are validated strictly',
      () async {
        final cases = <(String, Future<Response> Function(Request))>[
          ('lat=NaN&lon=0', handlers.handleGetRadarData),
          ('lat=91&lon=0', handlers.handleGetRadarData),
          ('lat=0&lon=-181', handlers.handleGetForecast),
          ('lat=Infinity&lon=0', handlers.handleGetCloudCover),
          ('lat=0&lon=0&refresh=maybe', handlers.handleGetRadarData),
        ];
        for (final (query, handler) in cases) {
          final response = await translateHandlerErrors(
            handler(
              Request(
                'GET',
                Uri.parse('http://localhost/api/weather/test?$query'),
              ),
            ),
          );
          expect(response.statusCode, HttpStatus.badRequest, reason: query);
        }
      },
    );

    test('current weather returns JSON with safe-imaging fields', () async {
      final response = await translateHandlerErrors(
        handlers.handleGetCurrent(
          Request('GET', Uri.parse('http://localhost/api/weather/current')),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body.containsKey('safeToImage'), isTrue);
      expect(body.containsKey('alertLevel'), isTrue);
      expect(body.containsKey('temperature'), isTrue);
      expect(body.containsKey('hardwareConnected'), isTrue);
      expect(body.containsKey('windSpeedMps'), isTrue);
      expect(body.containsKey('windSpeedKph'), isTrue);
    });

    test('malformed settings payload returns JSON internal error', () async {
      final response = await translateHandlerErrors(
        handlers.handleUpdateSettings(
          Request(
            'POST',
            Uri.parse('http://localhost/api/weather/settings'),
            body: '{',
          ),
        ),
      );

      expect(
        response.statusCode,
        anyOf(HttpStatus.badRequest, HttpStatus.internalServerError),
      );
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], isA<String>());
    });

    test('unsafe weather thresholds are rejected', () async {
      final response = await translateHandlerErrors(
        handlers.handleUpdateSettings(
          Request(
            'POST',
            Uri.parse('http://localhost/api/weather/settings'),
            body: jsonEncode({'maxHumidityPercent': 150}),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['field'], 'maxHumidityPercent');
    });
    // A clear sky must not produce HTTP 500 from the weather endpoints.
    //
    // WeatherAlertService represents "no cloud front detected" as an infinite
    // distance, which is correct for its threshold comparisons but has no JSON
    // encoding. Serialising it raw makes jsonEncode throw, so the two endpoints
    // that answer "is it safe to image?" return an opaque internal error on
    // precisely the nights when the answer is "yes, perfectly clear".
    test(
      'clear sky (no cloud front) serialises instead of failing to encode',
      () async {
        final service = container.read(weatherAlertServiceProvider);
        final alert = service.evaluateConditions(
          motion: null,
          currentCloudDensity: 0,
          settings: const WeatherSettings(),
        );
        // Precondition: this is the in-memory sentinel that used to break JSON.
        expect(
          alert.distanceKm.isFinite,
          isFalse,
          reason: 'clear sky should still use the infinite-distance sentinel',
        );
        service.emitAlert(alert);

        final response = await translateHandlerErrors(
          handlers.handleGetAlerts(
            Request('GET', Uri.parse('http://localhost/api/weather/alerts')),
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = jsonDecode(await response.readAsString()) as Map;
        final alerts = body['alerts'] as List;
        expect(alerts, hasLength(1));
        // No front means no distance to it — null, not a crash and not a number.
        expect((alerts.single as Map)['distanceKm'], isNull);
      },
    );

    test('current weather serialises a clear sky without a 500', () async {
      final service = container.read(weatherAlertServiceProvider);
      service.emitAlert(
        service.evaluateConditions(
          motion: null,
          currentCloudDensity: 0,
          settings: const WeatherSettings(),
        ),
      );

      final response = await translateHandlerErrors(
        handlers.handleGetCurrent(
          Request('GET', Uri.parse('http://localhost/api/weather/current')),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect((body['currentAlert'] as Map)['distanceKm'], isNull);
    });
  });

  // POST /api/weather/settings used to read only the top level of the body,
  // so the `{"settings": {...}}` document its own GET answers stored nothing —
  // and still replied {"status":"updated"}. That is how a rig can be told
  // weather safety is on and image all night unguarded.
  group('WeatherHandlers settings round trip', () {
    late ProviderContainer container;
    late WeatherHandlers handlers;

    setUp(() {
      container = createHeadlessTestContainer();
      handlers = WeatherHandlers(container);
    });

    tearDown(() {
      container.dispose();
    });

    Future<Response> post(Object body) => translateHandlerErrors(
      handlers.handleUpdateSettings(
        Request(
          'POST',
          Uri.parse('http://localhost/api/weather/settings'),
          body: jsonEncode(body),
        ),
      ),
    );

    Future<Map<String, dynamic>> readSettings() async {
      final response = await translateHandlerErrors(
        handlers.handleGetSettings(
          Request('GET', Uri.parse('http://localhost/api/weather/settings')),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      return (body['settings'] as Map).cast<String, dynamic>();
    }

    test('the GET document posted back is stored', () async {
      final before = await readSettings();
      expect(before['weatherSafetyEnabled'], isFalse);

      final response = await post({
        'settings': {'maxWindSpeedKph': 44.5, 'weatherSafetyEnabled': true},
      });
      expect(response.statusCode, HttpStatus.ok);

      final after = await readSettings();
      expect(after['maxWindSpeedKph'], 44.5);
      expect(after['weatherSafetyEnabled'], isTrue);
    });

    test('a whole GET document round-trips, `id` and all', () async {
      await post({'maxWindSpeedKph': 51.0});
      final document = await readSettings();
      expect(document.containsKey('id'), isTrue);

      final response = await post({
        'settings': {...document, 'maxCloudCoverPercent': 42.0},
      });
      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(
        body['ignored'],
        isNull,
        reason: 'the row id the GET echoes is not a misspelled setting',
      );

      final after = await readSettings();
      expect(after['maxCloudCoverPercent'], 42.0);
      expect(after['maxWindSpeedKph'], 51.0);
    });

    test('the forecast policy is readable and writable', () async {
      final before = await readSettings();
      // A fresh install with weather safety off only warns on forecasts.
      expect(before['forecastHoldsRun'], isFalse);
      expect(before['starEvidenceOverridesForecast'], isTrue);
      expect(before['requiredSafeDurationSeconds'], 300);

      final response = await post({
        'forecastHoldsRun': true,
        'starEvidenceOverridesForecast': false,
      });
      expect(response.statusCode, HttpStatus.ok);

      final after = await readSettings();
      expect(after['forecastHoldsRun'], isTrue);
      expect(after['starEvidenceOverridesForecast'], isFalse);
    });

    test('the flat body older clients send still works', () async {
      final response = await post({
        'maxWindSpeedKph': 55.5,
        'weatherSafetyEnabled': true,
      });
      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['applied'], ['maxWindSpeedKph', 'weatherSafetyEnabled']);

      final after = await readSettings();
      expect(after['maxWindSpeedKph'], 55.5);
      expect(after['weatherSafetyEnabled'], isTrue);
    });

    test('the response carries the row as it now stands', () async {
      final response = await post({'weatherSafetyEnabled': true});
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['status'], 'updated');
      expect((body['settings'] as Map)['weatherSafetyEnabled'], isTrue);
    });

    test('a body naming no setting is refused, not blessed', () async {
      final response = await post({'totallyMadeUpKey': 123});
      expect(response.statusCode, HttpStatus.badRequest);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['field'], 'settings');
      expect(body['message'], contains('totallyMadeUpKey'));

      final after = await readSettings();
      expect(after['weatherSafetyEnabled'], isFalse);
    });

    test('an empty settings envelope is refused', () async {
      final response = await post({'settings': <String, Object?>{}});
      expect(response.statusCode, HttpStatus.badRequest);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['field'], 'settings');
    });

    test('a non-object settings envelope is refused by name', () async {
      final response = await post({'settings': 'on'});
      expect(response.statusCode, HttpStatus.badRequest);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['field'], 'settings');
      expect(body['expected'], 'json_object');
    });

    test('a body holding both shapes is refused rather than guessed', () async {
      final response = await post({
        'maxWindSpeedKph': 20.0,
        'settings': {'maxWindSpeedKph': 90.0},
      });
      expect(response.statusCode, HttpStatus.badRequest);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['field'], 'settings');
      expect(body['message'], contains('maxWindSpeedKph'));

      final after = await readSettings();
      expect(after['maxWindSpeedKph'], 30.0, reason: 'neither answer applied');
    });

    test(
      'an unknown field alongside a real one is named, not silent',
      () async {
        final response = await post({
          'maxWindSpeedKph': 33.0,
          'maxWindSpeedKmh': 99.0,
        });
        expect(response.statusCode, HttpStatus.ok);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['applied'], ['maxWindSpeedKph']);
        expect(body['ignored'], ['maxWindSpeedKmh']);
        expect(body['warning'], contains('maxWindSpeedKmh'));

        final after = await readSettings();
        expect(after['maxWindSpeedKph'], 33.0);
      },
    );
  });
}
