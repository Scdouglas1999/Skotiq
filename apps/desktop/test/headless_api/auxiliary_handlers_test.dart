import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/auxiliary_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

/// Minimal [DeviceBackend] whose connected-device list is scriptable; every
/// other method loud-fails via [noSuchMethod] so an accidental dependency is
/// obvious.
class _FakeDeviceBackend implements DeviceBackend {
  _FakeDeviceBackend(this.connected);
  final List<DeviceInfo> connected;

  @override
  Future<List<DeviceInfo>> getConnectedDevices() async => connected;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('AuxiliaryHandlers', () {
    late ProviderContainer container;
    late AuxiliaryHandlers handlers;

    setUp(() {
      container = ProviderContainer();
      handlers = AuxiliaryHandlers(container);
    });

    tearDown(() {
      container.dispose();
    });

    test('cover status reports missing deviceId as JSON bad request', () async {
      final response = await translateHandlerErrors(
        handlers.handleCoverStatus(
          Request('GET', Uri.parse('http://localhost/api/cover/status')),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], 'deviceId query parameter is required');
    });

    test(
      'cover mutations return a clean 404 (not 500) when no cover is connected',
      () async {
        // The native bridge throws an opaque 500 when nothing is attached, so
        // the cover open/close/brightness/calibrator handlers must check first
        // and answer the same "not connected" 404 the switch/dome handlers do.
        final scoped = ProviderContainer(
          overrides: [
            deviceBackendProvider.overrideWithValue(
              _FakeDeviceBackend(const []),
            ),
          ],
        );
        addTearDown(scoped.dispose);
        final scopedHandlers = AuxiliaryHandlers(scoped);

        final endpoints = <String, Future<Response> Function(Request)>{
          '/api/cover/close': scopedHandlers.handleCoverClose,
          '/api/cover/open': scopedHandlers.handleCoverOpen,
          '/api/cover/calibrator-off': scopedHandlers.handleCalibratorOff,
        };
        for (final entry in endpoints.entries) {
          final response = await translateHandlerErrors(
            entry.value(
              Request(
                'POST',
                Uri.parse('http://localhost${entry.key}'),
                body: jsonEncode({'deviceId': 'cover-1'}),
              ),
            ),
          );
          expect(
            response.statusCode,
            HttpStatus.notFound,
            reason: '${entry.key} must be 404 when no cover is connected',
          );
          final body = jsonDecode(await response.readAsString()) as Map;
          expect(body['error'], 'Cover calibrator not connected');
          expect(body['connected'], false);
        }
      },
    );

    test('switch set reports missing deviceId as JSON bad request', () async {
      final response = await translateHandlerErrors(
        handlers.handleSwitchSet(
          Request(
            'POST',
            Uri.parse('http://localhost/api/switch/set'),
            body: jsonEncode({'switchId': 0, 'value': true}),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], 'deviceId is required');
    });

    test(
      'cover brightness validates required and non-negative values',
      () async {
        final missingDevice = await translateHandlerErrors(
          handlers.handleCoverBrightness(
            Request(
              'POST',
              Uri.parse('http://localhost/api/cover/brightness'),
              body: jsonEncode({'brightness': 10}),
            ),
          ),
        );
        expect(missingDevice.statusCode, HttpStatus.badRequest);
        expect(missingDevice.headers['content-type'], 'application/json');
        expect(
          (jsonDecode(await missingDevice.readAsString()) as Map)['error'],
          'deviceId is required',
        );

        final negativeBrightness = await translateHandlerErrors(
          handlers.handleCoverBrightness(
            Request(
              'POST',
              Uri.parse('http://localhost/api/cover/brightness'),
              body: jsonEncode({'deviceId': 'cover-1', 'brightness': -1}),
            ),
          ),
        );
        expect(negativeBrightness.statusCode, HttpStatus.badRequest);
        expect(
          (jsonDecode(await negativeBrightness.readAsString()) as Map)['error'],
          'Value must be >= 0.0',
        );
      },
    );

    test(
      'calibrator on validates defaultable brightness before bridge calls',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleCalibratorOn(
            Request(
              'POST',
              Uri.parse('http://localhost/api/cover/calibrator-on'),
              body: jsonEncode({'deviceId': 'cover-1', 'brightness': -10}),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.badRequest);
        expect(response.headers['content-type'], 'application/json');
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], 'Value must be >= 0.0');
      },
    );
  });
}
