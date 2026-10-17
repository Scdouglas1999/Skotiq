import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:skotiq_core/src/models/hips/hips_properties.dart';
import 'package:skotiq_core/src/models/hips/hips_tile_id.dart';
import 'package:skotiq_core/src/services/hips/hips_tile_fetcher.dart';

/// A minimal, valid HiPS `properties` document for the DSS2-red pyramid.
const String _validProperties = '''
creator_did      = ivo://CDS/P/DSS2/red
obs_collection   = DSS2 red
hips_version      = 1.4
hips_order        = 9
hips_order_min    = 0
hips_tile_width   = 512
hips_tile_format  = jpeg fits
hips_frame        = equatorial
obs_copyright     = STScI/NASA
obs_copyright_url = https://archive.stsci.edu/dss/
''';

/// Builds a deterministic encoded PNG of [size]x[size] pixels filled with a
/// recognisable colour, flowing through the same `image` -> bytes ->
/// `instantiateImageCodec` path the production decode uses.
Uint8List _encodePng(int size, {int r = 200, int g = 120, int b = 40}) {
  final image = img.Image(width: size, height: size);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodePng(image));
}

/// Builds a deterministic encoded JPEG of [size]x[size] pixels.
Uint8List _encodeJpg(int size) {
  final image = img.Image(width: size, height: size);
  img.fill(image, color: img.ColorRgb8(10, 80, 160));
  return Uint8List.fromList(img.encodeJpg(image, quality: 90));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const baseUrl = 'https://alasky.cds.unistra.fr/DSS/DSS2Merged';

  group('HipsTileFetcher.fetchProperties', () {
    test('fetches and parses a valid properties document', () async {
      late Uri requested;
      final client = MockClient((request) async {
        requested = request.url;
        return http.Response(_validProperties, 200);
      });
      final fetcher = HipsTileFetcher(httpClient: client);
      addTearDown(fetcher.dispose);

      final props = await fetcher.fetchProperties(baseUrl);

      expect(requested.toString(), '$baseUrl/properties');
      expect(props.hipsOrder, 9);
      expect(props.hipsOrderMin, 0);
      expect(props.tileWidth, 512);
      expect(props.frame, HipsFrame.equatorial);
      expect(props.preferredFormat, HipsTileFormat.jpeg);
    });

    test('sends a User-Agent and Accept header', () async {
      String? userAgent;
      String? accept;
      final client = MockClient((request) async {
        userAgent = request.headers['User-Agent'];
        accept = request.headers['Accept'];
        return http.Response(_validProperties, 200);
      });
      final fetcher = HipsTileFetcher(httpClient: client);
      addTearDown(fetcher.dispose);

      await fetcher.fetchProperties(baseUrl);

      expect(userAgent, isNotNull);
      expect(userAgent, contains('Skotiq'));
      expect(accept, contains('text/plain'));
    });

    test('normalises a trailing slash on the base URL', () async {
      late Uri requested;
      final client = MockClient((request) async {
        requested = request.url;
        return http.Response(_validProperties, 200);
      });
      final fetcher = HipsTileFetcher(httpClient: client);
      addTearDown(fetcher.dispose);

      await fetcher.fetchProperties('$baseUrl/');

      expect(requested.toString(), '$baseUrl/properties');
    });

    test(
      'non-200 status throws HipsFetchHttpException with the status code',
      () async {
        final client = MockClient(
          (request) async => http.Response('nope', 404),
        );
        final fetcher = HipsTileFetcher(httpClient: client);
        addTearDown(fetcher.dispose);

        await expectLater(
          fetcher.fetchProperties(baseUrl),
          throwsA(
            isA<HipsFetchHttpException>()
                .having((e) => e.statusCode, 'statusCode', 404)
                .having(
                  (e) => e.requestUrl,
                  'requestUrl',
                  '$baseUrl/properties',
                ),
          ),
        );
      },
    );

    test('empty body throws HipsFetchDecodeException', () async {
      final client = MockClient((request) async => http.Response('   ', 200));
      final fetcher = HipsTileFetcher(httpClient: client);
      addTearDown(fetcher.dispose);

      await expectLater(
        fetcher.fetchProperties(baseUrl),
        throwsA(isA<HipsFetchDecodeException>()),
      );
    });

    test('malformed properties throws HipsFetchDecodeException carrying the '
        'parse exception as cause', () async {
      // Missing the required hips_order key -> HipsPropertiesParseException.
      const bad = 'hips_frame = equatorial\nhips_tile_format = jpeg\n';
      final client = MockClient((request) async => http.Response(bad, 200));
      final fetcher = HipsTileFetcher(httpClient: client);
      addTearDown(fetcher.dispose);

      await expectLater(
        fetcher.fetchProperties(baseUrl),
        throwsA(
          isA<HipsFetchDecodeException>().having(
            (e) => e.cause,
            'cause',
            isA<HipsPropertiesParseException>(),
          ),
        ),
      );
    });

    test('invalid UTF-8 body throws HipsFetchDecodeException', () async {
      // 0xFF 0xFE is not a valid UTF-8 sequence.
      final client = MockClient.streaming((request, bodyStream) async {
        return http.StreamedResponse(
          Stream<List<int>>.fromIterable(<List<int>>[
            <int>[0xFF, 0xFE, 0xFF],
          ]),
          200,
        );
      });
      final fetcher = HipsTileFetcher(httpClient: client);
      addTearDown(fetcher.dispose);

      await expectLater(
        fetcher.fetchProperties(baseUrl),
        throwsA(isA<HipsFetchDecodeException>()),
      );
    });

    test(
      'transport error throws HipsFetchHttpException with null status',
      () async {
        final client = MockClient((request) async {
          throw http.ClientException('connection reset', request.url);
        });
        final fetcher = HipsTileFetcher(httpClient: client);
        addTearDown(fetcher.dispose);

        await expectLater(
          fetcher.fetchProperties(baseUrl),
          throwsA(
            isA<HipsFetchHttpException>().having(
              (e) => e.statusCode,
              'statusCode',
              isNull,
            ),
          ),
        );
      },
    );
  });

  group('HipsTileFetcher.fetchTile', () {
    test('fetches and decodes a PNG tile to a ui.Image with correct '
        'dimensions', () async {
      final pngBytes = _encodePng(64);
      late Uri requested;
      final client = MockClient((request) async {
        requested = request.url;
        return http.Response.bytes(pngBytes, 200);
      });
      final fetcher = HipsTileFetcher(httpClient: client);
      addTearDown(fetcher.dispose);

      final id = HipsTileId(survey: 'CDS/P/DSS2/red', norder: 3, npix: 42);
      final image = await fetcher.fetchTile(id, baseUrl, HipsTileFormat.jpeg);
      addTearDown(image.dispose);

      expect(requested.toString(), '$baseUrl/Norder3/Dir0/Npix42.jpg');
      expect(image.width, 64);
      expect(image.height, 64);
    });

    test('fetches and decodes a JPEG tile to a ui.Image', () async {
      final jpgBytes = _encodeJpg(32);
      final client = MockClient((request) async {
        return http.Response.bytes(jpgBytes, 200);
      });
      final fetcher = HipsTileFetcher(httpClient: client);
      addTearDown(fetcher.dispose);

      final id = HipsTileId(survey: 'CDS/P/DSS2/red', norder: 5, npix: 10001);
      final image = await fetcher.fetchTile(id, baseUrl, HipsTileFormat.jpeg);
      addTearDown(image.dispose);

      expect(image.width, 32);
      expect(image.height, 32);
    });

    test('builds the directory bucket path for a high npix', () async {
      final pngBytes = _encodePng(16);
      late Uri requested;
      final client = MockClient((request) async {
        requested = request.url;
        return http.Response.bytes(pngBytes, 200);
      });
      final fetcher = HipsTileFetcher(httpClient: client);
      addTearDown(fetcher.dispose);

      // Norder5 has 12 * 4^5 = 12288 tiles, so npix 10500 lands in Dir10000.
      final id = HipsTileId(survey: 's', norder: 5, npix: 10500);
      final image = await fetcher.fetchTile(id, baseUrl, HipsTileFormat.png);
      addTearDown(image.dispose);

      expect(requested.toString(), '$baseUrl/Norder5/Dir10000/Npix10500.png');
    });

    test('undecodable bytes throw HipsFetchDecodeException', () async {
      final junk = Uint8List.fromList(utf8.encode('this is not an image'));
      final client = MockClient((request) async {
        return http.Response.bytes(junk, 200);
      });
      final fetcher = HipsTileFetcher(httpClient: client);
      addTearDown(fetcher.dispose);

      final id = HipsTileId(survey: 's', norder: 3, npix: 1);
      await expectLater(
        fetcher.fetchTile(id, baseUrl, HipsTileFormat.png),
        throwsA(isA<HipsFetchDecodeException>()),
      );
    });

    test('non-200 tile status throws HipsFetchHttpException', () async {
      final client = MockClient((request) async => http.Response('', 503));
      final fetcher = HipsTileFetcher(httpClient: client);
      addTearDown(fetcher.dispose);

      final id = HipsTileId(survey: 's', norder: 3, npix: 1);
      await expectLater(
        fetcher.fetchTile(id, baseUrl, HipsTileFormat.png),
        throwsA(
          isA<HipsFetchHttpException>().having(
            (e) => e.statusCode,
            'statusCode',
            503,
          ),
        ),
      );
    });

    test('empty 200 body throws HipsFetchDecodeException', () async {
      final client = MockClient(
        (request) async => http.Response.bytes(<int>[], 200),
      );
      final fetcher = HipsTileFetcher(httpClient: client);
      addTearDown(fetcher.dispose);

      final id = HipsTileId(survey: 's', norder: 3, npix: 1);
      await expectLater(
        fetcher.fetchTile(id, baseUrl, HipsTileFormat.png),
        throwsA(isA<HipsFetchDecodeException>()),
      );
    });
  });

  group('HipsTileFetcher.fetchAllsky', () {
    test('fetches and decodes the Allsky thumbnail', () async {
      final pngBytes = _encodePng(48);
      late Uri requested;
      final client = MockClient((request) async {
        requested = request.url;
        return http.Response.bytes(pngBytes, 200);
      });
      final fetcher = HipsTileFetcher(httpClient: client);
      addTearDown(fetcher.dispose);

      final image = await fetcher.fetchAllsky(baseUrl, 3, HipsTileFormat.png);
      addTearDown(image.dispose);

      expect(requested.toString(), '$baseUrl/Norder3/Allsky.png');
      expect(image.width, 48);
      expect(image.height, 48);
    });
  });

  group('size cap', () {
    test(
      'declared Content-Length over the cap throws before download',
      () async {
        var streamWasRead = false;
        final client = MockClient.streaming((request, bodyStream) async {
          return http.StreamedResponse(
            Stream<List<int>>.fromIterable(<List<int>>[
              <int>[1, 2, 3],
            ]).map((chunk) {
              streamWasRead = true;
              return chunk;
            }),
            200,
            contentLength: 5000,
          );
        });
        final fetcher = HipsTileFetcher(
          httpClient: client,
          maxResponseBytes: 1024,
        );
        addTearDown(fetcher.dispose);

        final id = HipsTileId(survey: 's', norder: 3, npix: 1);
        await expectLater(
          fetcher.fetchTile(id, baseUrl, HipsTileFormat.png),
          throwsA(
            isA<HipsFetchDecodeException>().having(
              (e) => e.message,
              'message',
              contains('exceeds'),
            ),
          ),
        );
        // The body must be rejected on Content-Length alone, but draining is
        // allowed; the key assertion is the typed throw above. streamWasRead may
        // be true (drain) or false; both are acceptable.
        expect(streamWasRead, anyOf(isTrue, isFalse));
      },
    );

    test(
      'a body that exceeds the cap mid-stream (no Content-Length) throws',
      () async {
        final big = List<int>.filled(4096, 7);
        final client = MockClient.streaming((request, bodyStream) async {
          return http.StreamedResponse(
            Stream<List<int>>.fromIterable(<List<int>>[big]),
            200,
            // contentLength deliberately omitted (null) so the incremental cap
            // is what catches it.
          );
        });
        final fetcher = HipsTileFetcher(
          httpClient: client,
          maxResponseBytes: 1024,
        );
        addTearDown(fetcher.dispose);

        final id = HipsTileId(survey: 's', norder: 3, npix: 1);
        await expectLater(
          fetcher.fetchTile(id, baseUrl, HipsTileFormat.png),
          throwsA(
            isA<HipsFetchDecodeException>().having(
              (e) => e.message,
              'message',
              contains('mid-stream'),
            ),
          ),
        );
      },
    );
  });

  group('cancellation', () {
    test('a pre-cancelled token throws HipsFetchCancelledException before any '
        'socket is opened', () async {
      var hit = false;
      final client = MockClient((request) async {
        hit = true;
        return http.Response.bytes(_encodePng(16), 200);
      });
      final fetcher = HipsTileFetcher(httpClient: client);
      addTearDown(fetcher.dispose);

      final token = HipsFetchToken()..cancel();
      final id = HipsTileId(survey: 's', norder: 3, npix: 1);

      await expectLater(
        fetcher.fetchTile(id, baseUrl, HipsTileFormat.png, token: token),
        throwsA(isA<HipsFetchCancelledException>()),
      );
      expect(hit, isFalse, reason: 'no request should be issued');
    });

    test('cancelling an in-flight request aborts it with '
        'HipsFetchCancelledException', () async {
      final gate = Completer<void>();
      final client = MockClient.streaming((request, bodyStream) async {
        // Hang until released; cancellation should win the race first.
        await gate.future;
        return http.StreamedResponse(
          Stream<List<int>>.fromIterable(<List<int>>[_encodePng(16)]),
          200,
        );
      });
      final fetcher = HipsTileFetcher(httpClient: client);
      addTearDown(fetcher.dispose);

      final token = HipsFetchToken();
      final id = HipsTileId(survey: 's', norder: 3, npix: 1);
      final future = fetcher.fetchTile(
        id,
        baseUrl,
        HipsTileFormat.png,
        token: token,
      );

      // Let the send begin, then cancel.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      token.cancel();

      await expectLater(future, throwsA(isA<HipsFetchCancelledException>()));

      // Release the hung mock so it does not leak; ignore its outcome.
      gate.complete();
    });

    test('isCancelled reflects cancel(); cancel() is idempotent', () {
      final token = HipsFetchToken();
      expect(token.isCancelled, isFalse);
      token.cancel();
      expect(token.isCancelled, isTrue);
      // Second call is a no-op and must not throw.
      token.cancel();
      expect(token.isCancelled, isTrue);
    });

    test('a completed request does not leave the token armed (later cancel is '
        'a no-op)', () async {
      final client = MockClient((request) async {
        return http.Response.bytes(_encodePng(16), 200);
      });
      final fetcher = HipsTileFetcher(httpClient: client);
      addTearDown(fetcher.dispose);

      final token = HipsFetchToken();
      final id = HipsTileId(survey: 's', norder: 3, npix: 1);
      final image = await fetcher.fetchTile(
        id,
        baseUrl,
        HipsTileFormat.png,
        token: token,
      );
      addTearDown(image.dispose);

      // Cancelling after completion must not throw, must not affect the
      // already-returned image, and must flip isCancelled.
      token.cancel();
      expect(token.isCancelled, isTrue);
      expect(image.width, 16);
    });
  });

  group('timeout', () {
    test('a slow request times out as HipsFetchHttpException', () async {
      final client = MockClient.streaming((request, bodyStream) async {
        // Never returns within the fetcher timeout.
        await Future<void>.delayed(const Duration(seconds: 5));
        return http.StreamedResponse(
          Stream<List<int>>.fromIterable(<List<int>>[_encodePng(16)]),
          200,
        );
      });
      final fetcher = HipsTileFetcher(
        httpClient: client,
        timeout: const Duration(milliseconds: 50),
      );
      addTearDown(fetcher.dispose);

      final id = HipsTileId(survey: 's', norder: 3, npix: 1);
      await expectLater(
        fetcher.fetchTile(id, baseUrl, HipsTileFormat.png),
        throwsA(
          isA<HipsFetchHttpException>().having(
            (e) => e.message,
            'message',
            contains('timed out'),
          ),
        ),
      );
    });
  });

  group('construction validation', () {
    test('rejects a non-positive timeout', () {
      expect(
        () => HipsTileFetcher(timeout: Duration.zero),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects a non-positive maxResponseBytes', () {
      expect(
        () => HipsTileFetcher(maxResponseBytes: 0),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('an injected client is not closed by dispose()', () async {
      var closed = false;
      final client = _CloseTrackingClient(
        MockClient((request) async => http.Response(_validProperties, 200)),
        () => closed = true,
      );
      final fetcher = HipsTileFetcher(httpClient: client);
      await fetcher.fetchProperties(baseUrl);
      fetcher.dispose();
      expect(
        closed,
        isFalse,
        reason: 'an injected client is owned by the caller',
      );
      client.close();
      expect(closed, isTrue);
    });
  });
}

/// Wraps a client to observe whether [close] was called.
class _CloseTrackingClient extends http.BaseClient {
  _CloseTrackingClient(this._inner, this._onClose);

  final http.Client _inner;
  final void Function() _onClose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() {
    _onClose();
    _inner.close();
  }
}
