import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/handlers/framing_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

void main() {
  group('FramingHandlers', () {
    late ProviderContainer container;
    late FramingHandlers handlers;

    setUp(() {
      container = ProviderContainer();
      handlers = FramingHandlers(container);
    });

    tearDown(() {
      container.dispose();
    });

    test(
      'slew to target malformed payload returns JSON internal error',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleSlewToTarget(
            Request(
              'POST',
              Uri.parse('http://localhost/api/framing/slew-to-target'),
              body: jsonEncode({}),
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
      },
    );

    test(
      'center on target malformed payload returns JSON internal error',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleCenterOnTarget(
            Request(
              'POST',
              Uri.parse('http://localhost/api/framing/center-on-target'),
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
      },
    );

    test(
      'center on target rejects out-of-range coordinates and settings',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleCenterOnTarget(
            Request(
              'POST',
              Uri.parse('http://localhost/api/framing/center-on-target'),
              body: jsonEncode({
                'ra': 25,
                'dec': 45,
                'maxIterations': 0,
                'exposureTime': -1,
              }),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.badRequest);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['field'], 'ra');
        expect(body['error'], contains('<= 24'));
      },
    );

    test('save framing malformed payload returns JSON error', () async {
      final response = await translateHandlerErrors(
        handlers.handleSaveFraming(
          Request(
            'POST',
            Uri.parse('http://localhost/api/framing/save'),
            body: jsonEncode({'ra': 1.0}),
          ),
        ),
      );

      expect(
        response.statusCode,
        anyOf(HttpStatus.badRequest, HttpStatus.internalServerError),
      );
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], isA<String>());
    });

    test('save framing rejects impossible coordinates and rotation', () async {
      for (final payload in const [
        {'name': 'Bad RA', 'ra': 99, 'dec': 0, 'positionAngle': 0},
        {'name': 'Bad Dec', 'ra': 1, 'dec': 100, 'positionAngle': 0},
        {'name': 'Bad PA', 'ra': 1, 'dec': 0, 'positionAngle': 720},
      ]) {
        final response = await translateHandlerErrors(
          handlers.handleSaveFraming(
            Request(
              'POST',
              Uri.parse('http://localhost/api/framing/save'),
              body: jsonEncode(payload),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.badRequest, reason: '$payload');
      }
    });

    test('rotate to malformed payload returns JSON internal error', () async {
      final response = await translateHandlerErrors(
        handlers.handleRotateTo(
          Request(
            'POST',
            Uri.parse('http://localhost/api/framing/rotate-to'),
            body: jsonEncode({}),
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
  });
}
