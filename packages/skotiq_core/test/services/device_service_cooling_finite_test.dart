// DeviceService.setCameraCooling finite-target guard (defense-in-depth).
//
// The GUI cooling dialog validates its text field, but non-UI callers (the
// headless API, sequencer instructions, other services) route through
// DeviceService too. A NaN/±∞ setpoint reaching the driver would either be
// silently coerced or corrupt the cooler control loop, so setCameraCooling
// rejects a non-finite target before any backend call. A null target (the
// "disable cooling" / "keep current setpoint" case) must still pass.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/disconnected_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/services/device_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _CoolingCaptureBackend backend;
  late ProviderContainer container;

  setUp(() {
    backend = _CoolingCaptureBackend();
    container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
      ],
    );
    // Seed a connected camera so setCameraCooling passes its precondition
    // checks and would reach the backend on a valid target.
    container.read(cameraStateProvider.notifier).setConnecting('cam-1', 'Cam');
    container.read(cameraStateProvider.notifier).setConnected();
  });

  tearDown(() => container.dispose());

  test('a NaN target is rejected before the backend is touched', () async {
    await expectLater(
      container
          .read(deviceServiceProvider)
          .setCameraCooling(enabled: true, targetTemp: double.nan),
      throwsA(isA<ArgumentError>()),
    );
    expect(backend.calls, isEmpty);
  });

  test(
    'an infinite target is rejected before the backend is touched',
    () async {
      await expectLater(
        container
            .read(deviceServiceProvider)
            .setCameraCooling(enabled: true, targetTemp: double.infinity),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        container
            .read(deviceServiceProvider)
            .setCameraCooling(
              enabled: true,
              targetTemp: double.negativeInfinity,
            ),
        throwsA(isA<ArgumentError>()),
      );
      expect(backend.calls, isEmpty);
    },
  );

  test('a finite target reaches the backend', () async {
    await container
        .read(deviceServiceProvider)
        .setCameraCooling(enabled: true, targetTemp: -10.0);
    expect(backend.calls, [(enabled: true, targetTemp: -10.0)]);
  });

  test('disable-cooling with no target is still allowed', () async {
    await container
        .read(deviceServiceProvider)
        .setCameraCooling(enabled: false);
    expect(backend.calls, [(enabled: false, targetTemp: null)]);
  });
}

typedef _CoolingCall = ({bool enabled, double? targetTemp});

class _CoolingCaptureBackend extends DisconnectedBackend {
  final List<_CoolingCall> calls = [];

  @override
  Future<void> cameraSetCooling({
    required String deviceId,
    required bool enabled,
    double? targetTemp,
  }) async {
    calls.add((enabled: enabled, targetTemp: targetTemp));
  }
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}
