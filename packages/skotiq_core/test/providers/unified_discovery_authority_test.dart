import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _MockDeviceService extends Mock implements DeviceService {}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void swap(SkotiqBackend backend) => state = backend;
}

class _SettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
}

DeviceInfo _device(String id) => DeviceInfo(
  id: id,
  name: 'Camera $id',
  deviceType: DeviceType.camera,
  driverType: DriverType.native,
  description: '',
  driverVersion: '',
);

void main() {
  setUpAll(() {
    registerFallbackValue(DeviceType.camera);
  });

  ProviderContainer createContainer({
    required NetworkBackend backend,
    required DeviceService service,
    void Function(_SwappableBackendNotifier notifier)? captureNotifier,
  }) {
    return ProviderContainer(
      overrides: [
        backendProvider.overrideWith((ref) {
          final notifier = _SwappableBackendNotifier(ref, backend);
          captureNotifier?.call(notifier);
          return notifier;
        }),
        deviceServiceProvider.overrideWithValue(service),
        appSettingsProvider.overrideWith(_SettingsNotifier.new),
      ],
    );
  }

  test('a hung camera scan ends with an error and retains other devices', () {
    fakeAsync((async) {
      final service = _MockDeviceService();
      final cameraResult = Completer<List<DeviceInfo>>();
      const mount = DeviceInfo(
        id: 'mount',
        name: 'Mount',
        deviceType: DeviceType.mount,
        driverType: DriverType.native,
        description: '',
        driverVersion: '',
      );
      when(() => service.discoverDevices(any())).thenAnswer((invocation) {
        final type = invocation.positionalArguments.single as DeviceType;
        return type == DeviceType.camera
            ? cameraResult.future
            : Future.value(type == DeviceType.mount ? [mount] : []);
      });
      final container = createContainer(
        backend: _MockNetworkBackend(),
        service: service,
      );
      addTearDown(container.dispose);
      var completed = false;
      container.read(unifiedDiscoveryProvider.notifier).discoverAll().then((_) {
        completed = true;
      });
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 46));
      expect(completed, isTrue);
      final state = container.read(unifiedDiscoveryProvider);
      expect(state.isDiscovering, isFalse);
      expect(state.rawDevices.map((d) => d.id), ['mount']);
      expect(state.backendStates.values.single.error, contains('Camera'));
      expect(state.backendStates.values.single.error, contains('timed out'));
      cameraResult.complete([_device('late-camera')]);
      async.flushMicrotasks();
      expect(
        container.read(unifiedDiscoveryProvider).rawDevices.map((d) => d.id),
        ['mount'],
      );
    });
  });

  test('a slower older scan cannot overwrite the latest scan', () async {
    final service = _MockDeviceService();
    final oldCameraResult = Completer<List<DeviceInfo>>();
    final newCameraResult = Completer<List<DeviceInfo>>();
    var cameraCalls = 0;
    when(() => service.discoverDevices(any())).thenAnswer((invocation) {
      final type = invocation.positionalArguments.single as DeviceType;
      if (type != DeviceType.camera) return Future.value(const []);
      cameraCalls++;
      return cameraCalls == 1 ? oldCameraResult.future : newCameraResult.future;
    });
    final container = createContainer(
      backend: _MockNetworkBackend(),
      service: service,
    );
    addTearDown(container.dispose);
    final discovery = container.read(unifiedDiscoveryProvider.notifier);

    final oldScan = discovery.discoverAll();
    await Future<void>.delayed(Duration.zero);
    final newScan = discovery.discoverAll();
    await Future<void>.delayed(Duration.zero);
    expect(cameraCalls, 2);

    newCameraResult.complete([_device('new')]);
    await newScan;
    expect(
      container.read(unifiedDiscoveryProvider).rawDevices.map((d) => d.id),
      ['new'],
    );

    oldCameraResult.complete([_device('old')]);
    await oldScan;
    expect(
      container.read(unifiedDiscoveryProvider).rawDevices.map((d) => d.id),
      ['new'],
    );
  });

  test('clear invalidates a scan that is still running', () async {
    final service = _MockDeviceService();
    final cameraResult = Completer<List<DeviceInfo>>();
    when(() => service.discoverDevices(any())).thenAnswer((invocation) {
      final type = invocation.positionalArguments.single as DeviceType;
      return type == DeviceType.camera
          ? cameraResult.future
          : Future.value(const []);
    });
    final container = createContainer(
      backend: _MockNetworkBackend(),
      service: service,
    );
    addTearDown(container.dispose);
    final discovery = container.read(unifiedDiscoveryProvider.notifier);

    final scan = discovery.discoverAll();
    await Future<void>.delayed(Duration.zero);
    discovery.clear();
    cameraResult.complete([_device('late')]);
    await scan;

    expect(container.read(unifiedDiscoveryProvider).rawDevices, isEmpty);
    expect(container.read(unifiedDiscoveryProvider).backendStates, isEmpty);
  });

  test('backend swap clears results and rejects the old host scan', () async {
    final service = _MockDeviceService();
    final cameraResult = Completer<List<DeviceInfo>>();
    when(() => service.discoverDevices(any())).thenAnswer((invocation) {
      final type = invocation.positionalArguments.single as DeviceType;
      return type == DeviceType.camera
          ? cameraResult.future
          : Future.value(const []);
    });
    late _SwappableBackendNotifier backendNotifier;
    final container = createContainer(
      backend: _MockNetworkBackend(),
      service: service,
      captureNotifier: (notifier) => backendNotifier = notifier,
    );
    addTearDown(container.dispose);
    final discovery = container.read(unifiedDiscoveryProvider.notifier);

    final scan = discovery.discoverAll();
    await Future<void>.delayed(Duration.zero);
    backendNotifier.swap(_MockNetworkBackend());
    expect(container.read(unifiedDiscoveryProvider).backendStates, isEmpty);

    cameraResult.complete([_device('old-host')]);
    await scan;
    expect(container.read(unifiedDiscoveryProvider).rawDevices, isEmpty);
    expect(container.read(unifiedDiscoveryProvider).backendStates, isEmpty);
  });
}
