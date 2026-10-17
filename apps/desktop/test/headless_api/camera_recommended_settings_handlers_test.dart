import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/disconnected_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart'
    show CameraRecommendedSettings;
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_desktop/headless_api/handlers/device_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GET /api/camera/recommended-settings', () {
    late ProviderContainer container;
    late DeviceHandlers handlers;

    setUp(() {
      container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith((ref) => _TestBackendNotifier(ref)),
        ],
      );
      handlers = DeviceHandlers(container);
    });

    tearDown(() {
      container.dispose();
    });

    test(
      'returns 200 with full CameraRecommendedSettings JSON shape',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleCameraGetRecommendedSettings(
            Request(
              'GET',
              Uri.parse(
                'http://localhost/api/camera/recommended-settings'
                '?deviceId=native:zwo:1',
              ),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        expect(response.headers['content-type'], 'application/json');
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body, containsPair('unityGain', 120));
        expect(body, containsPair('hcgGain', isNull));
        expect(body, containsPair('defaultOffset', 30));
        // A camera whose SDK reports no cooling setpoint must project the
        // field as JSON `null`, not omit it — remote clients recover the
        // same honest "not reported" state the FFI backend sees.
        expect(body, containsPair('recommendedCoolingSetpointC', isNull));
        expect(body, containsPair('notes', 'fixture'));
      },
    );

    test(
      'carries a non-null recommendedCoolingSetpointC through the JSON',
      () async {
        final localContainer = ProviderContainer(
          overrides: [
            backendProvider.overrideWith(
              (ref) => _TestBackendNotifier(
                ref,
                const CameraRecommendedSettings(
                  unityGain: 100,
                  hcgGain: 200,
                  defaultOffset: 50,
                  recommendedCoolingSetpointC: -10.0,
                  notes: 'cooled',
                ),
              ),
            ),
          ],
        );
        addTearDown(localContainer.dispose);
        final localHandlers = DeviceHandlers(localContainer);

        final response = await translateHandlerErrors(
          localHandlers.handleCameraGetRecommendedSettings(
            Request(
              'GET',
              Uri.parse(
                'http://localhost/api/camera/recommended-settings'
                '?deviceId=native:zwo:1',
              ),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body, containsPair('unityGain', 100));
        expect(body, containsPair('hcgGain', 200));
        expect(body, containsPair('defaultOffset', 50));
        expect(body, containsPair('recommendedCoolingSetpointC', -10.0));
        expect(body, containsPair('notes', 'cooled'));
      },
    );

    test('returns 400 when deviceId query parameter is missing', () async {
      final response = await translateHandlerErrors(
        handlers.handleCameraGetRecommendedSettings(
          Request(
            'GET',
            Uri.parse('http://localhost/api/camera/recommended-settings'),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], isA<String>());
      expect(body['error'], contains('deviceId'));
    });
  });
}

class _FixtureBackend extends DisconnectedBackend {
  _FixtureBackend([CameraRecommendedSettings? recommended])
    : _recommended =
          recommended ??
          // Default: a deterministic non-empty struct whose cooling setpoint
          // is null, so the handler test can assert the wire shape exactly
          // (unityGain present, hcgGain null, defaultOffset present,
          // recommendedCoolingSetpointC null, notes carried through).
          const CameraRecommendedSettings(
            unityGain: 120,
            defaultOffset: 30,
            notes: 'fixture',
          );

  final CameraRecommendedSettings _recommended;

  @override
  Future<CameraRecommendedSettings> cameraGetRecommendedSettings(
    String deviceId,
  ) async => _recommended;
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, [CameraRecommendedSettings? recommended]) {
    state = _FixtureBackend(recommended);
  }
}
