import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

Future<HttpServer> _server(
  Future<void> Function(HttpRequest request) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(handler);
  return server;
}

NetworkBackend _backend(
  HttpServer server, {
  String? authToken,
  Future<String?> Function()? refreshAuthToken,
}) => NetworkBackend(
  serverHost: InternetAddress.loopbackIPv4.address,
  serverPort: server.port,
  authToken: authToken,
  refreshAuthToken: refreshAuthToken,
  autoConnectWebSocket: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NetworkBackend image streaming contract', () {
    test(
      'thumbnail sends compatibility/auth headers and refreshes once',
      () async {
        final observed = <HttpHeaders>[];
        var requestCount = 0;
        final server = await _server((request) async {
          requestCount++;
          observed.add(request.headers);
          if (requestCount == 1) {
            request.response.statusCode = HttpStatus.unauthorized;
            request.response.headers.contentType = ContentType.json;
            request.response.write('{"error":"expired"}');
          } else {
            request.response.statusCode = HttpStatus.ok;
            request.response.contentLength = 3;
            request.response.add([1, 2, 3]);
          }
          await request.response.close();
        });
        addTearDown(() => server.close(force: true));
        var refreshCount = 0;
        final backend = _backend(
          server,
          authToken: 'old-token',
          refreshAuthToken: () async {
            refreshCount++;
            return 'new-token';
          },
        );
        addTearDown(backend.dispose);

        expect(
          await backend.getImageThumbnail(3),
          Uint8List.fromList([1, 2, 3]),
        );
        expect(refreshCount, 1);
        expect(observed, hasLength(2));
        expect(
          observed[0].value(HttpHeaders.authorizationHeader),
          'Bearer old-token',
        );
        expect(
          observed[1].value(HttpHeaders.authorizationHeader),
          'Bearer new-token',
        );
        expect(observed[0].value('x-skotiq-api-version'), isNotEmpty);
        expect(observed[0].value('x-request-id'), isNotEmpty);
        expect(
          observed[1].value('x-request-id'),
          isNot(observed[0].value('x-request-id')),
        );
      },
    );

    test(
      'interrupted downloads resume only with matching ETag metadata',
      () async {
        const bytes = [97, 98, 99, 100, 101, 102, 103, 104, 105, 106];
        final server = await _server((request) async {
          request.response.headers.set(HttpHeaders.etagHeader, '"image-v1"');
          expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=5-');
          expect(
            request.headers.value(HttpHeaders.ifRangeHeader),
            '"image-v1"',
          );
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 5-9/10',
          );
          request.response.contentLength = 5;
          request.response.add(bytes.skip(5).toList());
          await request.response.close();
        });
        addTearDown(() => server.close(force: true));
        final backend = _backend(server);
        addTearDown(backend.dispose);
        final directory = await Directory.systemTemp.createTemp(
          'skotiq-image-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final path = '${directory.path}/frame.fits';
        await File(path).writeAsBytes(bytes.take(5).toList());
        await File('$path.skotiq-download').writeAsString(
          jsonEncode({'imageId': 9, 'etag': '"image-v1"', 'totalLength': 10}),
        );

        await backend.downloadImage(9, path);

        expect(await File(path).readAsBytes(), bytes);
        expect(await File('$path.skotiq-download').exists(), isFalse);
      },
    );

    test(
      'an unverified existing file is replaced instead of blindly resumed',
      () async {
        const bytes = [1, 2, 3, 4];
        final server = await _server((request) async {
          expect(request.headers.value(HttpHeaders.rangeHeader), isNull);
          expect(request.headers.value(HttpHeaders.ifRangeHeader), isNull);
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.set(HttpHeaders.etagHeader, '"image-v2"');
          request.response.contentLength = bytes.length;
          request.response.add(bytes);
          await request.response.close();
        });
        addTearDown(() => server.close(force: true));
        final backend = _backend(server);
        addTearDown(backend.dispose);
        final directory = await Directory.systemTemp.createTemp(
          'skotiq-image-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final path = '${directory.path}/frame.fits';
        await File(path).writeAsBytes([9, 9]);

        await backend.downloadImage(9, path);

        expect(await File(path).readAsBytes(), bytes);
      },
    );

    test(
      'rejects unsolicited partial content without creating a file',
      () async {
        final server = await _server((request) async {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers
            ..set(HttpHeaders.contentRangeHeader, 'bytes 0-2/3')
            ..set(HttpHeaders.etagHeader, '"image-v1"');
          request.response.contentLength = 3;
          request.response.add([1, 2, 3]);
          await request.response.close();
        });
        addTearDown(() => server.close(force: true));
        final backend = _backend(server);
        addTearDown(backend.dispose);
        final directory = await Directory.systemTemp.createTemp(
          'skotiq-image-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final path = '${directory.path}/frame.fits';

        await expectLater(
          backend.downloadImage(9, path),
          throwsFormatException,
        );
        expect(await File(path).exists(), isFalse);
      },
    );

    test('rejects invalid image identifiers before transport', () async {
      var called = false;
      final server = await _server((request) async {
        called = true;
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      final backend = _backend(server);
      addTearDown(backend.dispose);

      await expectLater(backend.getImageThumbnail(0), throwsArgumentError);
      await expectLater(
        backend.downloadImage(-1, '/tmp/unused-skotiq-image'),
        throwsArgumentError,
      );
      expect(called, isFalse);
    });
  });
}
