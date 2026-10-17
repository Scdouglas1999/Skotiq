import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/handlers/device_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

void main() {
  group('DeviceHandlers live view', () {
    late ProviderContainer container;
    late DeviceHandlers handlers;

    setUp(() {
      container = ProviderContainer();
      handlers = DeviceHandlers(container);
    });

    tearDown(() {
      container.dispose();
    });

    test('live view missing deviceId returns JSON bad request', () async {
      final response = await translateHandlerErrors(
        handlers.handleCameraLiveViewFrame(
          Request(
            'GET',
            Uri.parse('http://localhost/api/camera/live-view/frame'),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
    });

    test('live view unknown camera returns JSON not found', () async {
      final response = await translateHandlerErrors(
        handlers.handleCameraLiveViewFrame(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/api/camera/live-view/frame?deviceId=missing-camera',
            ),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.notFound);
    });
  });
}
