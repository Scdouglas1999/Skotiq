import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:skotiq_core/src/models/weather/weather_models.dart';
import 'package:skotiq_core/src/services/weather/providers/rainviewer_radar_provider.dart';
import 'package:skotiq_core/src/services/weather/radar_colormaps.dart';

void main() {
  group('RainViewerRadarProvider', () {
    late RainViewerRadarProvider provider;

    // Sample API response mimicking RainViewer structure.
    final sampleApiResponse = {
      'version': '2.0',
      'generated': 1234567890,
      'host': 'https://tilecache.rainviewer.com',
      'radar': {
        'past': [
          {
            'time': 1234567200,
            'path': '/v2/radar/1234567200/256/{z}/{x}/{y}/2/1_1.png',
          },
          {
            'time': 1234567800,
            'path': '/v2/radar/1234567800/256/{z}/{x}/{y}/2/1_1.png',
          },
          {
            'time': 1234568400,
            'path': '/v2/radar/1234568400/256/{z}/{x}/{y}/2/1_1.png',
          },
        ],
        'nowcast': [
          {
            'time': 1234569000,
            'path': '/v2/radar/1234569000/256/{z}/{x}/{y}/2/1_1.png',
          },
          {
            'time': 1234569600,
            'path': '/v2/radar/1234569600/256/{z}/{x}/{y}/2/1_1.png',
          },
        ],
      },
    };

    /// A 256×256 PNG painted entirely with a RainViewer heavy-rain anchor
    /// colour (intensity 1.0), so any sampled cell decodes to ~1.0.
    Uint8List heavyRainTilePng() {
      final stop = RadarColormaps.rainViewerScheme2.stops.last;
      final image = img.Image(width: 256, height: 256, numChannels: 4);
      img.fill(image, color: img.ColorRgba8(stop.r, stop.g, stop.b, 255));
      return Uint8List.fromList(img.encodePng(image));
    }

    /// Builds a MockClient that serves [sampleApiResponse] for the metadata URL
    /// and [tileResponse] for every tile request.
    MockClient clientWith(http.Response Function() tileResponse) {
      return MockClient((request) async {
        if (request.url.toString().contains('weather-maps.json')) {
          return http.Response(json.encode(sampleApiResponse), 200);
        }
        // Any other request is a radar tile fetch.
        return tileResponse();
      });
    }

    tearDown(() {
      provider.dispose();
    });

    test('provider metadata is correct', () {
      provider = RainViewerRadarProvider();

      expect(provider.name, equals('RainViewer'));
      expect(provider.providerType, equals(RadarProviderType.rainviewer));
      expect(provider.coverageBounds.north, equals(90.0));
      expect(provider.coverageBounds.south, equals(-90.0));
      expect(provider.coverageBounds.east, equals(180.0));
      expect(provider.coverageBounds.west, equals(-180.0));
    });

    test('coversLocation returns true for any location (global coverage)', () {
      provider = RainViewerRadarProvider();

      expect(provider.coversLocation(40.7128, -74.0060), isTrue);
      expect(provider.coversLocation(51.5074, -0.1278), isTrue);
      expect(provider.coversLocation(-33.8688, 151.2093), isTrue);
      expect(provider.coversLocation(0, 0), isTrue);
      expect(provider.coversLocation(90, 180), isTrue);
      expect(provider.coversLocation(-90, -180), isTrue);
    });

    test('getAvailableTimeRange returns correct durations', () {
      provider = RainViewerRadarProvider();

      final (history, forecast) = provider.getAvailableTimeRange();

      expect(history, equals(const Duration(hours: 2)));
      expect(forecast, equals(const Duration(minutes: 30)));
    });

    test('buildTileUrl replaces placeholders correctly', () {
      provider = RainViewerRadarProvider();

      final frame = RadarFrame(
        timestamp: DateTime.now(),
        tileUrlTemplate:
            'https://tilecache.rainviewer.com/v2/radar/1234567890/256/{z}/{x}/{y}/2/1_1.png',
        north: 90.0,
        south: -90.0,
        east: 180.0,
        west: -180.0,
      );

      final url = provider.buildTileUrl(frame, 8, 123, 456);

      expect(
        url,
        equals(
          'https://tilecache.rainviewer.com/v2/radar/1234567890/256/8/123/456/2/1_1.png',
        ),
      );
    });

    test(
      'fetchRadarFrames decodes tiles into a real per-cell intensity grid',
      () async {
        provider = RainViewerRadarProvider(
          httpClient: clientWith(
            () => http.Response.bytes(
              heavyRainTilePng(),
              200,
              headers: {'content-type': 'image/png'},
            ),
          ),
        );

        final result = await provider.fetchRadarFrames(
          latitude: 40.7128,
          longitude: -74.0060,
        );

        expect(result.isSuccess, isTrue);
        expect(result.errorMessage, isNull);
        expect(result.frames.length, equals(5)); // 3 past + 2 nowcast

        for (final frame in result.frames) {
          // Real spatial data was decoded: a populated grid, not a no-data flag.
          expect(frame.isNoData, isFalse);
          expect(frame.intensityGrid, isNotNull);
          expect(frame.intensityGrid!.isNotEmpty, isTrue);

          // The whole tile was heavy rain → every sampled cell ~1.0.
          final sample = frame.intensityGrid![0][0];
          expect(sample, closeTo(1.0, 1e-6));

          // Frame bounds are the observer FOV (NOT the whole world anymore).
          expect(frame.north, lessThan(90.0));
          expect(frame.south, greaterThan(-90.0));
          expect(frame.north - frame.south, lessThan(10.0));
        }

        // Forecast frames retain their lower animation opacity + flag.
        final nowcast = result.frames.where((f) => f.isForecast).toList();
        expect(nowcast.length, equals(2));
        expect(nowcast.first.opacity, equals(0.85));
      },
    );

    test(
      'tile fetch failure yields honest no-data frames (no fabrication)',
      () async {
        // Metadata succeeds, but every tile request 404s.
        provider = RainViewerRadarProvider(
          httpClient: clientWith(() => http.Response('Not found', 404)),
        );

        final result = await provider.fetchRadarFrames(
          latitude: 40.7128,
          longitude: -74.0060,
        );

        // The fetch as a whole still "succeeds" (the metadata was read) but every
        // frame is flagged no-data, carrying no fabricated intensity field.
        expect(result.isSuccess, isTrue);
        expect(result.frames, isNotEmpty);
        for (final frame in result.frames) {
          expect(frame.isNoData, isTrue);
          expect(frame.intensityGrid, isNull);
        }
      },
    );

    test('tile decode failure (garbage bytes) yields no-data frames', () async {
      provider = RainViewerRadarProvider(
        httpClient: clientWith(
          () => http.Response.bytes(
            Uint8List.fromList([0, 1, 2, 3, 4]),
            200,
            headers: {'content-type': 'image/png'},
          ),
        ),
      );

      final result = await provider.fetchRadarFrames(
        latitude: 40.7128,
        longitude: -74.0060,
      );

      expect(result.isSuccess, isTrue);
      for (final frame in result.frames) {
        expect(frame.isNoData, isTrue);
        expect(frame.intensityGrid, isNull);
      }
    });

    test('fetchRadarFrames handles HTTP error on metadata', () async {
      final mockClient = MockClient((request) async {
        return http.Response('Not Found', 404);
      });

      provider = RainViewerRadarProvider(httpClient: mockClient);

      final result = await provider.fetchRadarFrames(
        latitude: 40.7128,
        longitude: -74.0060,
      );

      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, contains('404'));
      expect(result.frames, isEmpty);
    });

    test('fetchRadarFrames handles malformed JSON', () async {
      final mockClient = MockClient((request) async {
        return http.Response('{ invalid json', 200);
      });

      provider = RainViewerRadarProvider(httpClient: mockClient);

      final result = await provider.fetchRadarFrames(
        latitude: 40.7128,
        longitude: -74.0060,
      );

      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, contains('parse'));
      expect(result.frames, isEmpty);
    });

    test('fetchRadarFrames handles missing radar data', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          json.encode({
            'version': '2.0',
            'generated': 1234567890,
            'host': 'https://tilecache.rainviewer.com',
          }),
          200,
        );
      });

      provider = RainViewerRadarProvider(httpClient: mockClient);

      final result = await provider.fetchRadarFrames(
        latitude: 40.7128,
        longitude: -74.0060,
      );

      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, contains('missing radar data'));
    });

    test('fetchRadarFrames handles empty radar data', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          json.encode({
            'version': '2.0',
            'generated': 1234567890,
            'host': 'https://tilecache.rainviewer.com',
            'radar': {'past': [], 'nowcast': []},
          }),
          200,
        );
      });

      provider = RainViewerRadarProvider(httpClient: mockClient);

      final result = await provider.fetchRadarFrames(
        latitude: 40.7128,
        longitude: -74.0060,
      );

      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, contains('no radar frames'));
    });

    test('fetchRadarFrames handles network exception on metadata', () async {
      final mockClient = MockClient((request) async {
        throw http.ClientException('Network unreachable');
      });

      provider = RainViewerRadarProvider(httpClient: mockClient);

      final result = await provider.fetchRadarFrames(
        latitude: 40.7128,
        longitude: -74.0060,
      );

      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, contains('Network error'));
    });

    test('fetchRadarFrames skips entries missing time/path', () async {
      final mockClient = MockClient((request) async {
        if (request.url.toString().contains('weather-maps.json')) {
          return http.Response(
            json.encode({
              'version': '2.0',
              'generated': 1234567890,
              'host': 'https://tilecache.rainviewer.com',
              'radar': {
                'past': [
                  {
                    'time': 1234567200,
                    'path': '/v2/radar/1234567200/256/{z}/{x}/{y}/2/1_1.png',
                  },
                  {'path': '/v2/radar/1234567800/256/{z}/{x}/{y}/2/1_1.png'},
                  {'time': 1234568400},
                ],
                'nowcast': [],
              },
            }),
            200,
          );
        }
        return http.Response.bytes(
          heavyRainTilePng(),
          200,
          headers: {'content-type': 'image/png'},
        );
      });

      provider = RainViewerRadarProvider(httpClient: mockClient);

      final result = await provider.fetchRadarFrames(
        latitude: 40.7128,
        longitude: -74.0060,
      );

      expect(result.isSuccess, isTrue);
      expect(result.frames.length, equals(1)); // Only one valid entry.
    });

    test('dispose closes HTTP client', () {
      provider = RainViewerRadarProvider();
      expect(() => provider.dispose(), returnsNormally);
    });

    test('timestamp conversion from Unix seconds is correct', () async {
      provider = RainViewerRadarProvider(
        httpClient: clientWith(
          () => http.Response.bytes(
            heavyRainTilePng(),
            200,
            headers: {'content-type': 'image/png'},
          ),
        ),
      );

      final result = await provider.fetchRadarFrames(
        latitude: 40.7128,
        longitude: -74.0060,
      );

      expect(result.isSuccess, isTrue);
      final firstFrame = result.frames.first;
      final expectedTimestamp = DateTime.fromMillisecondsSinceEpoch(
        1234567200 * 1000,
      );
      expect(firstFrame.timestamp, equals(expectedTimestamp));
    });
  });
}
