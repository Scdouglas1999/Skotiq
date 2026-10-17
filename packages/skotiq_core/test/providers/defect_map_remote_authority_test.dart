import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

final _seedDefectMapProvider = FutureProvider<void>(
  seedDefectMapRuntimeForSequence,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'remote status, clear, and sequencer push never touch client FFI',
    () async {
      final backend = _MockNetworkBackend();
      const status = DefectMapStatus(
        cameraId: 'remote-camera',
        width: 3000,
        height: 2000,
        temperatureBucket: DefectMapTemperatureBucket(-100),
        defectivePixelCount: 17,
        lastRebuiltUnixSeconds: 42,
        applyDuringCapture: true,
        storedOnDisk: true,
      );
      when(
        () => backend.getDefectMapStatus(
          cameraId: 'remote-camera',
          width: 3000,
          height: 2000,
          sensorTemperatureCelsius: -10,
        ),
      ).thenAnswer((_) async => status);
      when(
        () => backend.clearDefectMap(
          cameraId: 'remote-camera',
          width: 3000,
          height: 2000,
          sensorTemperatureCelsius: -10,
        ),
      ).thenAnswer((_) async {});
      when(
        () => backend.applyDefectMapToSequencer(
          cameraId: 'remote-camera',
          width: 3000,
          height: 2000,
          sensorTemperatureCelsius: -10,
          enabled: true,
          method: DefectMapMethod.gaussian,
          kernel: DefectMapKernelSize.k5,
          saveOriginal: true,
        ),
      ).thenAnswer((_) async {});
      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);
      final service = container.read(defectMapServiceProvider);

      expect(
        await service.getStatus(
          cameraId: 'remote-camera',
          width: 3000,
          height: 2000,
          sensorTemperatureCelsius: -10,
        ),
        status,
      );
      await service.clear(
        cameraId: 'remote-camera',
        width: 3000,
        height: 2000,
        sensorTemperatureCelsius: -10,
      );
      await service.applyToSequencer(
        cameraId: 'remote-camera',
        width: 3000,
        height: 2000,
        sensorTemperatureCelsius: -10,
        enabled: true,
        method: DefectMapMethod.gaussian,
        kernel: DefectMapKernelSize.k5,
        saveOriginal: true,
      );

      verify(
        () => backend.getDefectMapStatus(
          cameraId: 'remote-camera',
          width: 3000,
          height: 2000,
          sensorTemperatureCelsius: -10,
        ),
      ).called(1);
      verify(
        () => backend.clearDefectMap(
          cameraId: 'remote-camera',
          width: 3000,
          height: 2000,
          sensorTemperatureCelsius: -10,
        ),
      ).called(1);
      verify(
        () => backend.applyDefectMapToSequencer(
          cameraId: 'remote-camera',
          width: 3000,
          height: 2000,
          sensorTemperatureCelsius: -10,
          enabled: true,
          method: DefectMapMethod.gaussian,
          kernel: DefectMapKernelSize.k5,
          saveOriginal: true,
        ),
      ).called(1);
    },
  );

  test('remote defect-map settings preserve the host snapshot', () async {
    final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final backend = _MockNetworkBackend();
    when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
    when(backend.getDefectMapSettings).thenAnswer(
      (_) async => {
        'autoApply': true,
        'method': 'median',
        'kernelDiameter': 3,
        'saveOriginal': true,
      },
    );
    when(
      () => backend.updateDefectMapSettings(any()),
    ).thenAnswer((_) async => const {'status': 'updated'});
    final localBefore = await database.settingsDao.getSetting(
      DefectMapSettingsKeys.method,
    );
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(defectMapSettingsProvider.notifier);
    expect(notifier.state.isLoading, isTrue);
    await notifier.setMethod(DefectMapMethod.gaussian);

    expect(notifier.state.isLoading, isFalse);
    expect(notifier.state.loadError, null);
    expect(notifier.state.autoApply, isTrue);
    expect(notifier.state.method, DefectMapMethod.gaussian);
    expect(notifier.state.kernel, DefectMapKernelSize.k3);
    expect(notifier.state.saveOriginal, isTrue);
    verify(
      () => backend.updateDefectMapSettings({'method': 'gaussian'}),
    ).called(1);
    expect(
      await database.settingsDao.getSetting(DefectMapSettingsKeys.method),
      localBefore,
    );
  });

  test(
    'sequence seed applies persisted auto-apply without visiting UI',
    () async {
      final backend = _MockNetworkBackend();
      when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
      when(backend.getDefectMapSettings).thenAnswer(
        (_) async => {
          'autoApply': true,
          'method': 'gaussian',
          'kernelDiameter': 5,
          'saveOriginal': true,
        },
      );
      const status = DefectMapStatus(
        cameraId: 'remote-camera',
        width: 3000,
        height: 2000,
        temperatureBucket: DefectMapTemperatureBucket(-100),
        defectivePixelCount: 17,
        lastRebuiltUnixSeconds: 42,
        applyDuringCapture: false,
        storedOnDisk: true,
      );
      when(
        () => backend.getDefectMapStatus(
          cameraId: 'remote-camera',
          width: 3000,
          height: 2000,
          sensorTemperatureCelsius: -10,
        ),
      ).thenAnswer((_) async => status);
      when(
        () => backend.applyDefectMapToSequencer(
          cameraId: 'remote-camera',
          width: 3000,
          height: 2000,
          sensorTemperatureCelsius: -10,
          enabled: true,
          method: DefectMapMethod.gaussian,
          kernel: DefectMapKernelSize.k5,
          saveOriginal: true,
        ),
      ).thenAnswer((_) async {});
      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          cameraCapabilitiesProvider.overrideWith(
            (ref, deviceId) async => const CameraCapabilities(
              maxWidth: 3000,
              maxHeight: 2000,
              bitDepth: 16,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final camera = container.read(cameraStateProvider.notifier);
      camera.setConnecting('remote-camera');
      camera.setConnected();
      camera.updateTemperature(-10);

      await container.read(_seedDefectMapProvider.future);

      verify(
        () => backend.applyDefectMapToSequencer(
          cameraId: 'remote-camera',
          width: 3000,
          height: 2000,
          sensorTemperatureCelsius: -10,
          enabled: true,
          method: DefectMapMethod.gaussian,
          kernel: DefectMapKernelSize.k5,
          saveOriginal: true,
        ),
      ).called(1);
    },
  );
}
