// Contract tests for the simple (non-resumable) streaming downloads:
// NetworkBackend.downloadServerLogFile + downloadDark, both backed by the
// shared `_downloadToFile` transport helper. These use a real in-process
// HttpServer because the helper streams through dart:io's HttpClient,
// which the FakeNetworkClient (`MockClient`) cannot intercept — same
// reason the image streaming contract test does.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

Future<HttpServer> _server(
  Future<void> Function(HttpRequest request) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(handler);
  return server;
}

NetworkBackend _backend(HttpServer server, {String? authToken}) =>
    NetworkBackend(
      serverHost: InternetAddress.loopbackIPv4.address,
      serverPort: server.port,
      authToken: authToken,
      autoConnectWebSocket: false,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NetworkBackend streaming file download contract', () {
    test(
      'downloadServerLogFile streams the body to disk with auth + progress',
      () async {
        const bytes = [108, 111, 103, 45, 100, 97, 116, 97]; // "log-data"
        String? requestedPath;
        String? authHeader;
        final server = await _server((request) async {
          requestedPath = request.uri.path;
          authHeader = request.headers.value(HttpHeaders.authorizationHeader);
          request.response.statusCode = HttpStatus.ok;
          request.response.contentLength = bytes.length;
          request.response.add(bytes);
          await request.response.close();
        });
        addTearDown(() => server.close(force: true));
        final backend = _backend(server, authToken: 'log-token');
        addTearDown(backend.dispose);
        final directory = await Directory.systemTemp.createTemp(
          'skotiq-logdl-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final path = '${directory.path}/skotiq.log';

        final progress = <double>[];
        await backend.downloadServerLogFile(
          'skotiq.log.2026-07-19',
          path,
          onProgress: progress.add,
        );

        expect(await File(path).readAsBytes(), bytes);
        expect(requestedPath, '/api/logs/files/skotiq.log.2026-07-19/download');
        expect(authHeader, 'Bearer log-token');
        expect(progress, isNotEmpty);
        expect(progress.last, 1.0);
      },
    );

    test('downloadServerLogFile percent-encodes hostile file names', () async {
      String? requestedPath;
      final server = await _server((request) async {
        requestedPath = request.uri.path;
        request.response.statusCode = HttpStatus.ok;
        request.response.contentLength = 1;
        request.response.add([0]);
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      final backend = _backend(server);
      addTearDown(backend.dispose);
      final directory = await Directory.systemTemp.createTemp('skotiq-logdl-');
      addTearDown(() => directory.delete(recursive: true));

      // A slash-bearing name must stay ONE path segment on the wire so the
      // server's filename validation sees it (and rejects it) instead of the
      // client quietly requesting a different route.
      await backend.downloadServerLogFile(
        '../etc/passwd',
        '${directory.path}/out.log',
      );
      expect(requestedPath, '/api/logs/files/..%2Fetc%2Fpasswd/download');
    });

    test(
      'downloadServerLogFile surfaces an error body without writing a file',
      () async {
        final server = await _server((request) async {
          request.response.statusCode = HttpStatus.notFound;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            '{"error":"log_file_not_found","message":"no such file"}',
          );
          await request.response.close();
        });
        addTearDown(() => server.close(force: true));
        final backend = _backend(server);
        addTearDown(backend.dispose);
        final directory = await Directory.systemTemp.createTemp(
          'skotiq-logdl-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final path = '${directory.path}/missing.log';

        await expectLater(
          backend.downloadServerLogFile('skotiq.log', path),
          throwsA(isA<Object>()),
        );
        expect(await File(path).exists(), isFalse);
      },
    );

    test('a truncated transfer is rejected, not silently kept', () async {
      final server = await _server((request) async {
        // dart:io refuses to close a response below its declared
        // contentLength, so fake the truncation on a detached socket:
        // promise 10 bytes, send 3, drop the connection.
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.write('HTTP/1.1 200 OK\r\ncontent-length: 10\r\n\r\n');
        socket.add([1, 2, 3]);
        await socket.flush();
        await socket.close();
      });
      addTearDown(() => server.close(force: true));
      final backend = _backend(server);
      addTearDown(backend.dispose);
      final directory = await Directory.systemTemp.createTemp('skotiq-logdl-');
      addTearDown(() => directory.delete(recursive: true));

      await expectLater(
        backend.downloadServerLogFile(
          'skotiq.log',
          '${directory.path}/short.log',
        ),
        throwsA(isA<Object>()),
      );
    });

    test('downloadDark hits the calibration route and validates ids', () async {
      const bytes = [70, 73, 84, 83]; // "FITS"
      String? requestedPath;
      final server = await _server((request) async {
        requestedPath = request.uri.path;
        request.response.statusCode = HttpStatus.ok;
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      final backend = _backend(server);
      addTearDown(backend.dispose);
      final directory = await Directory.systemTemp.createTemp('skotiq-darkdl-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/master_dark.fits';

      await backend.downloadDark(7, path);
      expect(await File(path).readAsBytes(), bytes);
      expect(requestedPath, '/api/calibration/darks/7/download');

      // The id guard throws synchronously, before any transport work.
      expect(
        () => backend.downloadDark(0, '${directory.path}/unused.fits'),
        throwsArgumentError,
      );
    });
  });
}
