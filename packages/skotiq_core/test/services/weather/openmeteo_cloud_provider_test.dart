// OpenMeteoCloudProvider parses naive GMT timestamps as UTC, not device-local.
//
// Open-Meteo, when asked for hourly data, returns naive ISO-8601 strings
// ("2026-05-30T18:00") with no zone designator. A bare DateTime.parse treats
// those as device-LOCAL, shifting every frame by the device's UTC offset. The
// multi-night forecast then matches frames against UTC dark-hour samples within
// a 90-minute tolerance, so the shift collapses the whole week to "unavailable"
// for any non-UTC user.
//
// A real Open-Meteo response body is driven through fetchRadarFrames to assert:
//   * the request pins timezone=UTC,
//   * every frame timestamp is a genuine UTC instant, and
//   * the parsed instants line up with the requested hours (not offset-shifted),
//     which is what the forecast's dark-window matching relies on.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:skotiq_core/src/services/weather/providers/openmeteo_cloud_provider.dart';

void main() {
  /// Builds a MockClient that mimics Open-Meteo: hourly NAIVE timestamps (no
  /// zone suffix) that are UTC by virtue of the `timezone=UTC` query param.
  /// Captures the requested URI so tests can assert the timezone param.
  MockClient mockClient({
    required DateTime startUtc,
    required int hours,
    required double cloudCoverPercent,
    void Function(Uri uri)? onRequest,
  }) {
    return MockClient((request) async {
      onRequest?.call(request.url);
      final times = <String>[];
      final cover = <double>[];
      for (var i = 0; i < hours; i++) {
        final t = startUtc.add(Duration(hours: i));
        // Naive local-format string, exactly as Open-Meteo emits with
        // timezone=UTC: UTC wall-clock fields, no trailing 'Z'.
        times.add(
          '${t.year.toString().padLeft(4, '0')}-'
          '${t.month.toString().padLeft(2, '0')}-'
          '${t.day.toString().padLeft(2, '0')}T'
          '${t.hour.toString().padLeft(2, '0')}:00',
        );
        cover.add(cloudCoverPercent);
      }
      final body = jsonEncode({
        'hourly': {'time': times, 'cloud_cover': cover},
      });
      return http.Response(body, 200);
    });
  }

  test('requests timezone=UTC from the Open-Meteo API', () async {
    Uri? captured;
    final provider = OpenMeteoCloudProvider(
      httpClient: mockClient(
        startUtc: DateTime.utc(2026, 5, 30, 0),
        hours: 24,
        cloudCoverPercent: 0.0,
        onRequest: (uri) => captured = uri,
      ),
    );
    addTearDown(provider.dispose);

    final result = await provider.fetchRadarFrames(
      latitude: 47.6,
      longitude: -122.3,
    );

    expect(result.isSuccess, isTrue);
    expect(captured, isNotNull);
    expect(captured!.queryParameters['timezone'], 'UTC');
  });

  test('parses naive Open-Meteo timestamps as genuine UTC instants', () async {
    final startUtc = DateTime.utc(2026, 5, 30, 0);
    final provider = OpenMeteoCloudProvider(
      httpClient: mockClient(
        startUtc: startUtc,
        hours: 24,
        cloudCoverPercent: 50.0,
      ),
    );
    addTearDown(provider.dispose);

    final result = await provider.fetchRadarFrames(
      latitude: 47.6,
      longitude: -122.3,
    );

    expect(result.isSuccess, isTrue);
    expect(result.frames, isNotEmpty);
    for (final frame in result.frames) {
      // Every frame must be a UTC instant — never a device-local one.
      expect(
        frame.timestamp.isUtc,
        isTrue,
        reason: 'frame timestamp ${frame.timestamp} should be UTC',
      );
    }

    // The first frame must be the requested 00:00 UTC instant exactly — i.e.
    // NOT shifted by the device's UTC offset. This is the property the forecast
    // dark-window matcher depends on.
    final first = result.frames.first;
    expect(first.timestamp, DateTime.utc(2026, 5, 30, 0, 0));

    // And the hours march forward in UTC at one-hour steps.
    expect(result.frames[1].timestamp, DateTime.utc(2026, 5, 30, 1, 0));
    expect(result.frames[6].timestamp, DateTime.utc(2026, 5, 30, 6, 0));
  });

  test('opacity is cloud-cover percentage / 100, clamped to [0, 1]', () async {
    final provider = OpenMeteoCloudProvider(
      httpClient: mockClient(
        startUtc: DateTime.utc(2026, 5, 30, 0),
        hours: 3,
        cloudCoverPercent: 80.0,
      ),
    );
    addTearDown(provider.dispose);

    final result = await provider.fetchRadarFrames(
      latitude: 0.0,
      longitude: 0.0,
    );
    expect(result.isSuccess, isTrue);
    for (final frame in result.frames) {
      expect(frame.opacity, closeTo(0.8, 1e-9));
    }
  });

  test('surfaces an error RadarFetchResult on a non-200 response', () async {
    final provider = OpenMeteoCloudProvider(
      httpClient: MockClient((_) async => http.Response('nope', 500)),
    );
    addTearDown(provider.dispose);

    final result = await provider.fetchRadarFrames(
      latitude: 47.6,
      longitude: -122.3,
    );
    expect(result.isSuccess, isFalse);
    expect(result.errorMessage, isNotNull);
  });
}
