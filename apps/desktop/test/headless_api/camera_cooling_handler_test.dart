// POST /api/camera/cooling request validation.
//
// The cooling handler must reject a non-finite target temperature with a
// structured 400 BEFORE the backend is touched, so a remote client (or a
// malformed script) cannot drive NaN/±∞ into the cooler control loop. The
// shared `optionalDouble`/`requireDouble` request helpers enforce finiteness;
// these tests pin that contract at the handler boundary and confirm the valid
// and disable-cooling paths still reach the backend intact.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/disconnected_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_desktop/headless_api/handlers/device_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

Request _coolingRequest(String body) => Request(
  'POST',
  Uri.parse('http://localhost/api/camera/cooling'),
  body: body,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _CoolingCaptureBackend backend;
  late ProviderContainer container;
  late DeviceHandlers handlers;

  setUp(() {
    backend = _CoolingCaptureBackend();
    container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
      ],
    );
    handlers = DeviceHandlers(container);
  });

  tearDown(() => container.dispose());

  test('NaN target is a structured 400 before the backend', () async {
    final response = await translateHandlerErrors(
      handlers.handleCameraSetCooling(
        _coolingRequest(
          jsonEncode({
            'deviceId': 'cam-1',
            'enabled': true,
            'targetTemp': 'NaN',
          }),
        ),
      ),
    );

    expect(response.statusCode, HttpStatus.badRequest);
    final body = jsonDecode(await response.readAsString()) as Map;
    expect(body['field'], 'targetTemp');
    expect(
      backend.calls,
      isEmpty,
      reason: 'validation must fail before any backend call',
    );
  });

  test('Infinity target is a structured 400 before the backend', () async {
    final response = await translateHandlerErrors(
      handlers.handleCameraSetCooling(
        _coolingRequest(
          jsonEncode({
            'deviceId': 'cam-1',
            'enabled': true,
            'targetTemp': 'Infinity',
          }),
        ),
      ),
    );

    expect(response.statusCode, HttpStatus.badRequest);
    expect(backend.calls, isEmpty);
  });

  test('an overflowing numeric literal (1e400 -> inf) is rejected', () async {
    // A raw JSON number that decodes to a non-finite double must be caught too
    // — not just string spellings of NaN/Infinity.
    final response = await translateHandlerErrors(
      handlers.handleCameraSetCooling(
        _coolingRequest(
          '{"deviceId":"cam-1","enabled":true,"targetTemp":1e400}',
        ),
      ),
    );

    expect(response.statusCode, HttpStatus.badRequest);
    expect(backend.calls, isEmpty);
  });

  test('a finite target reaches the backend with 200', () async {
    final response = await translateHandlerErrors(
      handlers.handleCameraSetCooling(
        _coolingRequest(
          jsonEncode({'deviceId': 'cam-1', 'enabled': true, 'targetTemp': -10}),
        ),
      ),
    );

    expect(response.statusCode, HttpStatus.ok);
    expect(backend.calls, [
      (deviceId: 'cam-1', enabled: true, targetTemp: -10.0),
    ]);
  });

  test('disable cooling with no target still reaches the backend', () async {
    final response = await translateHandlerErrors(
      handlers.handleCameraSetCooling(
        _coolingRequest(jsonEncode({'deviceId': 'cam-1', 'enabled': false})),
      ),
    );

    expect(response.statusCode, HttpStatus.ok);
    expect(backend.calls, [
      (deviceId: 'cam-1', enabled: false, targetTemp: null),
    ]);
  });
}

typedef _CoolingCall = ({String deviceId, bool enabled, double? targetTemp});

class _CoolingCaptureBackend extends DisconnectedBackend {
  final List<_CoolingCall> calls = [];

  @override
  Future<void> cameraSetCooling({
    required String deviceId,
    required bool enabled,
    double? targetTemp,
  }) async {
    calls.add((deviceId: deviceId, enabled: enabled, targetTemp: targetTemp));
  }
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}
