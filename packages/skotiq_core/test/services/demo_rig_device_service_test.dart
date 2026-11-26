// The app's own device service on the demo rig: discovery finds the demo
// devices, every slot connects through the service, and the polling that
// follows a connect asks only for what the demo rig simulates.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/demo_backend/demo_backend.dart';
import 'package:skotiq_core/src/backend/demo_backend/demo_star_field.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/backend/backend_types.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/device_service_providers.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/providers/unified_discovery_provider.dart';

import '../harness/in_memory_database.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  late DemoBackend backend;
  late ProviderContainer container;

  setUp(() {
    backend = DemoBackend(
      latitudeDeg: 40,
      longitudeDeg: -105,
      renderFrame: (request) async => renderDemoFrame(request),
      cameraWidth: 96,
      cameraHeight: 64,
    );
    container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
      ],
    );
    container.read(deviceServiceProvider);
  });

  tearDown(() {
    container.dispose();
    backend.dispose();
  });

  test('every slot connects through the device service and polls only what '
      'the demo rig simulates', () async {
    await container
        .read(unifiedDiscoveryProvider.notifier)
        .discoverAll(includeIndi: false, includeAlpaca: false);
    final discovered = container.read(unifiedDiscoveryProvider);
    expect(
      discovered.toString(),
      contains('Demo Camera'),
      reason: 'discovery lists the demo devices',
    );

    final service = container.read(deviceServiceProvider);
    for (final (type, id) in [
      (DeviceType.camera, DemoDeviceIds.camera),
      (DeviceType.mount, DemoDeviceIds.mount),
      (DeviceType.focuser, DemoDeviceIds.focuser),
      (DeviceType.filterWheel, DemoDeviceIds.filterWheel),
      (DeviceType.rotator, DemoDeviceIds.rotator),
      (DeviceType.guider, DemoDeviceIds.guider),
      (DeviceType.weather, DemoDeviceIds.weather),
      (DeviceType.safetyMonitor, DemoDeviceIds.safetyMonitor),
    ]) {
      await service.connect(type, id);
    }

    expect(
      container.read(cameraStateProvider).connectionState,
      DeviceConnectionState.connected,
    );
    expect(
      container.read(mountStateProvider).connectionState,
      DeviceConnectionState.connected,
    );
    expect(
      container.read(focuserStateProvider).connectionState,
      DeviceConnectionState.connected,
    );
    expect(
      container.read(filterWheelStateProvider).connectionState,
      DeviceConnectionState.connected,
    );
    expect(
      container.read(rotatorStateProvider).connectionState,
      DeviceConnectionState.connected,
    );
    expect(
      container.read(guiderStateProvider).connectionState,
      DeviceConnectionState.connected,
    );
    expect(
      container.read(weatherStateProvider).connectionState,
      DeviceConnectionState.connected,
    );
    expect(
      container.read(safetyMonitorStateProvider).connectionState,
      DeviceConnectionState.connected,
    );

    // Let the mount, camera temperature, focuser and environment polling
    // run a few cycles.
    await Future<void>.delayed(const Duration(seconds: 7));

    // The readiness check asks for the plate solver settings and reads a
    // refusal as "no solver", which is true: the demo rig does not solve.
    const refusedOnPurpose = {'getPlateSolverConfig'};
    expect(
      backend.debugUnavailableCalls.difference(refusedOnPurpose),
      isEmpty,
      reason:
          'the connect and poll path called members the demo rig does '
          'not simulate',
    );
  }, timeout: const Timeout(Duration(seconds: 60)));
}
