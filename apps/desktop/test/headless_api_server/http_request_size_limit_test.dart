// The request-size-limit middleware must NOT buffer an unauthenticated
// chunked body up to the per-path cap before auth runs.
//
// The header-only Content-Length ceiling still rejects a declared over-limit
// upload with 413 before auth (cheap, no body read), but a chunked body that
// omits Content-Length is only buffered AFTER the bearer token is checked, so
// an unauthenticated client to a protected path is rejected with 401 before any
// of its body is read. Authenticated uploads keep the streaming cap (413 over
// limit, success within limit).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api_server.dart';

import '../headless_api/handler_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HeadlessApiServer request-size limit ordering', () {
    late ProviderContainer container;
    late HeadlessApiServer server;
    late Uri baseUri;

    setUp(() async {
      container = createHeadlessTestContainer(
        overrides: [
          appVersionProvider.overrideWithValue(
            const AppVersionInfo(version: '2.5.0', buildNumber: 5),
          ),
        ],
      );
      server = HeadlessApiServer(
        port: 0,
        container: container,
        bindLocalOnly: true,
        authToken: 'admin-token',
      );
      await server.start();
      baseUri = Uri.parse('http://127.0.0.1:${server.actualPort}');
    });

    tearDown(() async {
      await server.stop();
      container.dispose();
    });

    test('unauthenticated chunked upload is rejected with 401 before the body '
        'is buffered', () async {
      // A small chunked body (well under any cap) to the admin-only catalog
      // upload endpoint. The point is that auth rejects it with 401 — the body
      // is never buffered, so the per-path 1 GiB cap is unreachable pre-auth.
      const body = 'payload-that-must-never-be-buffered';
      final response = await _rawSocketRequest(
        baseUri,
        const [
          'POST /api/catalog/upload HTTP/1.1',
          'Content-Type: application/octet-stream',
          'Transfer-Encoding: chunked',
          'Connection: close',
        ],
        host: '127.0.0.1',
        port: server.actualPort,
        body: _chunked(body),
      );

      expect(response.statusCode, HttpStatus.unauthorized);
      expect(response.body['error'], 'Authentication required');
    });

    // The declared-Content-Length 413-before-auth path (header-only, no body
    // read) is preserved unchanged and is already covered by
    // auth_middleware_test's "rejects oversized control requests before auth".

    test(
      'authenticated within-limit chunked upload reaches the handler',
      () async {
        final response = await _rawSocketRequest(
          baseUri,
          const [
            'POST /api/files/validate HTTP/1.1',
            'Authorization: Bearer admin-token',
            'Content-Type: application/json',
            'Transfer-Encoding: chunked',
            'Connection: close',
          ],
          host: '127.0.0.1',
          port: server.actualPort,
          body: _chunked('{"path":""}'),
        );

        // The handler ran (it buffered the chunked body post-auth) and answered
        // the empty-path validation with a 200 envelope, proving the streaming
        // cap still admits within-limit authenticated uploads.
        expect(response.statusCode, HttpStatus.ok);
        expect(response.body['valid'], isFalse);
      },
    );

    test(
      'authenticated oversized chunked upload is rejected with 413',
      () async {
        final big = 'x' * (1024 * 1024 + 1);
        final response = await _rawSocketRequest(
          baseUri,
          const [
            'POST /api/mount/slew HTTP/1.1',
            'Authorization: Bearer admin-token',
            'Content-Type: application/json',
            'Transfer-Encoding: chunked',
            'Connection: close',
          ],
          host: '127.0.0.1',
          port: server.actualPort,
          body: _chunked(big),
        );

        expect(response.statusCode, HttpStatus.requestEntityTooLarge);
        expect(response.body['error'], 'Request body too large');
        expect(response.body['maxBytes'], 1024 * 1024);
      },
    );
  });
}

String _chunked(String body) =>
    '${body.length.toRadixString(16)}\r\n$body\r\n0\r\n\r\n';

Future<_RawResponse> _rawSocketRequest(
  Uri baseUri,
  List<String> headers, {
  required String host,
  required int port,
  String body = '',
}) async {
  final socket = await Socket.connect(host, port);
  final requestLine = headers.first;
  final rest = headers.skip(1).toList();
  socket.write(
    '$requestLine\r\nHost: $host:$port\r\n${rest.join('\r\n')}\r\n\r\n$body',
  );
  await socket.flush();

  final responseText = await utf8.decoder.bind(socket).join();
  await socket.close();

  final separator = responseText.indexOf('\r\n\r\n');
  final head = separator == -1
      ? responseText
      : responseText.substring(0, separator);
  final responseBody = separator == -1
      ? ''
      : responseText.substring(separator + 4);
  final statusLine = head.split('\r\n').first;
  final statusCode = int.parse(statusLine.split(' ')[1]);
  final parsedBody = responseBody.trim().isEmpty
      ? const <String, dynamic>{}
      : jsonDecode(responseBody) as Map<String, dynamic>;
  return _RawResponse(statusCode: statusCode, body: parsedBody);
}

class _RawResponse {
  final int statusCode;
  final Map<String, dynamic> body;

  const _RawResponse({required this.statusCode, required this.body});
}
