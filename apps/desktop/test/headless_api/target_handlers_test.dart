import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/handlers/target_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

void main() {
  group('TargetHandlers', () {
    late ProviderContainer container;
    late TargetHandlers handlers;

    setUp(() {
      container = ProviderContainer();
      handlers = TargetHandlers(container);
    });

    tearDown(() {
      container.dispose();
    });

    test('invalid target ID returns JSON internal error', () async {
      final response = await translateHandlerErrors(
        handlers.handleGetTargetById(
          Request('GET', Uri.parse('http://localhost/api/targets/not-an-id')),
          'not-an-id',
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

    test(
      'create target malformed payload returns JSON internal error',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleCreateTarget(
            Request(
              'POST',
              Uri.parse('http://localhost/api/targets'),
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
      'create target rejects unsafe coordinates and planning values',
      () async {
        for (final payload in const [
          {'name': 'Bad RA', 'ra': 99, 'dec': 0},
          {'name': 'Bad Dec', 'ra': 1, 'dec': 100},
          {'name': 'Bad subs', 'ra': 1, 'dec': 0, 'totalPlannedSubs': -1},
          {'name': 'Bad priority', 'ra': 1, 'dec': 0, 'priority': -1},
          {
            'name': 'Bad integration',
            'ra': 1,
            'dec': 0,
            'goalIntegrationSecs': -1,
          },
        ]) {
          final response = await translateHandlerErrors(
            handlers.handleCreateTarget(
              Request(
                'POST',
                Uri.parse('http://localhost/api/targets'),
                body: jsonEncode(payload),
              ),
            ),
          );

          expect(
            response.statusCode,
            HttpStatus.badRequest,
            reason: '$payload',
          );
        }
      },
    );

    test('progress rejects negative counters', () async {
      for (final payload in const [
        {'capturedSubs': -4},
        {'totalIntegrationSecs': -30},
      ]) {
        final response = await translateHandlerErrors(
          handlers.handleUpdateProgress(
            Request(
              'PUT',
              Uri.parse('http://localhost/api/targets/1/progress'),
              body: jsonEncode(payload),
            ),
            '1',
          ),
        );

        expect(response.statusCode, HttpStatus.badRequest, reason: '$payload');
      }
    });

    test(
      'update progress malformed payload returns JSON internal error',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleUpdateProgress(
            Request(
              'PUT',
              Uri.parse('http://localhost/api/targets/1/progress'),
              body: '{',
            ),
            '1',
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
  });
}
