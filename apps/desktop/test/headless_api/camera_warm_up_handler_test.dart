// The camera warm-up runs on the host: a client starts and cancels it through
// /api/camera/warm-up, and a cooler command from a client replaces it.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/device_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

class _MockDeviceService extends Mock implements DeviceService {}

class _MockDeviceBackend extends Mock implements DeviceBackend {}

Request _post(String path, [Map<String, dynamic>? body]) => Request(
  'POST',
  Uri.parse('http://localhost$path'),
  body: body == null ? '' : jsonEncode(body),
);

void main() {
  late _MockDeviceService service;
  late _MockDeviceBackend backend;
  late ProviderContainer container;
  late DeviceHandlers handlers;

  setUp(() {
    service = _MockDeviceService();
    backend = _MockDeviceBackend();
    when(
      () => service.warmCamera(ratePerMin: any(named: 'ratePerMin')),
    ).thenAnswer((_) async => CameraWarmupOutcome.started);
    when(
      () => service.setCameraCooling(
        enabled: any(named: 'enabled'),
        targetTemp: any(named: 'targetTemp'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => backend.cameraSetCooling(
        deviceId: any(named: 'deviceId'),
        enabled: any(named: 'enabled'),
        targetTemp: any(named: 'targetTemp'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => backend.getCameraCapabilities(any()),
    ).thenAnswer((_) async => null);
    container = createHeadlessTestContainer(
      overrides: [
        deviceServiceProvider.overrideWithValue(service),
        deviceBackendProvider.overrideWithValue(backend),
      ],
    );
    final camera = container.read(cameraStateProvider.notifier);
    camera.setConnecting('sim_camera_1');
    camera.setConnected();
    handlers = DeviceHandlers(container);
  });

  tearDown(() => container.dispose());

  test('POST /api/camera/warm-up runs the warm-up on the host', () async {
    final response = await translateHandlerErrors(
      handlers.handleCameraStartWarmUp(
        _post('/api/camera/warm-up', {'ratePerMin': 1.5}),
      ),
    );

    expect(response.statusCode, HttpStatus.ok);
    expect(jsonDecode(await response.readAsString())['outcome'], 'started');
    verify(() => service.warmCamera(ratePerMin: 1.5)).called(1);
  });

  test('a run that owns the cooler refuses the warm-up with 409', () async {
    container.read(runRecordProvider.notifier).setLifecycle(SequenceExecutionState.running);

    final response = await handlers.handleCameraStartWarmUp(
      _post('/api/camera/warm-up'),
    );

    expect(response.statusCode, HttpStatus.conflict);
    verifyNever(() => service.warmCamera(ratePerMin: any(named: 'ratePerMin')));
  });

  test('POST /api/camera/warm-up/cancel restores the prior set-point by '
      'default', () async {
    final response = await handlers.handleCameraCancelWarmUp(
      _post('/api/camera/warm-up/cancel'),
    );

    expect(response.statusCode, HttpStatus.ok);
    verify(() => service.cancelWarmCamera(restorePriorSetting: true)).called(1);
  });

  test(
    'a cooler command from a client replaces a warm-up in progress',
    () async {
      await translateHandlerErrors(
        handlers.handleCameraSetCooling(
          _post('/api/camera/cooling', {
            'deviceId': 'sim_camera_1',
            'enabled': true,
            'targetTemp': -10.0,
          }),
        ),
      );

      // The host's camera cools through DeviceService, as the host UI's
      // cooler controls do, so the cooling goal is recorded too.
      verifyInOrder([
        () => service.cancelWarmCamera(restorePriorSetting: false),
        () => service.setCameraCooling(enabled: true, targetTemp: -10.0),
      ]);
      verifyNever(
        () => backend.cameraSetCooling(
          deviceId: any(named: 'deviceId'),
          enabled: any(named: 'enabled'),
          targetTemp: any(named: 'targetTemp'),
        ),
      );
    },
  );

  test('a cooler command for another camera does not touch the host '
      'camera\'s warm-up', () async {
    await translateHandlerErrors(
      handlers.handleCameraSetCooling(
        _post('/api/camera/cooling', {
          'deviceId': 'guide_camera',
          'enabled': true,
          'targetTemp': -5.0,
        }),
      ),
    );

    verifyNever(
      () => service.cancelWarmCamera(
        restorePriorSetting: any(named: 'restorePriorSetting'),
      ),
    );
    verify(
      () => backend.cameraSetCooling(
        deviceId: 'guide_camera',
        enabled: true,
        targetTemp: -5.0,
      ),
    ).called(1);
  });
}
