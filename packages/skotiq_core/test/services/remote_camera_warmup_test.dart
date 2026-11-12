// On a remote client the gradual warm-up runs on the imaging host: the client
// asks for it and shows it, sends no set-points of its own, cancels it on the
// host, and leaves it running when the client goes away.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

void main() {
  late _MockNetworkBackend host;
  late ProviderContainer container;

  setUp(() {
    host = _MockNetworkBackend();
    when(() => host.eventStream).thenAnswer((_) => const Stream.empty());
    when(
      () => host.cameraStartHostWarmUp(ratePerMin: any(named: 'ratePerMin')),
    ).thenAnswer((_) async => 'started');
    when(
      () => host.cameraCancelHostWarmUp(
        restorePriorSetting: any(named: 'restorePriorSetting'),
      ),
    ).thenAnswer((_) async {});
    container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith((ref) => _FixedBackendNotifier(ref, host)),
        loggingServiceProvider.overrideWithValue(LoggingService()),
      ],
    );
    final camera = container.read(cameraStateProvider.notifier);
    camera.setConnecting('sim_camera_1');
    camera.setConnected();
    camera.setTargetTemp(-10);
    camera.setCooling(true);
  });

  tearDown(() => container.dispose());

  test(
    'Warm up asks the host to run the ramp and sends no set-points',
    () async {
      final service = container.read(deviceServiceProvider);

      final outcome = await service.warmCamera();

      expect(outcome, CameraWarmupOutcome.started);
      verify(() => host.cameraStartHostWarmUp(ratePerMin: 2.0)).called(1);
      verifyNever(
        () => host.cameraSetCooling(
          deviceId: any(named: 'deviceId'),
          enabled: any(named: 'enabled'),
          targetTemp: any(named: 'targetTemp'),
        ),
      );
      expect(container.read(cameraStateProvider).isWarming, isTrue);
    },
  );

  test('Cancel warm-up stops the ramp on the host', () async {
    final service = container.read(deviceServiceProvider);
    await service.warmCamera();

    service.cancelWarmCamera();
    await Future<void>.delayed(Duration.zero);

    verify(
      () => host.cameraCancelHostWarmUp(restorePriorSetting: true),
    ).called(1);
    expect(container.read(cameraStateProvider).isWarming, isFalse);
  });

  test('closing this client leaves the host warm-up running', () async {
    final service = container.read(deviceServiceProvider);
    await service.warmCamera();

    await service.prepareForBackendSwap();
    container.invalidate(deviceServiceProvider);
    await Future<void>.delayed(Duration.zero);

    verifyNever(
      () => host.cameraCancelHostWarmUp(
        restorePriorSetting: any(named: 'restorePriorSetting'),
      ),
    );
  });
}
