import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/handlers/narrator_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

void main() {
  group('NarratorHandlers query validation', () {
    late ProviderContainer container;
    late NarratorHandlers handlers;

    setUp(() {
      container = ProviderContainer();
      handlers = NarratorHandlers(container);
    });

    tearDown(() => container.dispose());

    test('feed requires a positive integer sessionId', () async {
      for (final query in const [
        '',
        'sessionId=abc',
        'sessionId=0',
        'sessionId=-1',
      ]) {
        final suffix = query.isEmpty ? '' : '?$query';
        final response = await translateHandlerErrors(
          handlers.handleFeed(
            Request(
              'GET',
              Uri.parse('http://localhost/api/narrator/feed$suffix'),
            ),
          ),
        );
        expect(response.statusCode, HttpStatus.badRequest, reason: query);
      }
    });

    test('recent rejects malformed or out-of-range limits', () async {
      for (final limit in const ['many', '0', '-1', '201']) {
        final response = await translateHandlerErrors(
          handlers.handleRecent(
            Request(
              'GET',
              Uri.parse('http://localhost/api/narrator/recent?limit=$limit'),
            ),
          ),
        );
        expect(response.statusCode, HttpStatus.badRequest, reason: limit);
      }
    });
  });
}
