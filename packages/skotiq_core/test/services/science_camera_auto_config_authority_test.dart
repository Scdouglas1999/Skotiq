import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockLocalBackend extends Mock implements SkotiqBackend {}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _SwitchableBackendNotifier extends BackendNotifier {
  _SwitchableBackendNotifier(super.ref, SkotiqBackend initial) : super() {
    state = initial;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

class _SeededCameraNotifier extends CameraStateNotifier {
  _SeededCameraNotifier(super.ref, CameraStateSnapshot initial) : super() {
    state = initial;
  }

  void replace(CameraStateSnapshot next) => state = next;
}

CameraStateSnapshot _connectedCamera(String id, String name) {
  return CameraStateSnapshot(
    connectionState: DeviceConnectionState.connected,
    deviceId: id,
    deviceName: name,
  );
}

/// Saturation comes from the driver's PIXEL-CONTAINER full scale
/// (`CameraStatus.maxAdu`), never from `2^bitDepth - 1` — a 12-bit sensor whose
/// driver left-justifies into 16 bits saturates at 65520, not 4095.
CameraStatus _statusWithMaxAdu(int maxAdu) =>
    CameraStatus.fromJson({'connected': true, 'maxAdu': maxAdu});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('backend switch retires an in-flight local camera sync', () async {
    final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final localBackend = _MockLocalBackend();
    final remoteBackend = _MockNetworkBackend();
    final capabilities = Completer<CameraCapabilities?>();
    final capabilitiesRequested = Completer<void>();
    late _SwitchableBackendNotifier backendNotifier;

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        loggingServiceProvider.overrideWithValue(LoggingService()),
        backendProvider.overrideWith((ref) {
          backendNotifier = _SwitchableBackendNotifier(ref, localBackend);
          return backendNotifier;
        }),
        cameraStateProvider.overrideWith(
          (ref) => _SeededCameraNotifier(
            ref,
            _connectedCamera('old-camera', 'Old Camera'),
          ),
        ),
        cameraCapabilitiesProvider.overrideWith((ref, deviceId) {
          if (!capabilitiesRequested.isCompleted) {
            capabilitiesRequested.complete();
          }
          return capabilities.future;
        }),
      ],
    );
    addTearDown(container.dispose);

    container.read(scienceCameraAutoConfigProvider);
    await capabilitiesRequested.future;
    backendNotifier.switchTo(remoteBackend);
    capabilities.complete(
      const CameraCapabilities(maxWidth: 100, maxHeight: 100, bitDepth: 8),
    );
    await Future<void>.delayed(Duration.zero);

    final settings = await SettingsDao(database).getAllSettings();
    expect(settings, isNot(contains(ScienceCameraAutoConfig.saturationKey)));
    expect(settings, isNot(contains(ScienceCameraAutoConfig.autoSourceKey)));
  });

  test(
    'an older camera sync cannot overwrite the newly selected camera',
    () async {
      final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final localBackend = _MockLocalBackend();
      when(
        () => localBackend.getCameraStatus('camera-a'),
      ).thenAnswer((_) async => _statusWithMaxAdu(255));
      when(
        () => localBackend.getCameraStatus('camera-b'),
      ).thenAnswer((_) async => _statusWithMaxAdu(65520));
      final oldCapabilities = Completer<CameraCapabilities?>();
      final oldCapabilitiesRequested = Completer<void>();
      late _SeededCameraNotifier cameraNotifier;

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          loggingServiceProvider.overrideWithValue(LoggingService()),
          backendProvider.overrideWith(
            (ref) => _SwitchableBackendNotifier(ref, localBackend),
          ),
          cameraStateProvider.overrideWith((ref) {
            cameraNotifier = _SeededCameraNotifier(
              ref,
              _connectedCamera('camera-a', 'Camera A'),
            );
            return cameraNotifier;
          }),
          cameraCapabilitiesProvider.overrideWith((ref, deviceId) {
            if (deviceId == 'camera-a') {
              if (!oldCapabilitiesRequested.isCompleted) {
                oldCapabilitiesRequested.complete();
              }
              return oldCapabilities.future;
            }
            return Future.value(
              const CameraCapabilities(
                maxWidth: 100,
                maxHeight: 100,
                bitDepth: 12,
              ),
            );
          }),
        ],
      );
      addTearDown(container.dispose);

      final service = container.read(scienceCameraAutoConfigProvider);
      await oldCapabilitiesRequested.future;
      cameraNotifier.replace(_connectedCamera('camera-b', 'Camera B'));
      await service.maybeSync(reason: 'camera B selected');

      var settings = await SettingsDao(database).getAllSettings();
      expect(settings[ScienceCameraAutoConfig.saturationKey], '65520');
      expect(
        settings[ScienceCameraAutoConfig.autoSourceKey],
        contains('Camera B'),
      );

      oldCapabilities.complete(
        const CameraCapabilities(maxWidth: 100, maxHeight: 100, bitDepth: 8),
      );
      await Future<void>.delayed(Duration.zero);

      settings = await SettingsDao(database).getAllSettings();
      expect(settings[ScienceCameraAutoConfig.saturationKey], '65520');
      expect(
        settings[ScienceCameraAutoConfig.autoSourceKey],
        contains('Camera B'),
      );
    },
  );
}
