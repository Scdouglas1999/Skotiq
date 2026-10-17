// `POST /api/profiles` must refuse a physically impossible optical train.
//
// Focal length is written to the FITS `FOCALLEN` card and drives plate-solve
// field-of-view estimation and arcsec/px image scale, so accepting focalLength
// 999999999 with aperture 0.0001 — f/9999999990000 — silently corrupts
// astrometry and every derived measurement for that rig.
//
// This drives a real socket against the real route table and the real
// middleware stack rather than calling the handler directly, so it proves what
// a remote client actually receives. Raw sockets (not `HttpClient`) because
// `TestWidgetsFlutterBinding` stubs every `HttpClient` request to a canned 400.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api_server.dart';

import '../headless_api/handler_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('POST /api/profiles optical-train bounds over real HTTP', () {
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

    Future<_RawResponse> send(
      String method,
      String path, {
      Map<String, dynamic>? json,
    }) =>
        _rawRequest(server.actualPort, method: method, path: path, json: json);

    /// The literal payload that was accepted live, minus the fields that only
    /// identify the row.
    Map<String, dynamic> absurdProfile() => <String, dynamic>{
      'id': '0',
      'name': 'AGENT PROBE absurd optics',
      'focalLength': 999999999.0,
      'aperture': 0.0001,
      'focalRatio': 9999999990000.0,
      'pixelSize': 99999.0,
      'defaultGain': 100,
      'defaultOffset': 10,
      'defaultBinX': 1,
      'defaultBinY': 1,
      'defaultCoolingTemp': -10.0,
      'coolOnConnect': false,
      'telescopeFocalLength': 0.0,
      'telescopeAperture': 0.0,
      'sortOrder': 0,
      'isDefault': false,
      'isActive': false,
    };

    test('the absurd train is refused and never persisted', () async {
      final save = await send(
        'POST',
        '/api/profiles',
        json: {'profile': absurdProfile()},
      );

      expect(save.statusCode, HttpStatus.badRequest);
      expect(save.body['code'], 'invalid_request');
      // Assert the literal so the operator-facing wording is part of the
      // contract, not an accident of formatting.
      expect(
        save.body['message'],
        'Focal length must be between 1 and 50000 mm.',
      );

      final list = await send('GET', '/api/profiles');
      expect(list.statusCode, HttpStatus.ok);
      expect(
        list.body['profiles'],
        isEmpty,
        reason: 'a rejected profile must leave no row behind',
      );
    });

    test('a real rig still saves and reads back intact', () async {
      // EdgeHD 8 with a 0.7x reducer: 1422 mm at 203.2 mm is f/7, a real and
      // very common configuration.
      final save = await send(
        'POST',
        '/api/profiles',
        json: {
          'profile': {
            ...absurdProfile(),
            'name': 'EdgeHD 8 + 0.7x',
            'focalLength': 1422.0,
            'aperture': 203.2,
            'focalRatio': 7.0,
            'pixelSize': 3.76,
          },
        },
      );
      expect(save.statusCode, HttpStatus.ok);
      expect(save.body['status'], 'saved');

      final list = await send('GET', '/api/profiles');
      final profiles = (list.body['profiles'] as List)
          .cast<Map<String, dynamic>>();
      expect(profiles, hasLength(1));
      expect(profiles.single['focalLength'], 1422.0);
      expect(profiles.single['aperture'], 203.2);
    });
  });
}

Future<_RawResponse> _rawRequest(
  int port, {
  required String method,
  required String path,
  Map<String, dynamic>? json,
}) async {
  const host = '127.0.0.1';
  final body = json == null ? '' : jsonEncode(json);
  final bytes = utf8.encode(body);
  final socket = await Socket.connect(host, port);
  socket.write(
    '$method $path HTTP/1.1\r\n'
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
  final statusCode = int.parse(head.split('\r\n').first.split(' ')[1]);
  return _RawResponse(
    statusCode: statusCode,
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
