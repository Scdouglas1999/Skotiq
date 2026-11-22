import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/utils.dart';
import 'package:skotiq_desktop/headless_api/handlers/device_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';
import 'package:skotiq_desktop/headless_api/job_manager.dart';

class _FakeDeviceBackend implements DeviceBackend {
  int angleReads = 0;

  @override
  Future<RotatorStatus> getRotatorStatus(String deviceId) async {
    return const RotatorStatus(
      connected: true,
      position: 10,
      moving: true,
      mechanicalPosition: 190,
      isMoving: true,
      canReverse: false,
    );
  }

  @override
  Future<double> rotatorGetAngle(String deviceId) async {
    angleReads++;
    return 0;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('rotator status reports motion and mechanical position', () async {
    final loggerTempDir = await Directory.systemTemp.createTemp('sk_rot_');
    final logger = LoggingService(
      applicationSupportDirectoryProvider: () async => loggerTempDir,
      nativeInitWithLogging: ({logDirectory}) {},
      nativeInit: () {},
      currentLogFileProvider: () => null,
    );
    await logger.ensureInitialized();
    final backend = _FakeDeviceBackend();
    final container = ProviderContainer(
      overrides: [
        loggingServiceProvider.overrideWithValue(logger),
        deviceBackendProvider.overrideWithValue(backend),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await logger.dispose();
      if (await loggerTempDir.exists()) {
        await loggerTempDir.delete(recursive: true);
      }
    });

    final response = await translateHandlerErrors(
      DeviceHandlers(
        container,
        jobManager: JobManager(emitEvent: (_) {}),
      ).handleRotatorGetStatus(
        Request(
          'GET',
          Uri.parse('http://localhost/api/rotator/status?deviceId=rot-1'),
        ),
      ),
    );

    expect(response.statusCode, HttpStatus.ok);
    final body = jsonDecode(await response.readAsString()) as Map;
    expect(body['position'], 10);
    expect(body['mechanicalPosition'], 190);
    expect(body['isMoving'], isTrue);
    expect(backend.angleReads, 0);
  });
}
