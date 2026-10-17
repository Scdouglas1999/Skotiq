// What a remote client actually receives for a number JSON cannot carry.
//
// Live against the release bundle, `POST /api/post-session/integrate` with
// `"exposuresSec":[1e400]` answered `200 {"status":"queued"}` and then failed
// the job with "Converting object to an encodable object failed: Infinity" —
// an encoder artifact naming no field, no index and no next step, on the one
// surface whose every other refusal names all three.
//
// This drives a real socket against the real route table and the real
// middleware stack, and it writes the body as raw bytes rather than through
// `jsonEncode`, because `1e400` is exactly what curl put on the wire and
// Dart's encoder cannot write the `double.infinity` its decoder reads back.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api_server.dart';

import '../headless_api/handler_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('post-session non-finite numbers over real HTTP', () {
    late ProviderContainer container;
    late HeadlessApiServer server;

    setUp(() async {
      container = createHeadlessTestContainer();
      server = HeadlessApiServer(
        port: 0,
        container: container,
        bindLocalOnly: true,
        authToken: 'admin-token',
      );
      await server.start();
    });

    tearDown(() async {
      await server.stop();
      container.dispose();
    });

    test('integrate refuses it as a typed 400 naming the entry', () async {
      final response = await _rawRequest(
        server.actualPort,
        path: '/api/post-session/integrate',
        body:
            '{"runId":"x","lightPaths":["/tmp/a.fits"],"exposuresSec":[1e400],'
            '"calibration":{},"settings":{},'
            '"output":{"masterFitsPath":"/tmp/o.fits"}}',
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(response.body['code'], 'invalid_request');
      expect(response.body['field'], 'exposuresSec[0]');
      expect(
        response.body['message'],
        'exposuresSec[0] is Infinity, which is not a finite number; every '
        'numeric field must be a finite value',
      );
      expect(
        response.body.containsKey('jobId'),
        isFalse,
        reason: 'nothing is queued for a request that cannot be forwarded',
      );
    });

    test('master-accumulate refuses it the same way', () async {
      final response = await _rawRequest(
        server.actualPort,
        path: '/api/post-session/master-accumulate',
        body:
            '{"op":"add","masterPath":"/tmp/m.fits",'
            '"lightPaths":["/tmp/a.fits"],"exposuresSec":[-1e400],'
            '"calibration":{},"settings":{}}',
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(response.body['field'], 'exposuresSec[0]');
      expect(response.body['message'], contains('-Infinity'));
    });
  });
}

Future<_RawResponse> _rawRequest(
  int port, {
  required String path,
  required String body,
}) async {
  const host = '127.0.0.1';
  final bytes = utf8.encode(body);
  final socket = await Socket.connect(host, port);
  socket.write(
    'POST $path HTTP/1.1\r\n'
    'Host: $host:$port\r\n'
    'Authorization: Bearer admin-token\r\n'
    'Content-Type: application/json\r\n'
    'Content-Length: ${bytes.length}\r\n'
    'Connection: close\r\n'
    '\r\n'
    '$body',
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
  return _RawResponse(
    statusCode: int.parse(head.split('\r\n').first.split(' ')[1]),
    body: responseBody.trim().isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(responseBody) as Map<String, dynamic>,
  );
}

class _RawResponse {
  final int statusCode;
  final Map<String, dynamic> body;

  const _RawResponse({required this.statusCode, required this.body});
}
