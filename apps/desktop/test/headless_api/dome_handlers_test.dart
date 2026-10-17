import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/handlers/dome_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

void main() {
  group('DomeHandlers', () {
    late ProviderContainer container;
    late DomeHandlers handlers;

    setUp(() {
      container = ProviderContainer();
      handlers = DomeHandlers(container);
    });

    tearDown(() {
      container.dispose();
    });

    test('sync missing deviceId returns JSON bad request', () async {
      final response = await translateHandlerErrors(
        handlers.handleDomeSync(
          Request(
            'POST',
            Uri.parse('http://localhost/api/dome/sync'),
            body: jsonEncode({'enable': true}),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], isA<String>());
    });

    test('home missing deviceId returns JSON bad request', () async {
      final response = await translateHandlerErrors(
        handlers.handleDomeHome(
          Request(
            'POST',
            Uri.parse('http://localhost/api/dome/home'),
            body: jsonEncode({}),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
    });

    test('halt missing deviceId returns JSON bad request', () async {
      final response = await translateHandlerErrors(
        handlers.handleDomeHalt(
          Request(
            'POST',
            Uri.parse('http://localhost/api/dome/halt'),
            body: jsonEncode({}),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
    });

    test('sync unknown dome returns JSON not found', () async {
      final response = await translateHandlerErrors(
        handlers.handleDomeSync(
          Request(
            'POST',
            Uri.parse('http://localhost/api/dome/sync'),
            body: jsonEncode({'deviceId': 'missing-dome', 'enable': true}),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.notFound);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], 'Dome not connected');
    });
  });
}
